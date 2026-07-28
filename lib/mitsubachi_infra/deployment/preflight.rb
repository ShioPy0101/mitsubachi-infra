# frozen_string_literal: true

require 'fileutils'
require_relative '../errors'

module MitsubachiInfra
  module Deployment
    class Preflight
      REQUIRED_COMMANDS = %w[git bundle npm pg_dump pg_restore sha256sum nginx systemctl curl ss journalctl].freeze

      def initialize(config:, runner:, logger: $stderr)
        @config = config
        @runner = runner
        @logger = logger
      end

      def check!(backend_ref:, frontend_ref:, dry_run: false)
        validate_ref!(backend_ref, 'backend')
        validate_ref!(frontend_ref, 'frontend')
        REQUIRED_COMMANDS.each { |command| require_command!(command) }
        check_directory!(@config.fetch('release').fetch('backup_root'))
        check_nginx!
        check_service!(api_service)
        check_service!(worker_service)
        check_disk_space!
        resolve_ref(@config.fetch('backend').fetch('repository'), backend_ref)
        resolve_ref(@config.fetch('frontend').fetch('repository'), frontend_ref)
        smoke = @config.fetch('release').fetch('smoke_test')
        raise ValidationError, 'release.smoke_test.command is required' unless smoke['command'].is_a?(Array) && smoke['command'].any?
        credentials = smoke.fetch('credentials_file')
        if !File.file?(credentials) || (File.stat(credentials).mode & 0o077) != 0
          raise Error, "smoke-test credentials must exist and not be group/world accessible: #{credentials}"
        end
        manifest = smoke.fetch('removed_manifest')
        raise Error, "removed-routes manifest is missing: #{manifest}" unless File.file?(manifest)

        @logger.puts("[PREFLIGHT] health URL=#{health_url} Host=#{@config.health_host}")
        @logger.puts("[PREFLIGHT] maintenance flag=#{@config.fetch('release').fetch('maintenance_flag')}")
        @logger.puts("[PREFLIGHT] smoke manifest=#{smoke.fetch('removed_manifest')}")
        true
      end

      private

      def validate_ref!(ref, name)
        raise ValidationError, "--#{name}-ref is required" if ref.to_s.empty? || ref.to_s.start_with?('-')
      end

      def require_command!(command)
        result = probe('which', command, allow_failure: true)
        raise Error, "required command is missing: #{command}" unless result.success?
      end

      def check_directory!(path)
        if @runner.dry_run
          parent = existing_ancestor(path)
          raise Error, "release backup parent is not writable: #{parent}" unless File.writable?(parent)

          return @logger.puts("[DRY-RUN] backup directory can be created/written: #{path} via #{parent}")
        end

        FileUtils.mkdir_p(path)
        raise Error, "release backup directory is not writable: #{path}" unless File.writable?(path)
      end

      def check_disk_space!
        path = @config.fetch('release').fetch('backup_root')
        result = probe('df', '-Pk', File.exist?(path) ? path : existing_ancestor(path))
        available = result.stdout.lines.last.to_s.split[-3].to_i
        required = @config.fetch('release').fetch('minimum_free_kb').to_i
        raise Error, "insufficient release backup space: available=#{available}KB required=#{required}KB" if available < required

        @logger.puts("[PREFLIGHT] backup free space=#{available}KB required=#{required}KB")
      end

      def existing_ancestor(path)
        candidate = File.expand_path(path)
        candidate = File.dirname(candidate) until File.exist?(candidate) || candidate == File.dirname(candidate)
        candidate
      end

      def check_nginx!
        probe('nginx', '-t')
        result = probe('nginx', '-T')
        rendered = "#{result.stdout}\n#{result.stderr}"
        flag = @config.fetch('release').fetch('maintenance_flag')
        ready = "#{@config.fetch('backend').fetch('health_path')}/ready"
        raise Error, "active Nginx config does not contain maintenance flag #{flag}; run configure first" unless rendered.include?(flag)
        raise Error, "active Nginx config does not expose readiness during maintenance: #{ready}" unless rendered.include?(ready)
      end

      def check_service!(service)
        result = probe('systemctl', 'show', '--property=LoadState', service)
        raise Error, "systemd service is not loaded: #{service}" unless result.stdout.include?('LoadState=loaded')
      end

      def resolve_ref(repository, ref)
        probe_deploy('git', 'ls-remote', '--exit-code', repository, ref, config: @config, timeout: 120)
      end

      def probe(*command, **options)
        with_real_runner { @runner.run(*command, **options) }
      end

      def probe_deploy(*command, **options)
        with_real_runner { @runner.deploy(*command, **options) }
      end

      def with_real_runner
        original = @runner.dry_run
        @runner.dry_run = false
        yield
      ensure
        @runner.dry_run = original
      end

      def api_service
        @config.fetch('release').fetch('api_service')
      end

      def worker_service
        @config.fetch('release').fetch('worker_service')
      end

      def health_url
        "http://127.0.0.1:#{@config.fetch('ports').fetch('rails')}#{@config.fetch('backend').fetch('health_path')}/ready"
      end
    end
  end
end
