# frozen_string_literal: true

require 'English'
require 'erb'
require 'fileutils'
require_relative 'atomic_writer'
require_relative 'certbot'
require_relative 'deploy_user'
require_relative 'health_check'
require_relative 'nginx'
require_relative 'postgresql'
require_relative 'ruby_runtime'
require_relative 'systemd'

module MitsubachiInfra
  class Installer
    PACKAGES = %w[
      git curl ca-certificates build-essential postgresql postgresql-contrib
      nginx ufw certbot python3-certbot-nginx ruby-full nodejs npm rsync jq
    ].freeze

    def initialize(config:, runner:, repo_root:)
      @config = config
      @runner = runner
      @repo_root = repo_root
    end

    def install(interactive: false, remove_nginx_default_site: nil)
      @remove_nginx_default_site = remove_nginx_default_site
      @runner.run('apt-get', 'update')
      @runner.run('apt-get', 'install', '-y', *PACKAGES)
      DeployUser.new(config: @config, runner: @runner).ensure!
      RubyRuntime.new(config: @config, runner: @runner).ensure!
      install_cli
      install_directories
      install_templates
      verify_install
    end

    private

    def install_cli
      source = File.join(@repo_root, 'bin', 'mitsubachi-infra')
      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0755', source, '/usr/local/bin/mitsubachi-infra')
    end

    def install_directories
      deploy_user = @config.fetch('deploy').fetch('user')
      @runner.run('install', '-d', '-o', deploy_user, '-g', deploy_user, '-m', '0755',
                  @config.backend_root, File.join(@config.backend_root, 'releases'), @config.backend_repository_cache,
                  @config.frontend_root, File.join(@config.frontend_root, 'releases'),
                  @config.frontend_repository_cache)
      @runner.run('install', '-d', '-o', 'root', '-g', 'root', '-m', '0755', '/var/lib/mitsubachi/acme')
      @runner.run('install', '-d', '-o', 'root', '-g', @config.fetch('deploy').fetch('user'), '-m', '0750',
                  '/etc/mitsubachi')
    end

    def install_templates
      systemd = Systemd.new(runner: @runner)
      nginx = Nginx.new(config: @config, runner: @runner, repo_root: @repo_root)
      nginx.install(mode: @config.public? ? 'public_http_challenge' : 'lan',
                    remove_default_site: remove_nginx_default_site?)
      install_systemd_unit('mitsubachi-api.service', 'mitsubachi-api.service.erb')
      install_systemd_unit('mitsubachi-worker.service', 'mitsubachi-jobs.service.erb')
      systemd.daemon_reload
      systemd.enable('mitsubachi-api.service')
      systemd.restart('mitsubachi-api.service')
      systemd.enable_now('mitsubachi-worker.service')
      enable_https_if_possible(nginx) if @config.public?
    end

    def install_systemd_unit(unit_name, template)
      unit = ERB.new(File.read(File.join(@repo_root, 'templates', 'systemd', template)),
                     trim_mode: '-').result(binding)
      tmp = "/tmp/#{unit_name}.#{$PROCESS_ID}"
      File.write(tmp, unit)
      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0644', tmp,
                  "/etc/systemd/system/#{unit_name}")
    ensure
      FileUtils.rm_f(tmp) if tmp
    end

    def enable_https_if_possible(nginx)
      Certbot.new(config: @config, runner: @runner, nginx: nginx,
                  health: HealthCheck.new(logger: $stderr)).enable(staging: @config.fetch('https').fetch('staging'))
    rescue Error => e
      warn "warning: HTTPS enable failed; keeping HTTP configuration: #{e.message}"
    end

    def remove_nginx_default_site?
      return @remove_nginx_default_site unless @remove_nginx_default_site.nil?

      @config.fetch('nginx').fetch('remove_default_site')
    end

    def verify_install
      @runner.run('nginx', '-t')
      @runner.run('systemctl', 'is-active', '--quiet', 'mitsubachi-api.service')
      @runner.run('systemctl', 'is-active', '--quiet', 'mitsubachi-worker.service')
      health_url = "http://127.0.0.1:#{@config.fetch('ports').fetch('rails')}#{@config.fetch('backend').fetch('health_path')}/ready"
      @runner.run('curl', '-fsS', '-H', "Host: #{@config.health_host}", health_url)
      nginx_url = @config.public? ? "http://127.0.0.1#{@config.fetch('backend').fetch('health_path')}/ready" : "http://#{@config.fetch('server_ip')}#{@config.fetch('backend').fetch('health_path')}/ready"
      @runner.run('curl', '-fsS', '-H', "Host: #{@config.health_host}", nginx_url)
      @runner.run('ss', '-ltn')
      @runner.deploy('ruby', '-e', "abort RUBY_VERSION unless RUBY_VERSION == #{@config.fetch('runtime').fetch('ruby_version').inspect}",
                     config: @config)
    end
  end
end
