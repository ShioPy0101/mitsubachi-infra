# frozen_string_literal: true

require 'English'
require 'erb'
require 'fileutils'
require 'time'
require 'yaml'
require_relative 'atomic_writer'
require_relative 'certbot'
require_relative 'deploy_user'
require_relative 'env_templates'
require_relative 'health_check'
require_relative 'nginx'
require_relative 'node_runtime'
require_relative 'postgresql'
require_relative 'ruby_runtime'
require_relative 'systemd'

module MitsubachiInfra
  class Installer
    CLI_ROOT = '/opt/mitsubachi-infra'
    CLI_LINK = '/usr/local/bin/mitsubachi-infra'
    PACKAGES = %w[
      git curl ca-certificates build-essential postgresql postgresql-contrib
      nginx ufw certbot python3-certbot-nginx ruby-full rsync jq
    ].freeze

    def initialize(config:, runner:, repo_root:, input: $stdin, output: $stderr, cli_root: CLI_ROOT, cli_link: CLI_LINK,
                   health: HealthCheck.new(logger: $stderr))
      @config = config
      @runner = runner
      @repo_root = repo_root
      @input = input
      @output = output
      @cli_root = cli_root
      @cli_link = cli_link
      @health = health
      @config_changed = false
    end

    def install(interactive: false, remove_nginx_default_site: nil)
      @remove_nginx_default_site = remove_nginx_default_site
      prepare_configuration(interactive: interactive)
      @runner.run('apt-get', 'update')
      @runner.run('apt-get', 'install', '-y', *PACKAGES)
      NodeRuntime.new(config: @config, runner: @runner).ensure!
      DeployUser.new(config: @config, runner: @runner).ensure!
      save_config_if_changed
      RubyRuntime.new(config: @config, runner: @runner).ensure!
      install_cli
      install_directories
      install_env_files
      install_templates
      verify_install
      print_completion_summary
    end

    private

    def install_cli
      release = File.join(@cli_root, 'releases', Time.now.utc.strftime('%Y%m%dT%H%M%SZ') + "-#{$PROCESS_ID}")
      tmp = "#{release}.tmp"
      current_tmp = File.join(@cli_root, ".current.tmp.#{$PROCESS_ID}")
      link_tmp = "#{@cli_link}.tmp.#{$PROCESS_ID}"

      if @runner.dry_run
        @runner.run('install', '-d', '-o', 'root', '-g', 'root', '-m', '0755', File.dirname(@cli_root), @cli_root,
                    File.join(@cli_root, 'releases'))
        @runner.run('ln', '-sfn', File.join(@cli_root, 'current', 'bin', 'mitsubachi-infra'), @cli_link)
        return
      end

      FileUtils.rm_rf(tmp)
      FileUtils.mkdir_p(File.join(tmp, 'bin'))
      FileUtils.mkdir_p(File.join(tmp, 'lib'))
      FileUtils.cp(File.join(@repo_root, 'bin', 'mitsubachi-infra'), File.join(tmp, 'bin', 'mitsubachi-infra'))
      FileUtils.chmod(0o755, File.join(tmp, 'bin', 'mitsubachi-infra'))
      FileUtils.cp_r(File.join(@repo_root, 'lib', 'mitsubachi_infra'), File.join(tmp, 'lib'))
      FileUtils.mkdir_p(File.join(@cli_root, 'releases'))
      FileUtils.mv(tmp, release)
      @runner.run('chown', '-R', 'root:root', release) if Process.euid.zero?
      FileUtils.ln_sf(release, current_tmp)
      FileUtils.mv(current_tmp, File.join(@cli_root, 'current'), force: true)
      FileUtils.ln_sf(File.join(@cli_root, 'current', 'bin', 'mitsubachi-infra'), link_tmp)
      FileUtils.mv(link_tmp, @cli_link, force: true)
    rescue StandardError
      FileUtils.rm_rf(tmp) if tmp
      FileUtils.rm_rf(release) if release && !File.symlink?(File.join(@cli_root, 'current'))
      FileUtils.rm_f(current_tmp) if current_tmp
      FileUtils.rm_f(link_tmp) if link_tmp
      raise
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

    def install_env_files
      rails_path = @config.fetch('paths').fetch('rails_env')
      frontend_path = @config.fetch('paths').fetch('frontend_env')
      return @output.puts("[DRY-RUN] write #{rails_path} and #{frontend_path}") if @runner.dry_run

      writer = AtomicWriter.new(runner: @runner)
      writer.write(rails_path, EnvTemplates.rails_env(@config), owner: 'root',
                   group: @config.fetch('deploy').fetch('user'), mode: '0640') unless File.exist?(rails_path)
      writer.write(frontend_path, EnvTemplates.frontend_env(@config), owner: 'root',
                   group: @config.fetch('deploy').fetch('user'), mode: '0640')
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
      check_service_active('mitsubachi-api.service')
      check_service_active('mitsubachi-worker.service')
      health_url = "http://127.0.0.1:#{@config.fetch('ports').fetch('rails')}#{@config.fetch('backend').fetch('health_path')}/ready"
      begin
        @health.check!(health_url, attempts: 30, delay: 1, dry_run: @runner.dry_run, host: @config.health_host,
                                  open_timeout: 2, read_timeout: 5)
      rescue Error
        service_diagnostics('mitsubachi-api.service')
        raise
      end
      @runner.run('ss', '-ltn')
      @runner.deploy('ruby', '-e', "abort RUBY_VERSION unless RUBY_VERSION == #{@config.fetch('runtime').fetch('ruby_version').inspect}",
                     config: @config)
    end

    def prepare_configuration(interactive:)
      interactive ? prompt_missing_settings : reject_missing_settings!
      @config.validate!
      print_summary
      confirm! if interactive
    rescue ValidationError => e
      raise ValidationError, "#{e.message}\n#{configuration_hint}"
    end

    def reject_missing_settings!
      missing = @config.missing_required_settings
      return if missing.empty?

      raise ValidationError, "missing required configuration: #{missing.join(', ')}"
    end

    def prompt_missing_settings
      ask_choice('deployment_mode', 'Deployment mode', %w[lan public]) unless %w[lan public].include?(@config.fetch('deployment_mode').to_s)
      if @config.lan?
        ask_value('server_ip', 'LAN server private IPv4') if @config.fetch('server_ip').to_s.empty?
      else
        ask_value('domains.frontend', 'Frontend domain') if @config.fetch('domains').fetch('frontend').to_s.empty?
        ask_value('domains.api', 'API domain') if @config.fetch('domains').fetch('api').to_s.empty?
        ask_value('https.email', 'Certbot email') if @config.fetch('https').fetch('email').to_s.empty?
      end
      ask_value('ports.rails', 'Rails internal port') if @config.fetch('ports').fetch('rails').to_s.empty?
      ask_value('runtime.ruby_version', 'Ruby version') if @config.fetch('runtime').fetch('ruby_version').to_s.empty?
      ask_value('runtime.node_major', 'Node.js major version') if @config.fetch('runtime').fetch('node_major').to_s.empty?
      ask_value('backend.repository', 'Backend repository') if @config.fetch('backend').fetch('repository').to_s.empty?
      ask_value('frontend.repository', 'Frontend repository') if @config.fetch('frontend').fetch('repository').to_s.empty?
      ask_value('backend.ref', 'Backend deploy ref') if @config.fetch('backend').fetch('ref').to_s.empty?
      ask_value('frontend.ref', 'Frontend deploy ref') if @config.fetch('frontend').fetch('ref').to_s.empty?
    end

    def ask_choice(path, label, choices)
      loop do
        value = ask_value(path, "#{label} (#{choices.join('/')})", validate: false)
        return if choices.include?(value)

        @output.puts("invalid #{path}: choose #{choices.join(' or ')}")
      end
    end

    def ask_value(path, label, validate: true)
      current = nested_value(path)
      loop do
        @output.print("#{label}#{current.to_s.empty? ? '' : " [#{current}]"}: ")
        line = @input.gets
        raise ValidationError, "interactive input ended before #{path} was provided" if line.nil?

        value = line.strip
        value = current if value.empty? && !current.to_s.empty?
        if value.to_s.empty?
          @output.puts("#{path} is required")
          next
        end
        @config.set(path, coerce_value(path, value))
        @config_changed = true
        @config.validate! if validate
        return value
      rescue ValidationError => e
        @output.puts(e.message)
      end
    end

    def nested_value(path)
      path.split('.').reduce(@config.data) { |acc, key| acc.fetch(key) }
    end

    def coerce_value(path, value)
      path.start_with?('ports.', 'runtime.node_major') ? Integer(value) : value
    rescue ArgumentError
      value
    end

    def print_summary
      @output.puts('Install summary:')
      @output.puts("  mode: #{@config.fetch('deployment_mode')}")
      @output.puts("  server_ip: #{@config.fetch('server_ip') || '(not used)'}")
      @output.puts("  frontend domain: #{@config.fetch('domains').fetch('frontend')}")
      @output.puts("  api domain: #{@config.fetch('domains').fetch('api')}")
      @output.puts("  rails port: #{@config.fetch('ports').fetch('rails')}")
      @output.puts("  ruby: #{@config.fetch('runtime').fetch('ruby_version')}")
      @output.puts("  node major: #{@config.fetch('runtime').fetch('node_major')}")
      @output.puts("  backend: #{@config.fetch('backend').fetch('repository')} #{@config.fetch('backend').fetch('ref')}")
      @output.puts("  frontend: #{@config.fetch('frontend').fetch('repository')} #{@config.fetch('frontend').fetch('ref')}")
      @output.puts("  config: #{@config.path}")
    end

    def confirm!
      @output.print('Continue install? [y/N]: ')
      answer = @input.gets
      raise ValidationError, 'interactive input ended before confirmation' if answer.nil?
      return if answer.strip.downcase == 'y'

      raise ValidationError, 'install cancelled'
    end

    def save_config_if_changed
      return unless @config_changed
      return @output.puts("[DRY-RUN] write #{@config.path}") if @runner.dry_run

      writer = AtomicWriter.new(runner: @runner)
      writer.write(@config.path, @config.data.to_yaml, owner: 'root', group: @config.fetch('deploy').fetch('user'),
                   mode: '0640')
    end

    def check_service_active(unit)
      @runner.run('systemctl', 'is-active', '--quiet', unit)
    rescue Error
      service_diagnostics(unit)
      raise
    end

    def service_diagnostics(unit)
      @runner.run('systemctl', 'status', unit, '--no-pager', allow_failure: true)
      @runner.run('journalctl', '-u', unit, '-n', '100', '--no-pager', allow_failure: true)
      @runner.run('ss', '-ltnp', allow_failure: true)
    end

    def configuration_hint
      <<~HINT.chomp
        Configure /etc/mitsubachi/config.yml. Example:
          deployment_mode: lan
          server_ip: 192.168.10.151
      HINT
    end

    def print_completion_summary
      @output.puts('Install completed. PostgreSQL role/database initialization is not part of this Ruby install phase.')
      @output.puts('Next: create/update /etc/mitsubachi/rails.env secrets, deploy backend/frontend, then check services.')
    end
  end
end
