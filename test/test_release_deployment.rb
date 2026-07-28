# frozen_string_literal: true

require 'fileutils'
require 'erb'
require 'json'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__) unless defined?(ROOT)
$LOAD_PATH.unshift(File.join(ROOT, 'lib')) unless $LOAD_PATH.include?(File.join(ROOT, 'lib'))

require 'mitsubachi_infra/command_runner'
require 'mitsubachi_infra/configuration'
require 'mitsubachi_infra/deployment/database_backup'
require 'mitsubachi_infra/deployment/diagnostics'
require 'mitsubachi_infra/deployment/maintenance'
require 'mitsubachi_infra/deployment/migration'
require 'mitsubachi_infra/deployment/release'
require 'mitsubachi_infra/deployment/smoke_tester'
require 'mitsubachi_infra/health_check'
require 'mitsubachi_infra/lock'

class ReleaseDeploymentTest < Minitest::Test
  class Runner
    attr_accessor :dry_run
    attr_reader :commands, :deploy_commands

    def initialize(dry_run: false, failures: {})
      @dry_run = dry_run
      @commands = []
      @deploy_commands = []
      @failures = failures
    end

    def run(*command, **_options)
      argv = command.flatten.map(&:to_s)
      @commands << argv
      raise MitsubachiInfra::Error, @failures[argv.first] if @failures.key?(argv.first)

      MitsubachiInfra::CommandRunner::Result.new(stdout: '', stderr: '', status: 0)
    end

    def deploy(*command, **options)
      @deploy_commands << command.flatten.map(&:to_s)
      run(*command, **options)
    end
  end

  class Preflight
    attr_reader :calls

    def initialize
      @calls = []
    end

    def check!(**options)
      @calls << options
      true
    end
  end

  class Backup
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = []
    end

    def create!(directory)
      @calls << directory
      raise @error if @error

      { path: File.join(directory, 'database.dump'), sha256: 'abc', verified: true }
    end
  end

  class Migration
    attr_reader :calls

    def initialize(fail_at: nil)
      @fail_at = fail_at
      @calls = []
    end

    def snapshot!(release:, output:)
      call(:snapshot)
      File.write(output, JSON.generate(count: 1))
    end

    def migrate!(release:)
      call(:migrate)
    end

    def verify!(release:, output:)
      call(:verify)
      File.write(output, JSON.generate(valid: true, unmigrated_count: 0, duplicate_count: 0, mismatch_count: 0))
      { 'valid' => true }
    end

    def prepare_smoke_credentials!(release:, output:, task:)
      call(:prepare_smoke_credentials)
      File.write(output, JSON.generate(users: { member: { token: 'secret' } }))
      { 'users' => { 'member' => { 'token' => 'secret' } } }
    end

    private

    def call(name)
      @calls << name
      raise MitsubachiInfra::Error, "#{name} failed" if @fail_at == name

      true
    end
  end

  class Health
    Result = Struct.new(:values) do
      def to_h
        values
      end
    end

    attr_reader :calls

    def initialize(fail: false)
      @fail = fail
      @calls = []
    end

    def check!(*args, **options)
      @calls << [args, options]
      raise MitsubachiInfra::Error, 'health failed' if @fail

      Result.new({ succeeded: true, attempts: 2, elapsed_seconds: 0.1, status: 200 })
    end
  end

  class Smoke
    def initialize(fail: false)
      @fail = fail
    end

    def run!(release_id:, output:, **_options)
      raise MitsubachiInfra::Error, 'smoke failed' if @fail

      File.write(output, JSON.generate(succeeded: true))
      { 'succeeded' => true }
    end
  end

  class Diagnostics
    attr_reader :calls

    def initialize
      @calls = []
    end

    def capture(path)
      @calls << path
      FileUtils.mkdir_p(path)
      File.write(File.join(path, 'diagnostic.txt'), 'captured')
    end
  end

  class TestRelease < MitsubachiInfra::Deployment::Release
    attr_accessor :fail_frontend_switch

    private

    def prepare_backend(release_id, _ref)
      release = File.join(backend_root, 'releases', release_id)
      FileUtils.mkdir_p(release)
      [release, 'a' * 40]
    end

    def prepare_frontend(release_id, _ref)
      release = File.join(frontend_root, 'releases', release_id)
      FileUtils.mkdir_p(release)
      [release, 'b' * 40]
    end

    def frontend_manager
      return super unless fail_frontend_switch

      @failing_frontend_manager ||= Object.new.tap do |manager|
        manager.define_singleton_method(:activate) { |_path| raise MitsubachiInfra::Error, 'frontend switch failed' }
      end
    end
  end

  def setup
    @root = Dir.mktmpdir
    @backend = File.join(@root, 'backend')
    @frontend = File.join(@root, 'frontend')
    @backup_root = File.join(@root, 'backups')
    @maintenance_path = File.join(@root, 'maintenance.enabled')
    [@backend, @frontend].each do |root|
      old = File.join(root, 'releases', 'old')
      FileUtils.mkdir_p(old)
      FileUtils.ln_s(old, File.join(root, 'current'))
    end
    credentials = File.join(@root, 'credentials')
    manifest = File.join(@root, 'removed.yml')
    File.write(credentials, '')
    File.chmod(0o600, credentials)
    File.write(manifest, "--- {}\n")
    @config = MitsubachiInfra::Configuration.new('/missing', data: {
      'deployment_mode' => 'lan', 'server_ip' => '192.168.1.50',
      'paths' => { 'rails_root' => @backend, 'frontend_root' => @frontend,
                   'rails_env' => File.join(@root, 'rails.env'), 'frontend_env' => File.join(@root, 'frontend.env'),
                   'server_id' => File.join(@root, 'server-id') },
      'release' => { 'backup_root' => @backup_root, 'maintenance_flag' => @maintenance_path,
                     'smoke_test' => { 'credentials_file' => credentials, 'removed_manifest' => manifest,
                                       'command' => ['smoke'], 'timeout_seconds' => 10 } }
    })
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def build_release(backup: Backup.new, migration: Migration.new, health: Health.new, smoke: Smoke.new,
                    diagnostics: Diagnostics.new, dry_run: false)
    runner = Runner.new(dry_run: dry_run)
    maintenance = MitsubachiInfra::Deployment::Maintenance.new(path: @maintenance_path, runner: runner,
                                                               logger: StringIO.new)
    release = TestRelease.new(config: @config, runner: runner, logger: StringIO.new, preflight: Preflight.new,
                              database_backup: backup, migration: migration, health: health,
                              smoke_tester: smoke, diagnostics: diagnostics, maintenance: maintenance,
                              lock: proc { |&block| block.call })
    [release, runner]
  end

  def deploy(release)
    release.deploy(backend_ref: 'backend-ref', frontend_ref: 'frontend-ref')
  end

  def report
    path = Dir.glob(File.join(@backup_root, '*', 'release.json')).first
    JSON.parse(File.read(path))
  end

  def test_メンテナンスの有効化と無効化は冪等である
    runner = Runner.new
    maintenance = MitsubachiInfra::Deployment::Maintenance.new(path: @maintenance_path, runner: runner,
                                                               logger: StringIO.new)
    2.times { maintenance.enable }
    assert maintenance.enabled?
    2.times { maintenance.disable }
    refute maintenance.enabled?
  end

  def test_バックアップ失敗時はmigrationを実行せず安全にメンテナンスを解除する
    migration = Migration.new
    release, = build_release(backup: Backup.new(error: MitsubachiInfra::Error.new('backup failed')),
                             migration: migration)
    assert_raises(MitsubachiInfra::Error) { deploy(release) }
    assert_empty migration.calls
    refute File.exist?(@maintenance_path)
    assert_equal 'database_backup', report.fetch('failed_step')
  end

  def test_migration失敗時はcurrentを維持してメンテナンスも維持する
    release, = build_release(migration: Migration.new(fail_at: :migrate))
    assert_raises(MitsubachiInfra::Error) { deploy(release) }
    assert_equal 'old', File.basename(File.realpath(File.join(@backend, 'current')))
    assert_equal 'old', File.basename(File.realpath(File.join(@frontend, 'current')))
    assert File.exist?(@maintenance_path)
    assert_equal 'database_migration', report.fetch('failed_step')
  end

  def test_migration検証失敗時はcurrentを切り替えない
    release, = build_release(migration: Migration.new(fail_at: :verify))
    assert_raises(MitsubachiInfra::Error) { deploy(release) }
    assert_equal 'old', File.basename(File.realpath(File.join(@backend, 'current')))
    assert File.exist?(@maintenance_path)
  end

  def test_health失敗時は診断を保存して両方のsymlinkを切り戻す
    diagnostics = Diagnostics.new
    release, = build_release(health: Health.new(fail: true), diagnostics: diagnostics)
    assert_raises(MitsubachiInfra::Error) { deploy(release) }
    assert_equal 'old', File.basename(File.realpath(File.join(@backend, 'current')))
    assert_equal 'old', File.basename(File.realpath(File.join(@frontend, 'current')))
    assert File.exist?(@maintenance_path)
    refute_empty diagnostics.calls
  end

  def test_frontend切り替え失敗時はbackendも元に戻す
    release, = build_release
    release.fail_frontend_switch = true
    assert_raises(MitsubachiInfra::Error) { deploy(release) }
    assert_equal 'old', File.basename(File.realpath(File.join(@backend, 'current')))
    assert_equal 'release_switch', report.fetch('failed_step')
  end

  def test_smoke失敗時はメンテナンスを維持して切り戻す
    health = Health.new
    release, = build_release(smoke: Smoke.new(fail: true), health: health)
    assert_raises(MitsubachiInfra::Error) { deploy(release) }
    assert File.exist?(@maintenance_path)
    assert_equal 'old', File.basename(File.realpath(File.join(@backend, 'current')))
    assert_equal({ status: ['ready'] }, health.calls.first.last.fetch(:expected_json))
    assert_equal({ status: %w[ready ok] }, health.calls.last.last.fetch(:expected_json))
  end

  def test_smoke認証情報生成失敗時は切り替えずメンテナンスを維持する
    migration = Migration.new(fail_at: :prepare_smoke_credentials)
    release, = build_release(migration: migration)

    assert_raises(MitsubachiInfra::Error) { deploy(release) }
    assert_equal 'old', File.basename(File.realpath(File.join(@backend, 'current')))
    assert_equal 'old', File.basename(File.realpath(File.join(@frontend, 'current')))
    assert File.exist?(@maintenance_path)
    assert_equal 'smoke_credentials', report.fetch('failed_step')
  end

  def test_全工程成功時だけメンテナンスを解除しDBのdownやrestoreを実行しない
    migration = Migration.new
    health = Health.new
    release, runner = build_release(migration: migration, health: health)
    result = deploy(release)
    refute File.exist?(@maintenance_path)
    assert_equal 'succeeded', result.fetch(:status)
    text = runner.commands.flatten.join(' ')
    refute_match(/db:rollback|db:migrate:down|pg_restore/, text)
    assert_includes migration.calls, :prepare_smoke_credentials
    refute File.exist?(File.join(@backup_root, result.fetch(:release_id), '.smoke-test-credentials.json'))
    assert_equal({ status: ['ready'] }, health.calls.fetch(0).last.fetch(:expected_json))
  end

  def test_dry_runではリリースの副作用が発生しない
    release, runner = build_release(dry_run: true)
    result = deploy(release)
    assert_equal 'dry_run', result.fetch(:status)
    refute File.exist?(@maintenance_path)
    assert_empty Dir.glob(File.join(@backup_root, '*'))
    assert_empty runner.commands
  end

  def test_デプロイロックは多重実行を拒否する
    path = File.join(@root, 'deploy.lock')
    error = nil
    MitsubachiInfra::Lock.with(path) do
      error = assert_raises(MitsubachiInfra::Error) { MitsubachiInfra::Lock.with(path) {} }
    end
    assert_includes error.message, 'another mitsubachi-infra operation'
  end

  def test_廃止routeが200またはredirectを返した場合は失敗する
    manifest = @config.fetch('release').fetch('smoke_test').fetch('removed_manifest')
    File.write(manifest, <<~YAML)
      removed_pages:
        - path: /retired
          expected_status: 404
    YAML
    tester = MitsubachiInfra::Deployment::SmokeTester.new(config: @config, runner: Runner.new,
                                                          logger: StringIO.new)
    [200, 302].each do |status|
      with_http_status(status) do
        assert_raises(MitsubachiInfra::Error) { tester.send(:check_removed!, manifest) }
      end
    end
  end

  def test_health_checkはready_jsonを要求して成功ログを出す
    logger = StringIO.new
    with_http_response(200, '{"status":"starting"}') do
      assert_raises(MitsubachiInfra::Error) do
        MitsubachiInfra::HealthCheck.new(logger: logger)
                                        .check!('http://127.0.0.1:3000/api/health/ready', host: 'api.example.com',
                                                                                         attempts: 1, delay: 0,
                                                                                         expected_json: { status: ['ready'] })
      end
    end
    with_http_response(200, '{"status":"ready"}') do
      result = MitsubachiInfra::HealthCheck.new(logger: logger)
                                           .check!('http://127.0.0.1:3000/api/health/ready', host: 'api.example.com',
                                                                                            attempts: 1, delay: 0,
                                                                                            expected_json: { status: ['ready'] })
      assert result.succeeded
      assert_includes logger.string, '[OK] health check passed'
    end
    with_http_response(200, '{"status":"ok"}') do
      assert_raises(MitsubachiInfra::Error) do
        MitsubachiInfra::HealthCheck.new(logger: logger)
                                        .check!('http://127.0.0.1:3000/api/health/ready', host: 'api.example.com',
                                                                                         attempts: 1, delay: 0,
                                                                                         expected_json: { status: ['ready'] })
      end
    end
  end

  def test_Nginxメンテナンスは通常routeを停止しreadinessを除外する
    default_server_suffix = ''
    config = @config
    rendered = ERB.new(File.read(File.join(ROOT, 'templates/nginx/lan.conf.erb'))).result(binding)
    assert_includes rendered, "-f #{@maintenance_path}"
    assert_includes rendered, 'return 503'
    assert_includes rendered, 'location = /api/health/ready'
    readiness = rendered[/location = \/api\/health\/ready \{.*?\n    \}/m]
    refute_includes readiness, 'return 503'
  end

  def test_preflightはbundleをdeployユーザー環境で確認する
    runner = Runner.new
    preflight = MitsubachiInfra::Deployment::Preflight.new(config: @config, runner: runner,
                                                           logger: StringIO.new)
    preflight.send(:require_deploy_command!, 'bundle')

    assert_includes runner.deploy_commands, %w[which bundle]
  end

  def test_smoke認証情報の実行用一時ファイルは終了時に削除する
    source = @config.fetch('release').fetch('smoke_test').fetch('credentials_file')
    output = File.join(@root, 'smoke-report.json')
    tester = MitsubachiInfra::Deployment::SmokeTester.new(config: @config, runner: Runner.new,
                                                          logger: StringIO.new)
    temporary = "#{output}.credentials.#{$PROCESS_ID}"
    File.write(source, "MEMBER_PASSWORD=secret\n")

    @config.set('deploy.user', Etc.getpwuid(Process.uid).name)
    runner = tester.instance_variable_get(:@runner)
    runner.define_singleton_method(:deploy) do |*_command, **options|
      path = options.fetch(:env).fetch('CREDENTIALS_FILE')
      raise '一時認証情報が存在しない' unless File.file?(path)
      File.write(options.fetch(:env).fetch('OUTPUT'), JSON.generate(succeeded: true))
      MitsubachiInfra::CommandRunner::Result.new(stdout: '', stderr: '', status: 0)
    end
    tester.run!(release_id: 'release-id', output: output)

    refute File.exist?(temporary)
    assert File.exist?(source)
  end

  def test_public_smokeは本番ホストのHTTPSとloopback接続先を渡しRails_readinessを分離する
    @config.set('deployment_mode', 'public')
    @config.set('https.frontend_host', 'mitsubachi.shiosalt.com')
    @config.set('https.api_host', 'mitsubachi-api.shiosalt.com')
    @config.set('ports.rails', 3000)
    captured_env = nil
    runner = Runner.new(dry_run: true)
    runner.define_singleton_method(:deploy) do |*_command, **options|
      captured_env = options.fetch(:env)
      MitsubachiInfra::CommandRunner::Result.new(stdout: '', stderr: '', status: 0)
    end
    tester = MitsubachiInfra::Deployment::SmokeTester.new(config: @config, runner: runner,
                                                          logger: StringIO.new)

    tester.run!(release_id: 'release-id', output: File.join(@root, 'smoke-report.json'))

    assert_equal 'https://mitsubachi.shiosalt.com/', captured_env.fetch('BASE_URL')
    assert_equal 'https://mitsubachi-api.shiosalt.com/', captured_env.fetch('API_BASE_URL')
    assert_equal '127.0.0.1', captured_env.fetch('SMOKE_RESOLVED_ADDRESS')
    assert_equal 'http://127.0.0.1:3000/api/health/ready', captured_env.fetch('RAILS_READINESS_URL')
  end

  private

  def with_http_status(status, &block)
    with_http_response(status, '', &block)
  end

  def with_http_response(status, body)
    response = Struct.new(:code, :body).new(status.to_s, body)
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }
    singleton = Net::HTTP.singleton_class
    singleton.alias_method(:release_original_start, :start)
    Net::HTTP.define_singleton_method(:start) { |_host, _port, **_options, &request_block| request_block.call(http) }
    yield
  ensure
    if singleton&.method_defined?(:release_original_start)
      singleton.alias_method(:start, :release_original_start)
      singleton.remove_method(:release_original_start)
    end
  end
end
