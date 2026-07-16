# frozen_string_literal: true

require 'ipaddr'
require 'yaml'
require_relative 'errors'

module MitsubachiInfra
  class Configuration
    CONFIG_PATH = '/etc/mitsubachi/config.yml'
    DEFAULT = {
      'deployment_mode' => 'lan',
      'server_ip' => '192.168.1.50',
      'lan_cidr' => '192.168.1.0/24',
      'deploy' => {
        'user' => 'deploy',
        'home' => '/home/deploy',
        'app_root' => '/var/www/mitsubachi'
      },
      'server' => {
        'deploy_user' => 'deploy',
        'server_id' => nil
      },
      'domains' => {
        'frontend' => 'mitsubachi.shiosalt.com',
        'api' => 'mitsubachi-api.shiosalt.com'
      },
      'paths' => {
        'rails_root' => '/var/www/mitsubachi',
        'frontend_root' => '/var/www/mitsubachi-frontend',
        'rails_env' => '/etc/mitsubachi/rails.env',
        'frontend_env' => '/etc/mitsubachi/frontend.env',
        'caddyfile' => '/etc/caddy/Caddyfile',
        'server_id' => '/etc/mitsubachi/server-id'
      },
      'ports' => {
        'rails' => 3000,
        'http' => 80,
        'https' => 443,
        'minecraft' => [25_565, 25_566]
      },
      'release_retention' => 5,
      'acme_email' => nil,
      'runtime' => {
        'ruby_version' => '3.3.7',
        'node_major' => 22
      },
      'backend' => {
        'repository' => 'git@github.com:ShioPy0101/mitsubachi-ruby.git',
        'ref' => 'main',
        'keep_releases' => 5,
        'health_path' => '/api/health'
      },
      'frontend' => {
        'repository' => 'git@github.com:ShioPy0101/mitsubachi-front.git',
        'ref' => 'main',
        'keep_releases' => 5,
        'build_command' => %w[npm run build],
        'output_directory' => 'dist'
      },
      'https' => {
        'host' => nil,
        'email' => nil,
        'staging' => false,
        'challenge' => 'http-01'
      }
    }.freeze

    attr_reader :path, :data

    def initialize(path = CONFIG_PATH, data: nil)
      @path = path
      @data = deep_merge(DEFAULT, data || load_file(path))
      validate!
    end

    def [](key)
      data.fetch(key)
    end

    def fetch(key)
      data.fetch(key)
    end

    def backend_root
      File.join(fetch('deploy').fetch('app_root'), 'backend')
    end

    def frontend_root
      File.join(fetch('deploy').fetch('app_root'), 'frontend')
    end

    def repositories_root
      File.join(fetch('deploy').fetch('app_root'), 'repositories')
    end

    def production_frontend_url
      "https://#{data.fetch('domains').fetch('frontend')}"
    end

    def production_api_url
      "https://#{data.fetch('domains').fetch('api')}"
    end

    def certificate_domains
      [data.fetch('domains').fetch('frontend'), data.fetch('domains').fetch('api')].uniq
    end

    def public?
      fetch('deployment_mode') == 'public'
    end

    def lan?
      fetch('deployment_mode') == 'lan'
    end

    def validate!
      mode = data['deployment_mode']
      raise ValidationError, 'deployment_mode must be lan or public' unless %w[lan public].include?(mode)

      validate_deploy!
      validate_production_schema!
      validate_app!('backend')
      validate_app!('frontend')
      validate_frontend!
      validate_https!
      true
    end

    private

    def load_file(path)
      return {} unless File.exist?(path)

      YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
    end

    def deep_merge(base, override)
      base.merge(override) do |_key, old_value, new_value|
        old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
      end
    end

    def validate_deploy!
      deploy = data.fetch('deploy')
      %w[user home app_root].each { |key| present!(deploy[key], "deploy.#{key}") }
      reject_traversal!(deploy['app_root'], 'deploy.app_root')
    end

    def validate_app!(name)
      app = data.fetch(name)
      present!(app['repository'], "#{name}.repository")
      positive_integer!(app['keep_releases'], "#{name}.keep_releases")
    end

    def validate_frontend!
      frontend = data.fetch('frontend')
      command = frontend['build_command']
      unless command.is_a?(Array) && !command.empty? && command.all? do |v|
        v.to_s != ''
      end
        raise ValidationError,
              'frontend.build_command must not be empty'
      end

      output = frontend['output_directory'].to_s
      present!(output, 'frontend.output_directory')
      raise ValidationError, 'frontend.output_directory must be relative' if output.start_with?('/')

      reject_traversal!(output, 'frontend.output_directory')
    end

    def validate_https!
      https = data.fetch('https')
      raise ValidationError, 'https.challenge must be http-01' unless https['challenge'] == 'http-01'
      return unless public?

      host = https['host'].to_s
      email = https['email'].to_s
      validate_public_host!(host) unless host.empty?
      return if email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)

      raise ValidationError,
            'https.email is required in public mode'
    end

    def validate_production_schema!
      %w[frontend api].each { |key| validate_public_host!(data.fetch('domains').fetch(key)) }
      paths = data.fetch('paths')
      %w[rails_root frontend_root rails_env frontend_env caddyfile server_id].each do |key|
        value = paths.fetch(key)
        present!(value, "paths.#{key}")
        raise ValidationError, "paths.#{key} must be absolute" unless value.start_with?('/')

        reject_traversal!(value, "paths.#{key}")
      end
      ports = data.fetch('ports')
      %w[rails http https].each { |key| integer_port!(ports.fetch(key), "ports.#{key}") }
      minecraft = ports.fetch('minecraft')
      raise ValidationError, 'ports.minecraft must be an array' unless minecraft.is_a?(Array)

      minecraft.each { |port| integer_port!(port, 'ports.minecraft') }
    end

    def validate_public_host!(host)
      present!(host, 'https.host')
      raise ValidationError, 'https.host must not include scheme' if host.include?('://')
      raise ValidationError, 'https.host must not include path' if host.include?('/')
      raise ValidationError, 'https.host must not be localhost' if host == 'localhost'
      raise ValidationError, 'https.host must be hostname, not IP' if ip_address?(host)
      return if host.match?(/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\z/i)

      raise ValidationError,
            'https.host is invalid'
    end

    def present!(value, name)
      raise ValidationError, "#{name} is required" if value.nil? || value.to_s.empty?
    end

    def positive_integer!(value, name)
      raise ValidationError, "#{name} must be positive integer" unless value.to_i.positive?
    end

    def integer_port!(value, name)
      port = Integer(value)
      raise ValidationError, "#{name} must be 1..65535" unless port.between?(1, 65_535)
    rescue ArgumentError, TypeError
      raise ValidationError, "#{name} must be integer"
    end

    def reject_traversal!(value, name)
      return unless value.to_s.split(File::SEPARATOR).include?('..')

      raise ValidationError, "#{name} must not include path traversal"
    end

    def ip_address?(value)
      IPAddr.new(value)
      true
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
