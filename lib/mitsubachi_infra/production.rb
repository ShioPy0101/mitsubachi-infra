# frozen_string_literal: true

require 'English'
require 'erb'
require 'etc'
require 'fileutils'
require 'json'
require 'net/http'
require 'securerandom'
require 'time'
require 'tmpdir'
require 'uri'
require_relative 'caddy'
require_relative 'certbot'
require_relative 'deploy_user'
require_relative 'env_templates'
require_relative 'errors'
require_relative 'health_check'
require_relative 'nginx'
require_relative 'ruby_runtime'
require_relative 'systemd'

module MitsubachiInfra
  class Production
    API_SERVICE = 'mitsubachi-api.service'
    JOBS_SERVICE = 'mitsubachi-worker.service'

    def initialize(config:, repo_root:, runner:, logger:)
      @config = config
      @repo_root = repo_root
      @runner = runner
      @logger = logger
    end

    def bootstrap
      warn_dirty_infra_tree
      check_server_id(allow_create: true)
      install_packages
      ensure_deploy_user
      RubyRuntime.new(config: deploy_config, runner: @runner).ensure!
      install_directories
      install_env_files
      install_systemd_units
      install_nginx
      configure_ufw
      production_check
    end

    def deploy(target, backend_ref: nil, frontend_ref: nil)
      warn_dirty_infra_tree
      check_server_id
      case target
      when 'backend' then deploy_backend(ref: backend_ref)
      when 'frontend' then deploy_frontend(ref: frontend_ref)
      when 'all'
        deploy_backend(ref: backend_ref)
        deploy_frontend(ref: frontend_ref)
      else
        raise ValidationError, 'deploy target must be all, backend, or frontend'
      end
    end

    def rollback(target)
      check_server_id
      case target
      when 'backend' then rollback_root(@config.fetch('paths').fetch('rails_root'),
                                        restart: [API_SERVICE, JOBS_SERVICE])
      when 'frontend' then rollback_root(@config.fetch('paths').fetch('frontend_root'), restart: [])
      when 'all'
        rollback_root(@config.fetch('paths').fetch('rails_root'), restart: [API_SERVICE, JOBS_SERVICE])
        rollback_root(@config.fetch('paths').fetch('frontend_root'), restart: [])
      else
        raise ValidationError, 'rollback target must be all, backend, or frontend'
      end
    end

    def production_check
      check_server_id unless @runner.dry_run
      @logger.puts('[LOCAL] Running on production host')
      @logger.puts("[LOCAL] Deploy user: #{success?('id', deploy_user) ? 'ok' : 'missing'}")
      @logger.puts("[LOCAL] Nginx active: #{if privileged_success?('systemctl', 'is-active', '--quiet',
                                                                   'nginx')
                                              'yes'
                                            else
                                              'no'
                                            end}")
      @logger.puts("[LOCAL] Rails API service: #{if privileged_success?('systemctl', 'is-active', '--quiet',
                                                                        API_SERVICE)
                                                   'active'
                                                 else
                                                   'inactive'
                                                 end}")
      @logger.puts("[LOCAL] Solid Queue worker: #{if privileged_success?('systemctl', 'is-active', '--quiet',
                                                                         JOBS_SERVICE)
                                                    'active'
                                                  else
                                                    'inactive'
                                                  end}")
      @logger.puts("[LOCAL] Nginx validation: #{privileged_success?('nginx', '-t') ? 'ok' : 'failed'}")
      @logger.puts("[LOCAL] Minecraft ports preserved in configuration: #{minecraft_ports.join(', ')}")
      @logger.puts("[EXTERNAL] Frontend HTTPS: #{http_ok?(@config.production_frontend_url) ? 'OK' : 'not verified'}")
      @logger.puts("[EXTERNAL] API HTTPS: #{http_ok?("#{@config.production_api_url}#{@config.fetch('backend').fetch('health_path')}") ? 'OK' : 'not verified'}")
    end

    def doctor
      @logger.puts("[LOCAL] Ruby: #{RUBY_VERSION}")
      @logger.puts("[LOCAL] Git: #{success?('git', '--version') ? 'ok' : 'missing'}")
      @logger.puts("[LOCAL] Nginx: #{success?('which', 'nginx') ? 'ok' : 'missing'}")
      production_check
    end

    def mail_test(to:)
      raise ValidationError, '--to is required' if to.to_s.empty?

      check_server_id
      script = <<~RUBY
        raise "MAIL_FROM is not configured" if ENV["MAIL_FROM"].to_s.empty?
        raise "RESEND_API_KEY is not configured" if ENV["RESEND_API_KEY"].to_s.empty?
        ActionMailer::Base.mail(to: #{to.inspect}, from: ENV.fetch("MAIL_FROM"), subject: "Mitsubachi production mail test", body: "Mitsubachi production mail test.").deliver_now
        puts "mail-test delivered"
      RUBY
      @runner.deploy('bundle', 'exec', 'rails', 'runner', script,
                     config: deploy_config,
                     chdir: File.join(@config.fetch('paths').fetch('rails_root'), 'current'),
                     timeout: 300)
    end

    private

    def deploy_backend(ref: nil)
      root = @config.fetch('paths').fetch('rails_root')
      app = @config.fetch('backend')
      release = create_git_release(root: root, repository: app.fetch('repository'), ref: ref || app.fetch('ref'),
                                   label: 'backend')
      previous = current_release(root)
      begin
        install_backend(release)
        activate(root, release)
        privileged('systemctl', 'restart', API_SERVICE)
        privileged('systemctl', 'restart', JOBS_SERVICE)
        privileged('systemctl', 'is-active', '--quiet', API_SERVICE)
        privileged('systemctl', 'is-active', '--quiet', JOBS_SERVICE)
        cleanup(root, keep: app.fetch('keep_releases'), protected_paths: [previous].compact)
      rescue StandardError
        FileUtils.rm_rf(release) unless @runner.dry_run || current_release(root) == release
        if previous && current_release(root) == release
          activate(root, previous)
          privileged('systemctl', 'restart', API_SERVICE, allow_failure: true)
          privileged('systemctl', 'restart', JOBS_SERVICE, allow_failure: true)
        end
        raise
      end
    end

    def deploy_frontend(ref: nil)
      root = @config.fetch('paths').fetch('frontend_root')
      app = @config.fetch('frontend')
      release = create_git_release(root: root, repository: app.fetch('repository'), ref: ref || app.fetch('ref'),
                                   label: 'frontend')
      begin
        @runner.deploy('npm', 'ci', config: deploy_config, chdir: release, timeout: 1800)
        @runner.deploy(*app.fetch('build_command'), config: deploy_config, chdir: release, timeout: 1800,
                                                    env: frontend_env)
        index = File.join(release, app.fetch('output_directory'), 'index.html')
        raise Error, "frontend build output missing index.html: #{index}" unless @runner.dry_run || File.exist?(index)

        activate(root, release)
        cleanup(root, keep: app.fetch('keep_releases'))
      rescue StandardError
        FileUtils.rm_rf(release) unless @runner.dry_run || current_release(root) == release
        raise
      end
    end

    def create_git_release(root:, repository:, ref:, label:)
      unless ref.match?(/\A[0-9a-f]{7,40}\z/i)
        @runner.deploy('git', 'ls-remote', '--exit-code', repository, ref, config: deploy_config, timeout: 120)
      end
      release = File.join(root, 'releases', release_name(label))
      @runner.deploy('git', 'clone', '--no-checkout', repository, release, config: deploy_config, timeout: 1800)
      @runner.deploy('git', 'fetch', '--prune', 'origin', ref, config: deploy_config, chdir: release, timeout: 1800)
      sha = @runner.deploy('git', 'rev-parse', '--verify', 'FETCH_HEAD^{commit}', config: deploy_config,
                                                                                  chdir: release).stdout.strip
      @runner.deploy('git', 'checkout', '--detach', sha, config: deploy_config, chdir: release)
      write_release_info(release, repository: repository, requested_ref: ref, resolved_sha: sha)
      release
    end

    def install_backend(release)
      ensure_required_rails_env!
      install_bundler(release)
      @runner.deploy('bundle', 'config', 'set', '--local', 'deployment', 'true', config: deploy_config, chdir: release)
      @runner.deploy('bundle', 'config', 'set', '--local', 'without', 'development test', config: deploy_config,
                                                                                          chdir: release)
      @runner.deploy('bundle', 'install', config: deploy_config, chdir: release, timeout: 1800)
      @runner.deploy('bundle', 'exec', 'rails', 'db:migrate', config: deploy_config, chdir: release, timeout: 1800)
      @runner.deploy('test', '-f', 'bin/jobs', config: deploy_config, chdir: release)
      @runner.deploy('bundle', 'exec', 'rails', 'runner',
                     "abort 'queue adapter is not solid_queue' unless Rails.application.config.active_job.queue_adapter.to_s == 'solid_queue'", config: deploy_config, chdir: release)
    end

    def install_bundler(release)
      lock = File.join(release, 'Gemfile.lock')
      return unless File.exist?(lock)

      version = File.readlines(lock).each_cons(2).find { |a, _b| a.strip == 'BUNDLED WITH' }&.last&.strip
      return if version.to_s.empty?

      return if @runner.deploy('gem', 'list', '--installed', '--exact', 'bundler', '--version', version,
                               config: deploy_config, allow_failure: true).success?

      @runner.deploy('gem', 'install', 'bundler', '--version', version, '--no-document', config: deploy_config)
    end

    def install_packages
      privileged('apt-get', 'update', timeout: 1800)
      privileged('apt-get', 'install', '-y', 'git', 'curl', 'ca-certificates', 'build-essential', 'ruby-full',
                 'postgresql-client', 'nginx', 'ufw', 'certbot', 'python3-certbot-nginx', 'rsync', 'nodejs', 'npm',
                 timeout: 1800)
    end

    def ensure_deploy_user
      DeployUser.new(config: deploy_config, runner: @runner).ensure!
    end

    def install_directories
      [@config.fetch('paths').fetch('rails_root'), @config.fetch('paths').fetch('frontend_root')].each do |root|
        privileged('install', '-d', '-o', deploy_user, '-g', deploy_user, '-m', '0755', root,
                   File.join(root, 'releases'), File.join(root, 'shared'))
      end
      privileged('install', '-d', '-o', 'root', '-g', deploy_user, '-m', '0750', '/etc/mitsubachi')
    end

    def install_env_files
      rails_path = @config.fetch('paths').fetch('rails_env')
      frontend_path = @config.fetch('paths').fetch('frontend_env')
      unless File.exist?(rails_path) || @runner.dry_run
        atomic_write(rails_path, EnvTemplates.rails_env(@config), owner: 'root', group: deploy_user,
                                                                  mode: '0640')
      end
      atomic_write(frontend_path, EnvTemplates.frontend_env(@config), owner: 'root', group: deploy_user, mode: '0640')
    end

    def install_systemd_units
      {
        API_SERVICE => 'mitsubachi-api.service.erb',
        JOBS_SERVICE => 'mitsubachi-jobs.service.erb'
      }.each do |unit, template|
        content = ERB.new(File.read(File.join(@repo_root, 'templates', 'systemd', template)),
                          trim_mode: '-').result(binding)
        atomic_write("/etc/systemd/system/#{unit}", content, owner: 'root', group: 'root', mode: '0644')
        privileged('systemctl', 'enable', unit)
      end
      privileged('systemctl', 'daemon-reload')
    end

    def install_nginx
      nginx = Nginx.new(config: @config, runner: @runner, repo_root: @repo_root)
      nginx.install(mode: @config.public? ? 'public_http_challenge' : 'lan')
      return unless @config.public?

      Certbot.new(config: @config, runner: @runner, nginx: nginx,
                  health: HealthCheck.new(logger: @logger)).enable(staging: @config.fetch('https').fetch('staging'))
    rescue Error => e
      @logger.puts("warning: HTTPS enable failed; keeping HTTP configuration: #{e.message}")
    end

    def configure_ufw
      privileged('ufw', 'allow', "#{@config.fetch('ports').fetch('http')}/tcp")
      privileged('ufw', 'allow', "#{@config.fetch('ports').fetch('https')}/tcp")
      privileged('ufw', 'allow', '22/tcp')
      minecraft_ports.each { |port| privileged('ufw', 'allow', "#{port}/tcp") }
    end

    def check_server_id(allow_create: false)
      expected = @config.fetch('server')['server_id'].to_s
      raise ValidationError, 'server.server_id is required' if expected.empty?

      path = @config.fetch('paths').fetch('server_id')
      actual = File.exist?(path) ? File.read(path).strip : ''
      if actual.empty? && allow_create
        atomic_write(path, "#{expected}\n", owner: 'root', group: 'root', mode: '0644')
        return
      end
      return if actual == expected

      raise ValidationError,
            "server ID mismatch: expected #{expected}, got #{actual.empty? ? '(missing)' : actual}"
    end

    def ensure_required_rails_env!
      path = @config.fetch('paths').fetch('rails_env')
      text = File.exist?(path) ? File.read(path) : ''
      required = %w[DATABASE_URL DATABASE_CACHE_URL DATABASE_QUEUE_URL DATABASE_CABLE_URL RAILS_MASTER_KEY
                    SECRET_KEY_BASE RESEND_API_KEY MAIL_FROM]
      missing = required.reject { |key| text.match?(/^#{Regexp.escape(key)}=.+/) }
      raise Error, "missing Rails env keys: #{missing.join(', ')}" unless missing.empty? || @runner.dry_run
    end

    def frontend_env
      path = @config.fetch('paths').fetch('frontend_env')
      return {} if @runner.dry_run && !File.exist?(path)

      File.readlines(path, chomp: true).each_with_object({}) do |line, env|
        next if line.strip.empty? || line.start_with?('#')

        key, value = line.split('=', 2)
        env[key] = value.to_s if key&.match?(/\A[A-Z0-9_]+\z/)
      end
    end

    def rollback_root(root, restart:)
      current = current_release(root)
      target = (release_paths(root) - [current]).last
      raise Error, "rollback target release is missing under #{root}" unless target

      activate(root, target)
      restart.each { |unit| privileged('systemctl', 'restart', unit) }
    end

    def activate(root, release)
      tmp = File.join(root, ".current.tmp.#{$PROCESS_ID}")
      FileUtils.ln_sf(release, tmp) unless @runner.dry_run
      FileUtils.mv(tmp, File.join(root, 'current'), force: true) unless @runner.dry_run
    end

    def cleanup(root, keep:, protected_paths: [])
      protected = ([current_release(root)] + protected_paths).compact.map do |path|
        File.realpath(path)
      rescue StandardError
        path
      end
      candidates = release_paths(root)
      candidates[0, [candidates.length - keep.to_i, 0].max].each do |path|
        real = begin
          File.realpath(path)
        rescue StandardError
          path
        end
        next if protected.include?(real)

        FileUtils.rm_rf(path) unless @runner.dry_run
      end
    end

    def release_paths(root)
      Dir.glob(File.join(root, 'releases', '*')).select do |path|
        File.directory?(path)
      end.sort_by { |path| File.mtime(path) }
    end

    def current_release(root)
      link = File.join(root, 'current')
      File.symlink?(link) ? File.realpath(link) : nil
    rescue Errno::ENOENT
      nil
    end

    def write_release_info(release, repository:, requested_ref:, resolved_sha:)
      return if @runner.dry_run

      File.write(File.join(release, 'REVISION'), "#{resolved_sha}\n")
      File.write(File.join(release, 'release.json'), {
        repository: repository,
        requested_ref: requested_ref,
        resolved_commit_sha: resolved_sha,
        deployed_by: Etc.getlogin || ENV.fetch('USER', 'unknown'),
        deploy_started_at: Time.now.utc.iso8601
      }.to_json)
    end

    def atomic_write(path, content, owner:, group:, mode:)
      return @logger.puts("[DRY-RUN] write #{path}") if @runner.dry_run

      dir = File.dirname(path)
      tmp = File.join(Dir.tmpdir, ".#{File.basename(path)}.#{$PROCESS_ID}.tmp")
      File.write(tmp, content)
      File.chmod(mode.to_i(8), tmp)
      privileged('install', '-d', '-m', '0755', dir)
      privileged('cp', '-a', path, "#{path}.backup.#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}") if File.exist?(path)
      privileged('install', '-o', owner, '-g', group, '-m', mode, tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end

    def warn_dirty_infra_tree
      result = @runner.run('git', 'status', '--short', allow_failure: true)
      return if result.stdout.strip.empty?

      @logger.puts('[LOCAL] warning: mitsubachi-infra working tree has uncommitted changes')
    end

    def success?(*command)
      @runner.run(*command, allow_failure: true).success?
    end

    def privileged_success?(*command)
      privileged(*command, allow_failure: true).success?
    end

    def privileged(*command, **options)
      if Process.euid.zero?
        @runner.run(*command, **options)
      else
        @runner.run('sudo', '-n', *command, **options)
      end
    end

    def http_ok?(url)
      return true if @runner.dry_run

      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 5) { |http| http.get(uri.request_uri) }
      response.code.to_i == 200
    rescue StandardError
      false
    end

    def release_name(label)
      "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{label}-#{$PROCESS_ID}-#{SecureRandom.hex(3)}"
    end

    def deploy_config
      @deploy_config ||= Configuration.new(@config.path, data: @config.data.merge('deploy' => {
                                                                                    'user' => deploy_user,
                                                                                    'home' => "/home/#{deploy_user}",
                                                                                    'app_root' => File.dirname(@config.fetch('paths').fetch('rails_root'))
                                                                                  }))
    end

    def deploy_user
      @config.fetch('server').fetch('deploy_user')
    end

    def minecraft_ports
      @config.fetch('ports').fetch('minecraft')
    end
  end
end
