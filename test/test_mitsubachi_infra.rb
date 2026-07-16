# frozen_string_literal: true

require 'minitest/autorun'
require 'erb'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT, 'lib'))

require 'mitsubachi_infra/command_runner'
require 'mitsubachi_infra/configuration'
require 'mitsubachi_infra/caddy'
require 'mitsubachi_infra/nginx'
require 'mitsubachi_infra/deployment/release_manager'
require 'mitsubachi_infra/errors'
require 'mitsubachi_infra/production'

class MitsubachiInfraTest < Minitest::Test
  class RecordingRunner
    attr_reader :commands
    attr_accessor :dry_run

    def initialize(dry_run: false)
      @dry_run = dry_run
      @commands = []
    end

    def run(*command, **_options)
      @commands << command.flatten.map(&:to_s)
      MitsubachiInfra::CommandRunner::Result.new(stdout: '', stderr: '', status: 0)
    end
  end

  class NginxFilesystemRunner
    attr_reader :commands
    attr_accessor :dry_run

    def initialize(nginx_statuses: [0], dry_run: false)
      @nginx_statuses = nginx_statuses.dup
      @dry_run = dry_run
      @commands = []
    end

    def run(*command, allow_failure: false, **_options)
      argv = command.flatten.map(&:to_s)
      @commands << argv
      return nginx_result(allow_failure: allow_failure) if argv == %w[nginx -t]

      apply_filesystem_command(argv) unless dry_run
      MitsubachiInfra::CommandRunner::Result.new(stdout: '', stderr: '', status: 0)
    end

    def mask(text)
      text.to_s
    end

    private

    def nginx_result(allow_failure:)
      status = @nginx_statuses.length > 1 ? @nginx_statuses.shift : @nginx_statuses.first
      result = MitsubachiInfra::CommandRunner::Result.new(stdout: '', stderr: nginx_stderr(status), status: status)
      raise MitsubachiInfra::CommandError.new(command: %w[nginx -t], status: status, stdout: '', stderr: result.stderr) if status != 0 && !allow_failure

      result
    end

    def nginx_stderr(status)
      return '' if status.zero?

      'nginx: [emerg] duplicate default server'
    end

    def apply_filesystem_command(argv)
      if argv[0, 7] == ['install', '-o', 'root', '-g', 'root', '-m', '0644']
        FileUtils.mkdir_p(File.dirname(argv[8]))
        FileUtils.cp(argv[7], argv[8])
      elsif argv[0, 2] == ['cp', '-a']
        FileUtils.cp(argv[2], argv[3])
      elsif argv[0, 2] == ['rm', '-f']
        FileUtils.rm_f(argv[2])
      elsif argv[0, 2] == ['ln', '-sfn']
        FileUtils.mkdir_p(File.dirname(argv[3]))
        FileUtils.rm_f(argv[3])
        FileUtils.ln_sf(argv[2], argv[3])
      end
    end
  end

  def config_data(overrides = {})
    MitsubachiInfra::Configuration::DEFAULT.merge(overrides)
  end

  def nginx_paths(root)
    {
      nginx_conf: File.join(root, 'nginx.conf'),
      conf_d: File.join(root, 'conf.d'),
      sites_enabled: File.join(root, 'sites-enabled'),
      target: File.join(root, 'sites-available', 'mitsubachi.conf'),
      enabled: File.join(root, 'sites-enabled', 'mitsubachi.conf'),
      ubuntu_default: File.join(root, 'sites-enabled', 'default')
    }
  end

  def build_nginx(config, runner, paths, logger: StringIO.new)
    MitsubachiInfra::Nginx.new(config: config, runner: runner, repo_root: ROOT, logger: logger, **paths)
  end

  def prepare_nginx_tree(root)
    paths = nginx_paths(root)
    FileUtils.mkdir_p([paths[:conf_d], paths[:sites_enabled], File.dirname(paths[:target])])
    File.write(paths[:nginx_conf], "events {}\nhttp { include #{paths[:conf_d]}/*; include #{paths[:sites_enabled]}/*; }\n")
    paths
  end

  def test_invalid_deployment_mode
    assert_raises(MitsubachiInfra::ValidationError) do
      MitsubachiInfra::Configuration.new('/missing', data: config_data('deployment_mode' => 'bad'))
    end
  end

  def test_public_hostname_validation
    %w[localhost 127.0.0.1 https://files.example.com files.example.com/path].each do |host|
      data = config_data('deployment_mode' => 'public',
                         'https' => { 'host' => host, 'email' => 'ops@example.com',
                                      'challenge' => 'http-01' })
      assert_raises(MitsubachiInfra::ValidationError) { MitsubachiInfra::Configuration.new('/missing', data: data) }
    end
  end

  def test_public_config_accepts_hostname_and_email
    data = config_data('deployment_mode' => 'public',
                       'https' => { 'host' => 'files.example.com', 'email' => 'ops@example.com',
                                    'challenge' => 'http-01' })
    assert_equal 'public', MitsubachiInfra::Configuration.new('/missing', data: data).fetch('deployment_mode')
  end

  def test_frontend_output_directory_rejects_traversal
    data = config_data('frontend' => MitsubachiInfra::Configuration::DEFAULT.fetch('frontend').merge('output_directory' => '../dist'))
    assert_raises(MitsubachiInfra::ValidationError) { MitsubachiInfra::Configuration.new('/missing', data: data) }
  end

  def test_build_command_must_not_be_empty
    data = config_data('frontend' => MitsubachiInfra::Configuration::DEFAULT.fetch('frontend').merge('build_command' => []))
    assert_raises(MitsubachiInfra::ValidationError) { MitsubachiInfra::Configuration.new('/missing', data: data) }
  end

  def test_command_runner_masks_secrets_and_dry_runs
    io = StringIO.new
    runner = MitsubachiInfra::CommandRunner.new(logger: io, dry_run: true)
    result = runner.run('echo', 'DATABASE_URL=postgresql://user:secret@127.0.0.1/db')
    assert result.success?
    refute_includes io.string, 'secret'
    assert_includes io.string, '<redacted>'
  end

  def test_command_runner_runs_when_chdir_is_nil
    runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: false)
    result = runner.run(RbConfig.ruby, '-e', 'print "ok"', chdir: nil)

    assert result.success?
    assert_equal 'ok', result.stdout
  end

  def test_command_runner_runs_when_chdir_is_empty_string
    runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: false)
    result = runner.run(RbConfig.ruby, '-e', 'print "ok"', chdir: '')

    assert result.success?
    assert_equal 'ok', result.stdout
  end

  def test_command_runner_runs_in_chdir_when_specified
    Dir.mktmpdir do |dir|
      runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: false)
      result = runner.run(RbConfig.ruby, '-e', 'print Dir.pwd', chdir: dir)

      assert result.success?
      assert_equal File.realpath(dir), File.realpath(result.stdout)
    end
  end

  def test_command_runner_failure_includes_stderr
    runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: false)
    error = assert_raises(MitsubachiInfra::CommandError) do
      runner.run(RbConfig.ruby, '-e', 'warn "nginx: [emerg] duplicate default server"; exit 7')
    end

    assert_includes error.message, 'status=7'
    assert_includes error.message, 'stderr=nginx: [emerg] duplicate default server'
  end

  def test_command_runner_allow_failure_returns_result
    runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: false)
    result = runner.run(RbConfig.ruby, '-e', 'warn "failed"; exit 3', allow_failure: true)

    refute result.success?
    assert_equal 3, result.status
    assert_includes result.stderr, 'failed'
  end

  def test_command_runner_timeout_mentions_timeout
    runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: false)
    error = assert_raises(MitsubachiInfra::Error) do
      runner.run(RbConfig.ruby, '-e', 'sleep 2', timeout: 0.1)
    end

    assert_includes error.message, 'timed out'
  end

  def test_command_runner_env_and_secret_masking
    io = StringIO.new
    runner = MitsubachiInfra::CommandRunner.new(logger: io, dry_run: false)
    result = runner.run(RbConfig.ruby, '-e', 'print ENV.fetch("MITSUBACHI_TEST")',
                        env: { 'MITSUBACHI_TEST' => :ok, 'SMTP_PASSWORD' => 'hidden' })

    assert_equal 'ok', result.stdout
    refute_includes io.string, 'hidden'
  end

  def test_command_runner_user_nil_does_not_use_sudo
    io = StringIO.new
    runner = MitsubachiInfra::CommandRunner.new(logger: io, dry_run: true)
    runner.run('true', user: nil)

    refute_includes io.string, 'sudo -u'
  end

  def test_command_runner_user_specified_uses_sudo
    io = StringIO.new
    runner = MitsubachiInfra::CommandRunner.new(logger: io, dry_run: true)
    runner.run('true', user: 'deploy')

    assert_includes io.string, 'sudo -u deploy'
  end

  def test_public_http_nginx_separates_frontend_and_api_without_ssl
    config = production_config('/tmp/mitsubachi-test')
    rendered = MitsubachiInfra::Nginx.new(config: config, runner: RecordingRunner.new, repo_root: ROOT)
                                 .render(mode: 'public_http_challenge')

    assert_equal 0, rendered.scan('default_server').length
    refute_includes rendered, 'ssl_certificate'
    assert_includes rendered, 'server_name mitsubachi.shiosalt.com;'
    assert_includes rendered, 'server_name mitsubachi-api.shiosalt.com;'
    assert_includes rendered, '/.well-known/acme-challenge/'
    assert_includes rendered, 'try_files $uri $uri/ /index.html;'
    assert_includes rendered, 'proxy_set_header X-Forwarded-Host $host;'
    assert_includes rendered, 'location /internal/storage/drive_items/'
    assert_includes rendered, 'internal;'
  end

  def test_public_https_nginx_has_redirect_and_separate_ssl_servers
    config = production_config('/tmp/mitsubachi-test')
    rendered = MitsubachiInfra::Nginx.new(config: config, runner: RecordingRunner.new, repo_root: ROOT)
                                 .render(mode: 'public_https')

    assert_includes rendered, 'return 301 https://$host$request_uri;'
    assert_includes rendered, 'server_name mitsubachi.shiosalt.com;'
    assert_includes rendered, 'server_name mitsubachi-api.shiosalt.com;'
    assert_includes rendered, '/etc/letsencrypt/live/mitsubachi.shiosalt.com/fullchain.pem'
    assert_includes rendered, '/etc/letsencrypt/live/mitsubachi-api.shiosalt.com/fullchain.pem'
    assert_includes rendered, 'proxy_pass http://127.0.0.1:3000;'
  end

  def test_nginx_can_render_explicit_default_server
    config = MitsubachiInfra::Configuration.new('/missing', data: config_data('nginx' => {
                                                                                 'default_server' => true,
                                                                                 'remove_default_site' => false
                                                                               }))
    rendered = MitsubachiInfra::Nginx.new(config: config, runner: RecordingRunner.new, repo_root: ROOT)
                                 .render(mode: 'public_http_challenge')

    assert_equal 2, rendered.scan('default_server').length
  end

  def test_nginx_install_removes_ubuntu_default_before_test
    Dir.mktmpdir do |dir|
      paths = prepare_nginx_tree(dir)
      default_available = File.join(dir, 'sites-available', 'default')
      FileUtils.mkdir_p(File.dirname(default_available))
      File.write(default_available, "server { listen 80 default_server; }\n")
      FileUtils.ln_sf(default_available, paths[:ubuntu_default])
      runner = NginxFilesystemRunner.new(nginx_statuses: [0, 0])
      build_nginx(production_config(dir), runner, paths).install(mode: 'public_http_challenge',
                                                                 remove_default_site: true)

      commands = runner.commands.map { |command| command.join(' ') }
      assert commands.any? { |command| command == "rm -f #{paths[:ubuntu_default]}" }
      assert commands.index { |command| command.start_with?("rm -f #{paths[:ubuntu_default]}") } <
             commands.rindex { |command| command == 'nginx -t' }
      assert commands.rindex { |command| command == 'nginx -t' } <
             commands.index { |command| command == 'systemctl reload nginx' }
      refute_path_exists paths[:ubuntu_default]
    end
  end

  def test_nginx_install_succeeds_with_existing_default_site_when_not_default
    Dir.mktmpdir do |dir|
      paths = prepare_nginx_tree(dir)
      default_available = File.join(dir, 'sites-available', 'default')
      FileUtils.mkdir_p(File.dirname(default_available))
      File.write(default_available, "server { listen 80 default_server; }\n")
      FileUtils.ln_sf(default_available, paths[:ubuntu_default])
      runner = NginxFilesystemRunner.new(nginx_statuses: [0, 0])

      build_nginx(production_config(dir), runner, paths).install(mode: 'public_http_challenge')

      assert_path_exists paths[:ubuntu_default]
      assert_path_exists paths[:target]
      assert runner.commands.none? { |command| command == ['rm', '-f', paths[:ubuntu_default]] }
    end
  end

  def test_nginx_detects_default_server_in_other_file_when_candidate_is_default
    Dir.mktmpdir do |dir|
      paths = prepare_nginx_tree(dir)
      File.write(File.join(paths[:conf_d], 'other.conf'), "server { listen 80 default_server; }\n")
      config = MitsubachiInfra::Configuration.new('/missing', data: config_data('nginx' => {
                                                                                 'default_server' => true,
                                                                                 'remove_default_site' => false
                                                                               }))

      error = assert_raises(MitsubachiInfra::Error) do
        build_nginx(config, NginxFilesystemRunner.new(nginx_statuses: [0]), paths).install(mode: 'public_http_challenge')
      end

      assert_includes error.message, 'default_server would be duplicated'
      assert_includes error.message, 'other.conf'
    end
  end

  def test_nginx_install_skips_missing_default_site
    Dir.mktmpdir do |dir|
      paths = prepare_nginx_tree(dir)
      runner = NginxFilesystemRunner.new(nginx_statuses: [0, 0])

      build_nginx(production_config(dir), runner, paths).install(mode: 'public_http_challenge',
                                                                 remove_default_site: true)

      assert runner.commands.none? { |command| command == ['rm', '-f', paths[:ubuntu_default]] }
    end
  end

  def test_nginx_rolls_back_when_nginx_test_fails
    Dir.mktmpdir do |dir|
      paths = prepare_nginx_tree(dir)
      File.write(paths[:target], "old config\n")
      FileUtils.ln_sf(paths[:target], paths[:enabled])
      runner = NginxFilesystemRunner.new(nginx_statuses: [0, 1, 0])

      assert_raises(MitsubachiInfra::CommandError) do
        build_nginx(production_config(dir), runner, paths).install(mode: 'public_http_challenge')
      end

      assert_equal "old config\n", File.read(paths[:target])
      assert_equal paths[:target], File.readlink(paths[:enabled])
      assert_equal 3, runner.commands.count { |command| command == %w[nginx -t] }
      assert runner.commands.none? { |command| command == ['systemctl', 'reload', 'nginx'] }
    end
  end

  def test_nginx_reports_original_and_rollback_errors
    Dir.mktmpdir do |dir|
      paths = prepare_nginx_tree(dir)
      File.write(paths[:target], "old config\n")
      FileUtils.ln_sf(paths[:target], paths[:enabled])
      runner = NginxFilesystemRunner.new(nginx_statuses: [0, 1, 1])

      error = assert_raises(MitsubachiInfra::Error) do
        build_nginx(production_config(dir), runner, paths).install(mode: 'public_http_challenge')
      end

      assert_includes error.message, 'nginx rollback failed'
      assert_includes error.message, 'original_error='
      assert_includes error.message, "restored #{paths[:target]}"
      assert_includes error.message, 'rollback_stderr=nginx: [emerg] duplicate default server'
    end
  end

  def test_nginx_refuses_to_start_when_initial_config_is_broken
    Dir.mktmpdir do |dir|
      paths = prepare_nginx_tree(dir)
      runner = NginxFilesystemRunner.new(nginx_statuses: [1])

      error = assert_raises(MitsubachiInfra::Error) do
        build_nginx(production_config(dir), runner, paths).install(mode: 'public_http_challenge')
      end

      assert_includes error.message, 'existing Nginx configuration is broken'
      refute_path_exists paths[:target]
    end
  end

  def test_nginx_dry_run_does_not_change_files
    Dir.mktmpdir do |dir|
      paths = prepare_nginx_tree(dir)
      File.write(paths[:target], "old config\n")
      runner = NginxFilesystemRunner.new(nginx_statuses: [0, 0], dry_run: true)

      build_nginx(production_config(dir), runner, paths).install(mode: 'public_http_challenge',
                                                                 remove_default_site: true)

      assert_equal "old config\n", File.read(paths[:target])
    end
  end

  def test_release_manager_keeps_current_release
    Dir.mktmpdir do |dir|
      runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: false)
      manager = MitsubachiInfra::Deployment::ReleaseManager.new(root: dir, runner: runner, keep: 1)
      FileUtils.mkdir_p(manager.releases_dir)
      old = File.join(manager.releases_dir, 'old')
      current = File.join(manager.releases_dir, 'current')
      FileUtils.mkdir_p(old)
      sleep 1
      FileUtils.mkdir_p(current)
      manager.activate(current)
      manager.cleanup
      assert_path_exists current
      refute_path_exists old
    end
  end

  def test_release_id_contains_sha_and_random_suffix
    Dir.mktmpdir do |dir|
      runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: true)
      manager = MitsubachiInfra::Deployment::ReleaseManager.new(root: dir, runner: runner, keep: 5)
      id = manager.release_id('abcdef1234567890')
      assert_match(/abcdef123456/, id)
      assert_match(/\d{8}T\d{6}Z-abcdef123456-\d+-[0-9a-f]{6}/, id)
    end
  end

  def production_config(root)
    MitsubachiInfra::Configuration.new('/missing', data: config_data(
      'deployment_mode' => 'public',
      'deploy' => MitsubachiInfra::Configuration::DEFAULT.fetch('deploy').merge('app_root' => File.join(root,
                                                                                                        'legacy')),
      'server' => {
        'deploy_user' => 'deploy',
        'server_id' => 'test-production'
      },
      'domains' => {
        'frontend' => 'mitsubachi.shiosalt.com',
        'api' => 'mitsubachi-api.shiosalt.com'
      },
      'paths' => {
        'rails_root' => File.join(root, 'rails'),
        'frontend_root' => File.join(root, 'frontend'),
        'rails_env' => File.join(root, 'etc', 'rails.env'),
        'frontend_env' => File.join(root, 'etc', 'frontend.env'),
        'caddyfile' => File.join(root, 'etc', 'Caddyfile'),
        'server_id' => File.join(root, 'etc', 'server-id')
      },
      'ports' => {
        'rails' => 3000,
        'http' => 80,
        'https' => 443,
        'minecraft' => [25_565, 25_566]
      },
      'https' => {
        'host' => 'mitsubachi.shiosalt.com',
        'email' => 'ops@example.com',
        'challenge' => 'http-01'
      }
    ))
  end

  def test_caddyfile_renders_frontend_and_api_domains
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: true)
      caddy = MitsubachiInfra::Caddy.new(config: config, runner: runner, repo_root: ROOT)
      rendered = caddy.render
      assert_includes rendered, 'mitsubachi.shiosalt.com'
      assert_includes rendered, 'mitsubachi-api.shiosalt.com'
      assert_includes rendered, 'try_files {path} /index.html'
      assert_includes rendered, 'reverse_proxy 127.0.0.1:3000'
    end
  end

  def test_production_bootstrap_dry_run_does_not_use_ssh_or_write_real_paths
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      io = StringIO.new
      runner = MitsubachiInfra::CommandRunner.new(logger: io, dry_run: true)
      production = MitsubachiInfra::Production.new(config: config, repo_root: ROOT, runner: runner, logger: io)
      production.bootstrap
      refute_includes io.string, 'ssh '
      assert_includes io.string, 'apt-get install'
      assert_includes io.string, 'ufw allow 25565/tcp'
      assert_includes io.string, 'ufw allow 25566/tcp'
      refute_path_exists File.join(dir, 'etc', 'rails.env')
    end
  end

  def test_server_id_mismatch_stops_production_check
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      FileUtils.mkdir_p(File.join(dir, 'etc'))
      File.write(File.join(dir, 'etc', 'server-id'), "other\n")
      io = StringIO.new
      runner = MitsubachiInfra::CommandRunner.new(logger: io, dry_run: false)
      production = MitsubachiInfra::Production.new(config: config, repo_root: ROOT, runner: runner, logger: io)
      assert_raises(MitsubachiInfra::ValidationError) { production.production_check }
    end
  end

  def test_systemd_worker_template_uses_bin_jobs_and_rails_env
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      @config = config
      rendered = ERB.new(File.read(File.join(ROOT, 'templates', 'systemd', 'mitsubachi-jobs.service.erb')),
                         trim_mode: '-').result(binding)
      assert_includes rendered, "EnvironmentFile=#{File.join(dir, 'etc', 'rails.env')}"
      assert_includes rendered, "ExecStartPre=/usr/bin/test -f #{File.join(dir, 'rails', 'current', 'bin/jobs')}"
      assert_includes rendered, 'bundle exec bin/jobs'
    end
  end
end
