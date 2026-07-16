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
require 'mitsubachi_infra/cli'
require 'mitsubachi_infra/env_templates'
require 'mitsubachi_infra/health_check'
require 'mitsubachi_infra/installer'
require 'mitsubachi_infra/nginx'
require 'mitsubachi_infra/node_runtime'
require 'mitsubachi_infra/deployment/release_manager'
require 'mitsubachi_infra/errors'
require 'mitsubachi_infra/production'
require 'mitsubachi_infra/rails_command'
require 'mitsubachi_infra/systemd'

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

    def deploy(*command, **options)
      run(*command, **options)
    end
  end

  class FakeHealth
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = []
    end

    def check!(url, **options)
      @calls << [url, options]
      raise @error if @error

      true
    end
  end

  class NodeRunner < RecordingRunner
    def initialize(node_stdout:)
      super()
      @node_stdout = Array(node_stdout)
    end

    def run(*command, **options)
      argv = command.flatten.map(&:to_s)
      @commands << argv
      if argv == %w[node --version]
        stdout = @node_stdout.length > 1 ? @node_stdout.shift : @node_stdout.first
        return MitsubachiInfra::CommandRunner::Result.new(stdout: stdout.to_s, stderr: '', status: stdout ? 0 : 1)
      end
      return MitsubachiInfra::CommandRunner::Result.new(stdout: '10.0.0', stderr: '', status: 0) if argv == %w[npm --version]

      MitsubachiInfra::CommandRunner::Result.new(stdout: '', stderr: '', status: 0)
    end
  end

  class OptionRecordingRunner < RecordingRunner
    attr_reader :calls

    def initialize
      super
      @calls = []
    end

    def deploy(*command, **options)
      @calls << [command.flatten.map(&:to_s), options]
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
    MitsubachiInfra::Configuration::DEFAULT.merge('server_ip' => '192.168.1.50').merge(overrides)
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

  def capture_health_request
    captured = nil
    response = Struct.new(:code).new('200')
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      captured = request
      response
    end
    Net::HTTP.singleton_class.alias_method(:mitsubachi_original_start, :start)
    Net::HTTP.define_singleton_method(:start) do |_host, _port, **_options, &block|
      block.call(fake_http)
    end
    yield 'http://127.0.0.1:3000/api/health/ready'
    captured
  ensure
    if Net::HTTP.singleton_class.method_defined?(:mitsubachi_original_start)
      Net::HTTP.singleton_class.alias_method(:start, :mitsubachi_original_start)
      Net::HTTP.singleton_class.remove_method(:mitsubachi_original_start)
    end
  end

  def with_euid(value)
    Process.singleton_class.alias_method(:mitsubachi_original_euid, :euid)
    Process.define_singleton_method(:euid) { value }
    yield
  ensure
    if Process.singleton_class.method_defined?(:mitsubachi_original_euid)
      Process.singleton_class.alias_method(:euid, :mitsubachi_original_euid)
      Process.singleton_class.remove_method(:mitsubachi_original_euid)
    end
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

  def test_rails_env_public_hosts
    config = production_config('/tmp/mitsubachi-test')
    rendered = MitsubachiInfra::EnvTemplates.rails_env(config)

    assert_includes rendered, 'APP_HOST=mitsubachi-api.shiosalt.com'
    assert_includes rendered, 'ALLOWED_HOSTS=mitsubachi-api.shiosalt.com,127.0.0.1,localhost'
  end

  def test_rails_env_lan_hosts
    config = MitsubachiInfra::Configuration.new('/missing', data: config_data(
      'deployment_mode' => 'lan',
      'server_ip' => '192.168.1.50',
      'https' => MitsubachiInfra::Configuration::DEFAULT.fetch('https')
    ))
    rendered = MitsubachiInfra::EnvTemplates.rails_env(config)

    assert_includes rendered, 'APP_HOST=192.168.1.50'
    assert_includes rendered, 'ALLOWED_HOSTS=192.168.1.50,127.0.0.1,localhost'
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

  def test_cli_installed_entrypoint_loads_outside_repository
    Dir.mktmpdir do |dir|
      cli_root = File.join(dir, 'opt', 'mitsubachi-infra')
      cli_link = File.join(dir, 'bin', 'mitsubachi-infra')
      FileUtils.mkdir_p(File.dirname(cli_link))
      installer = MitsubachiInfra::Installer.new(config: production_config(dir), runner: RecordingRunner.new,
                                                 repo_root: ROOT, cli_root: cli_root, cli_link: cli_link)

      installer.send(:install_cli)

      Dir.chdir('/tmp') do
        assert system(cli_link, 'help', out: File::NULL, err: File::NULL)
      end
    end
  end

  def test_cli_install_is_atomic
    Dir.mktmpdir do |dir|
      cli_root = File.join(dir, 'opt', 'mitsubachi-infra')
      cli_link = File.join(dir, 'bin', 'mitsubachi-infra')
      bad_repo = File.join(dir, 'bad-repo')
      FileUtils.mkdir_p(File.join(bad_repo, 'bin'))
      File.write(File.join(bad_repo, 'bin', 'mitsubachi-infra'), "#!/usr/bin/env ruby\n")
      FileUtils.mkdir_p(File.dirname(cli_link))
      installer = MitsubachiInfra::Installer.new(config: production_config(dir), runner: RecordingRunner.new,
                                                 repo_root: bad_repo, cli_root: cli_root, cli_link: cli_link)

      assert_raises(Errno::ENOENT) { installer.send(:install_cli) }
      refute_path_exists cli_link
      assert_empty Dir.glob(File.join(cli_root, 'releases', '*.tmp'))
    end
  end

  def test_install_rejects_non_root_before_lock
    with_euid(1000) do
      io = StringIO.new
      cli = MitsubachiInfra::CLI.new(%w[--config /missing install], repo_root: ROOT)
      $stderr = io
      assert_equal 1, cli.run
      assert_includes io.string, 'install must be run as root'
      assert_includes io.string, 'hint: sudo mitsubachi-infra install'
      refute_includes io.string, 'Permission denied'
    ensure
      $stderr = STDERR
    end
  end

  def test_install_interactive_prompts_for_missing_server_ip
    Dir.mktmpdir do |dir|
      config = MitsubachiInfra::Configuration.new(File.join(dir, 'config.yml'),
                                                  data: MitsubachiInfra::Configuration::DEFAULT, validate: false)
      output = StringIO.new
      installer = MitsubachiInfra::Installer.new(config: config, runner: RecordingRunner.new, repo_root: ROOT,
                                                 input: StringIO.new("192.168.10.151\ny\n"), output: output)

      installer.send(:prepare_configuration, interactive: true)

      assert_equal '192.168.10.151', config.fetch('server_ip')
      assert_includes output.string, 'LAN server private IPv4'
      assert_includes output.string, 'Install summary'
    end
  end

  def test_install_non_interactive_rejects_missing_required_config
    config = MitsubachiInfra::Configuration.new('/missing', data: MitsubachiInfra::Configuration::DEFAULT,
                                                          validate: false)
    runner = RecordingRunner.new
    installer = MitsubachiInfra::Installer.new(config: config, runner: runner, repo_root: ROOT)

    error = assert_raises(MitsubachiInfra::ValidationError) do
      installer.install(interactive: false)
    end

    assert_includes error.message, 'missing required configuration: server_ip'
    assert_empty runner.commands
  end

  def test_install_does_not_use_example_server_ip_as_default
    config = MitsubachiInfra::Configuration.new('/missing', data: MitsubachiInfra::Configuration::DEFAULT,
                                                          validate: false)

    assert_nil config.fetch('server_ip')
    assert_includes config.missing_required_settings, 'server_ip'
  end

  def test_install_uses_health_check_retry
    Dir.mktmpdir do |dir|
      health = FakeHealth.new
      installer = MitsubachiInfra::Installer.new(config: production_config(dir), runner: RecordingRunner.new,
                                                 repo_root: ROOT, health: health)

      installer.send(:verify_install)

      assert_equal 1, health.calls.length
      assert_equal 'mitsubachi-api.shiosalt.com', health.calls.first.last[:host]
      assert_equal 30, health.calls.first.last.fetch(:attempts, 30)
    end
  end

  def test_install_reports_service_diagnostics_after_health_timeout
    Dir.mktmpdir do |dir|
      runner = RecordingRunner.new
      health = FakeHealth.new(error: MitsubachiInfra::Error.new('health check failed'))
      installer = MitsubachiInfra::Installer.new(config: production_config(dir), runner: runner, repo_root: ROOT,
                                                 health: health)

      assert_raises(MitsubachiInfra::Error) { installer.send(:verify_install) }

      assert_includes runner.commands, %w[systemctl status mitsubachi-api.service --no-pager]
      assert_includes runner.commands, %w[journalctl -u mitsubachi-api.service -n 100 --no-pager]
      assert_includes runner.commands, %w[ss -ltnp]
    end
  end

  def test_node_major_is_validated
    config = production_config('/tmp/mitsubachi-test')
    runner = NodeRunner.new(node_stdout: ["v12.22.9\n", "v22.1.0\n", "v22.1.0\n"])

    MitsubachiInfra::NodeRuntime.new(config: config, runner: runner).ensure!

    assert runner.commands.any? { |command| command == %w[apt-get install -y nodejs] }
    assert_includes runner.commands, %w[node --version]
    assert_includes runner.commands, %w[npm --version]
  end

  def test_install_summary_does_not_expose_secrets
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      output = StringIO.new
      installer = MitsubachiInfra::Installer.new(config: config, runner: RecordingRunner.new, repo_root: ROOT,
                                                 output: output)

      installer.send(:prepare_configuration, interactive: false)

      refute_includes output.string, 'SECRET_KEY_BASE'
      refute_includes output.string, 'DATABASE_URL'
      assert_includes output.string, 'Install summary'
    end
  end

  def test_existing_valid_config_skips_interactive_questions
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      output = StringIO.new
      installer = MitsubachiInfra::Installer.new(config: config, runner: RecordingRunner.new, repo_root: ROOT,
                                                 input: StringIO.new("y\n"), output: output)

      installer.send(:prepare_configuration, interactive: true)

      refute_includes output.string, 'LAN server private IPv4'
      assert_includes output.string, 'Continue install?'
    end
  end

  def test_public_mode_health_host_uses_api_domain
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      health = FakeHealth.new
      MitsubachiInfra::Installer.new(config: config, runner: RecordingRunner.new, repo_root: ROOT,
                                     health: health).send(:verify_install)

      assert_equal 'mitsubachi-api.shiosalt.com', health.calls.first.last[:host]
    end
  end

  def test_lan_mode_health_host_uses_explicit_server_ip
    Dir.mktmpdir do |dir|
      config = MitsubachiInfra::Configuration.new('/missing', data: config_data(
        'deployment_mode' => 'lan',
        'server_ip' => '192.168.10.151',
        'paths' => {
          'rails_root' => File.join(dir, 'rails'),
          'frontend_root' => File.join(dir, 'frontend'),
          'rails_env' => File.join(dir, 'etc', 'rails.env'),
          'frontend_env' => File.join(dir, 'etc', 'frontend.env'),
          'server_id' => File.join(dir, 'etc', 'server-id')
        }
      ))
      health = FakeHealth.new
      MitsubachiInfra::Installer.new(config: config, runner: RecordingRunner.new, repo_root: ROOT,
                                     health: health).send(:verify_install)

      assert_equal '192.168.10.151', health.calls.first.last[:host]
    end
  end

  def test_rails_command_uses_production_env_and_release_cwd
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      FileUtils.mkdir_p(File.dirname(config.fetch('paths').fetch('rails_env')))
      File.write(config.fetch('paths').fetch('rails_env'), <<~ENV)
        DATABASE_URL=postgresql://app:secret@127.0.0.1/db
        RESEND_API_KEY=hidden
      ENV
      runner = OptionRecordingRunner.new
      release = File.join(dir, 'release')

      MitsubachiInfra::RailsCommand.new(config: config, runner: runner).runner('puts ENV.fetch("RAILS_ENV")',
                                                                               release: release)

      command, options = runner.calls.first
      assert_equal %w[bundle exec rails runner], command[0, 4]
      assert_equal release, options[:chdir]
      assert_equal 'production', options[:env].fetch('RAILS_ENV')
      assert_equal 'production', options[:env].fetch('RACK_ENV')
      assert_equal 'development:test', options[:env].fetch('BUNDLE_WITHOUT')
      assert_equal 'postgresql://app:secret@127.0.0.1/db', options[:env].fetch('DATABASE_URL')
    end
  end

  def test_backend_deploy_rails_checks_use_common_production_env
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      FileUtils.mkdir_p(File.dirname(config.fetch('paths').fetch('rails_env')))
      File.write(config.fetch('paths').fetch('rails_env'), <<~ENV)
        DATABASE_URL=postgresql://app:secret@127.0.0.1/db
        DATABASE_CACHE_URL=postgresql://app:secret@127.0.0.1/cache
        DATABASE_QUEUE_URL=postgresql://app:secret@127.0.0.1/queue
        DATABASE_CABLE_URL=postgresql://app:secret@127.0.0.1/cable
      ENV
      runner = OptionRecordingRunner.new
      backend = MitsubachiInfra::Deployment::Backend.new(config: config, runner: runner,
                                                         systemd: MitsubachiInfra::Systemd.new(runner: runner),
                                                         health: FakeHealth.new)

      backend.send(:rails_check, File.join(dir, 'release'))

      rails_calls = runner.calls.select { |command, _options| command[0, 3] == %w[bundle exec rails] }
      refute_empty rails_calls
      rails_calls.each do |_command, options|
        assert_equal 'production', options.fetch(:env).fetch('RAILS_ENV')
        assert_equal 'production', options.fetch(:env).fetch('RACK_ENV')
        assert_equal 'development:test', options.fetch(:env).fetch('BUNDLE_WITHOUT')
      end
    end
  end

  def test_rails_command_dry_run_masks_secret_env_values
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      FileUtils.mkdir_p(File.dirname(config.fetch('paths').fetch('rails_env')))
      File.write(config.fetch('paths').fetch('rails_env'), "DATABASE_URL=postgresql://app:secret@127.0.0.1/db\n")
      io = StringIO.new
      runner = MitsubachiInfra::CommandRunner.new(logger: io, dry_run: true)

      MitsubachiInfra::RailsCommand.new(config: config, runner: runner).rails('db:migrate',
                                                                              release: File.join(dir, 'release'))

      refute_includes io.string, 'secret'
      assert_includes io.string, '<redacted>'
      assert_includes io.string, 'RAILS_ENV=production'
      assert_includes io.string, 'BUNDLE_WITHOUT=development:test'
    end
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

  def test_health_check_sends_public_host_header
    request = capture_health_request do |url|
      MitsubachiInfra::HealthCheck.new(logger: StringIO.new).check!(url, host: 'mitsubachi-api.shiosalt.com')
    end

    assert_equal 'mitsubachi-api.shiosalt.com', request['Host']
  end

  def test_health_check_sends_lan_host_header
    request = capture_health_request do |url|
      MitsubachiInfra::HealthCheck.new(logger: StringIO.new).check!(url, host: '192.168.1.50')
    end

    assert_equal '192.168.1.50', request['Host']
  end

  def test_generated_files_do_not_reference_3001
    paths = %w[
      README.md
      docs/commands.md
      docs/environment-variables.md
      docs/mail-delivery.md
      docs/production-deployment.md
      docs/troubleshooting.md
      env/rails.env.example
      nginx/mitsubachi-local.conf
      scripts/deploy_api.sh
      scripts/rollback_api.sh
      scripts/verify_installation.sh
      templates/nginx/lan.conf.erb
      templates/nginx/public_http_challenge.conf.erb
      templates/nginx/public_https.conf.erb
      templates/systemd/mitsubachi-api.service.erb
    ]
    offenders = paths.select { |path| File.read(File.join(ROOT, path)).include?('3001') }

    assert_empty offenders
  end

  def test_systemd_commands_restart_and_enable_worker_now
    runner = RecordingRunner.new
    systemd = MitsubachiInfra::Systemd.new(runner: runner)
    systemd.restart('mitsubachi-api.service')
    systemd.enable_now('mitsubachi-worker.service')

    assert_includes runner.commands, %w[systemctl restart mitsubachi-api.service]
    assert_includes runner.commands, %w[systemctl enable --now mitsubachi-worker.service]
  end

  def test_production_rejects_active_caddy_before_nginx
    config = production_config('/tmp/mitsubachi-test')
    runner = RecordingRunner.new
    production = MitsubachiInfra::Production.new(config: config, repo_root: ROOT, runner: runner, logger: StringIO.new)

    error = assert_raises(MitsubachiInfra::Error) { production.send(:reject_caddy_conflict!) }
    assert_includes error.message, 'Caddy is active'
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

  def test_nginx_public_template_renders_frontend_and_api_domains
    Dir.mktmpdir do |dir|
      config = production_config(dir)
      rendered = MitsubachiInfra::Nginx.new(config: config, runner: RecordingRunner.new, repo_root: ROOT)
                                  .render(mode: 'public_https')
      assert_includes rendered, 'mitsubachi.shiosalt.com'
      assert_includes rendered, 'mitsubachi-api.shiosalt.com'
      assert_includes rendered, 'try_files $uri $uri/ /index.html'
      assert_includes rendered, 'proxy_pass http://127.0.0.1:3000'
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
