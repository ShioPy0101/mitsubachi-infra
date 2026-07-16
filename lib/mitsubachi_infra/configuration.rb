# frozen_string_literal: true

require 'ipaddr'
require 'yaml'
require_relative 'errors'

module MitsubachiInfra
  class Configuration
    CONFIG_PATH = '/etc/mitsubachi/config.yml'
    DEFAULT = {
      'deployment_mode' => 'lan',
      'server_ip' => nil,
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
      'nginx' => {
        'default_server' => false,
        'remove_default_site' => false
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
        'frontend_host' => 'mitsubachi.shiosalt.com',
        'api_host' => 'mitsubachi-api.shiosalt.com',
        'email' => nil,
        'acme_webroot' => '/var/lib/mitsubachi/acme',
        'enable_hsts' => false,
        'challenge' => 'http-01'
      },
      'postgresql' => {
        'wal_archive' => {
          'mount_point' => '/mnt/external-hdd',
          'archive_directory' => '/mnt/external-hdd/mitsubachi/backups/wal',
          'archive_script' => '/usr/local/libexec/mitsubachi/archive-wal',
          'config_filename' => '90-mitsubachi-wal-archive.conf',
          'version' => nil,
          'cluster' => nil,
          'archive_timeout' => nil
        }
      }
    }.freeze

    attr_reader :path, :data

    def initialize(path = CONFIG_PATH, data: nil, validate: true)
      @path = path
      @data = deep_merge(DEFAULT, data || load_file(path))
      validate! if validate
    end

    def [](key)
      data.fetch(key)
    end

    def fetch(key)
      data.fetch(key)
    end

    def backend_root
      fetch('paths').fetch('rails_root')
    end

    def frontend_root
      fetch('paths').fetch('frontend_root')
    end

    def repositories_root
      fetch('paths').fetch('rails_root')
    end

    def backend_repository_cache
      File.join(fetch('paths').fetch('rails_root'), 'repo')
    end

    def frontend_repository_cache
      File.join(fetch('paths').fetch('frontend_root'), 'repo')
    end

    def app_host
      public? ? api_host : fetch('server_ip')
    end

    def allowed_hosts
      [app_host, '127.0.0.1', 'localhost'].uniq
    end

    def health_host
      app_host
    end

    def production_frontend_url
      "https://#{frontend_host}"
    end

    def production_api_url
      "https://#{api_host}"
    end

    def certificate_domains
      [frontend_host, api_host].uniq
    end

    def frontend_host
      fetch('https').fetch('frontend_host')
    end

    def api_host
      fetch('https').fetch('api_host')
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

      validate_mode_specific!
      validate_deploy!
      validate_production_schema!
      validate_app!('backend')
      validate_app!('frontend')
      validate_frontend!
      validate_https!
      validate_postgresql!
      true
    end

    def missing_required_settings
      missing = []
      mode = data['deployment_mode'].to_s
      missing << 'deployment_mode' unless %w[lan public].include?(mode)
      missing << 'server_ip' if mode == 'lan' && data['server_ip'].to_s.empty?
      if mode == 'public'
        https = data.fetch('https')
        missing << 'https.frontend_host' if https['frontend_host'].to_s.empty?
        missing << 'https.api_host' if https['api_host'].to_s.empty?
        missing << 'https.email' if https['email'].to_s.empty?
      end
      missing
    end

    def set(path, value)
      keys = path.split('.')
      target = data
      keys[0...-1].each { |key| target = target.fetch(key) }
      target[keys.last] = value
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

    def validate_mode_specific!
      if lan?
        present!(data['server_ip'], 'server_ip')
        raise ValidationError, 'server_ip must be private IPv4 in lan mode' unless private_ipv4?(data['server_ip'])
      end
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
      if https.key?('host')
        raise ValidationError, 'https.host is no longer supported. Set https.frontend_host and https.api_host.'
      end
      raise ValidationError, 'https.challenge must be http-01' unless https['challenge'] == 'http-01'
      present!(https['acme_webroot'], 'https.acme_webroot')
      raise ValidationError, 'https.acme_webroot must be absolute' unless https['acme_webroot'].to_s.start_with?('/')
      return unless public?

      email = https['email'].to_s
      validate_public_host!(https['frontend_host'], 'https.frontend_host')
      validate_public_host!(https['api_host'], 'https.api_host')
      return if email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)

      raise ValidationError,
            'https.email is required in public mode'
    end

    def validate_postgresql!
      wal = data.fetch('postgresql').fetch('wal_archive')
      %w[mount_point archive_directory archive_script config_filename].each do |key|
        present!(wal[key], "postgresql.wal_archive.#{key}")
      end
      %w[mount_point archive_directory archive_script].each do |key|
        value = wal.fetch(key).to_s
        raise ValidationError, "postgresql.wal_archive.#{key} must be absolute" unless value.start_with?('/')

        reject_traversal!(value, "postgresql.wal_archive.#{key}")
      end
      archive_dir = wal.fetch('archive_directory').to_s
      mount_point = wal.fetch('mount_point').to_s
      unless archive_dir == mount_point || archive_dir.start_with?("#{mount_point}/")
        raise ValidationError, 'postgresql.wal_archive.archive_directory must be under mount_point'
      end
      filename = wal.fetch('config_filename').to_s
      raise ValidationError, 'postgresql.wal_archive.config_filename must end with .conf' unless filename.end_with?('.conf')
      raise ValidationError, 'postgresql.wal_archive.config_filename must be a basename' if filename.include?('/')
      if wal['archive_timeout'] && !wal['archive_timeout'].to_s.match?(/\A\d+[smh]?\z/)
        raise ValidationError, 'postgresql.wal_archive.archive_timeout must be a PostgreSQL duration like 300s'
      end
    end

    def validate_production_schema!
      data.fetch('domains', {}).each { |_key, value| validate_public_host!(value, 'domains') } if data.key?('domains')
      paths = data.fetch('paths')
      %w[rails_root frontend_root rails_env frontend_env server_id].each do |key|
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

    def validate_public_host!(host, name = 'hostname')
      present!(host, name)
      raise ValidationError, "#{name} must not include scheme" if host.include?('://')
      raise ValidationError, "#{name} must not include path" if host.include?('/')
      raise ValidationError, "#{name} must not be localhost" if host == 'localhost'
      raise ValidationError, "#{name} must be hostname, not IP" if ip_address?(host)
      return if host.match?(/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\z/i)

      raise ValidationError,
            "#{name} is invalid"
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

    def private_ipv4?(value)
      address = IPAddr.new(value)
      address.ipv4? && (
        IPAddr.new('10.0.0.0/8').include?(address) ||
        IPAddr.new('172.16.0.0/12').include?(address) ||
        IPAddr.new('192.168.0.0/16').include?(address)
      )
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
