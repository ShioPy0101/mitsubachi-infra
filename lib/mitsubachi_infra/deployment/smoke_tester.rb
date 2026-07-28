# frozen_string_literal: true

require 'json'
require 'etc'
require 'fileutils'
require 'net/http'
require 'openssl'
require 'uri'
require 'yaml'
require_relative '../errors'

module MitsubachiInfra
  module Deployment
    class SmokeTester
      def initialize(config:, runner:, logger: $stderr)
        @config = config
        @runner = runner
        @logger = logger
      end

      def run!(release_id:, output:, credentials_file: nil, delete_credentials: false)
        settings = @config.fetch('release').fetch('smoke_test')
        source_credentials = credentials_file || settings.fetch('credentials_file')
        validate_credentials!(source_credentials) unless @runner.dry_run
        runtime_credentials = @runner.dry_run ? source_credentials : materialize_runtime_credentials(source_credentials,
                                                                                                      output)
        env = {
          'RELEASE_ID' => release_id,
          'OUTPUT' => output,
          'CREDENTIALS_FILE' => runtime_credentials,
          'BASE_URL' => public_frontend_url,
          'API_BASE_URL' => public_api_url,
          'RAILS_READINESS_URL' => rails_readiness_url,
          'SMOKE_RESOLVED_ADDRESS' => '127.0.0.1',
          'FRONTEND_HOST' => @config.frontend_host,
          'API_HOST' => @config.health_host
        }
        @runner.deploy(*settings.fetch('command'), config: @config,
                                                    chdir: File.join(@config.frontend_root, 'current'),
                                                    env: env, timeout: settings.fetch('timeout_seconds'))
        return { succeeded: true, dry_run: true } if @runner.dry_run

        report = read_report(output)
        raise Error, 'production smoke test reported succeeded=false' unless report['succeeded'] == true

        begin
          report['removed_routes'] = check_removed!(settings.fetch('removed_manifest'))
        rescue StandardError => error
          report['succeeded'] = false
          report['removed_routes_error'] = error.message
          write_report(output, report)
          raise
        end
        write_report(output, report)
        report
      ensure
        FileUtils.rm_f(runtime_credentials) if defined?(runtime_credentials) && runtime_credentials != source_credentials
        FileUtils.rm_f(source_credentials) if delete_credentials && defined?(source_credentials)
      end

      private

      def validate_credentials!(path)
        raise Error, "smoke-test credentials are missing: #{path}" unless File.file?(path)
        raise Error, "smoke-test credentials must be mode 0600: #{path}" unless (File.stat(path).mode & 0o077).zero?
      end

      def materialize_runtime_credentials(source, output)
        path = "#{output}.credentials.#{$PROCESS_ID}"
        File.write(path, File.binread(source), mode: 'wb', perm: 0o600)
        account = Etc.getpwnam(@config.fetch('deploy').fetch('user'))
        File.chown(account.uid, account.gid, path)
        path
      rescue StandardError
        FileUtils.rm_f(path) if path
        raise
      end

      def write_report(path, report)
        File.write(path, JSON.pretty_generate(report) + "\n", mode: 'w', perm: 0o640)
        File.chmod(0o640, path)
      end

      def read_report(path)
        raise Error, "smoke test did not create report: #{path}" unless File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise Error, "smoke test generated invalid JSON: #{e.message}"
      end

      def check_removed!(manifest_path)
        return [] if manifest_path.to_s.empty? || !File.file?(manifest_path)

        manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false) || {}
        endpoints = Array(manifest['removed_endpoints']).map { |entry| check_route(entry, api: true) }
        pages = Array(manifest['removed_pages']).map { |entry| check_route(entry, api: false) }
        endpoints + pages
      end

      def check_route(entry, api:)
        method = entry.fetch('method', 'GET').upcase
        expected = Integer(entry.fetch('expected_status', 404))
        base = api ? public_api_url : public_frontend_url
        uri = URI.join(base, entry.fetch('path'))
        request_class = Net::HTTP.const_get(method.capitalize)
        request = request_class.new(uri.request_uri)
        request['Host'] = uri.host
        options = { use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 10 }
        options[:ipaddr] = '127.0.0.1' if @config.public?
        options[:verify_mode] = OpenSSL::SSL::VERIFY_PEER if options[:use_ssl]
        response = Net::HTTP.start(uri.host, uri.port, **options) { |connection| connection.request(request) }
        actual = response.code.to_i
        raise Error, "removed route #{method} #{entry.fetch('path')} returned #{actual}, expected #{expected}" unless actual == expected
        raise Error, "removed route redirected: #{entry.fetch('path')}" if response.is_a?(Net::HTTPRedirection)

        { method: method, path: entry.fetch('path'), expected_status: expected, actual_status: actual, passed: true }
      end

      def public_frontend_url
        @config.public? ? "https://#{@config.frontend_host}/" : "http://#{@config.fetch('server_ip')}/"
      end

      def public_api_url
        @config.public? ? "https://#{@config.health_host}/" : "http://#{@config.fetch('server_ip')}/"
      end

      def rails_readiness_url
        "http://127.0.0.1:#{@config.fetch('ports').fetch('rails')}#{@config.fetch('backend').fetch('health_path')}/ready"
      end

      def frontend_host
        @config.public? ? @config.frontend_host : @config.fetch('server_ip')
      end
    end
  end
end
