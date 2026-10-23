# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require 'fileutils'
require_relative '../lib/mitsubachi_infra/production'
require_relative '../lib/mitsubachi_infra/deployment/release'
require_relative '../lib/mitsubachi_infra/configuration'
require_relative '../lib/mitsubachi_infra/command_runner'

class ReleaseRubyDeploymentTest < Minitest::Test
  class Runner
    attr_reader :calls
    attr_accessor :failure

    def initialize
      @calls = []
    end

    def dry_run
      false
    end

    def run(*argv, **options)
      @calls << [argv, options]
      raise MitsubachiInfra::Error, 'injected failure' if failure && failure.call(argv, options)

      # Bundler 未導入を模擬して gem install の実行環境も検証する。
      status = argv[0, 2] == %w[gem list] ? 1 : 0
      MitsubachiInfra::CommandRunner::Result.new(stdout: '', stderr: '', status: status)
    end

    alias deploy run
  end

  class Health
    attr_accessor :failures
    attr_reader :calls

    def initialize(failures: 0)
      @failures = failures
      @calls = 0
    end

    def check!(*, **)
      @calls += 1
      if @failures.positive?
        @failures -= 1
        raise MitsubachiInfra::Error, 'unhealthy'
      end
    end
  end

  class Production < MitsubachiInfra::Production
    attr_accessor :candidate, :health

    private

    def create_git_release(**)
      candidate
    end

    def ensure_required_rails_env!; end

    def check_backend_health!
      health.check!
    end
  end

  class Release < MitsubachiInfra::Deployment::Release
    attr_accessor :candidate

    private

    def checkout_release(*)
      [candidate, 'a' * 40]
    end

    def link_backend_shared(*); end
  end

  def setup
    @dir = Dir.mktmpdir
    @old = File.join(@dir, 'releases/old')
    @new = File.join(@dir, 'releases/new')
    [@old, @new].each { |path| FileUtils.mkdir_p(path) }
    File.write(File.join(@old, '.ruby-version'), '3.4.9')
    File.write(File.join(@new, '.ruby-version'), '3.4.11')
    File.write(File.join(@new, 'Gemfile.lock'), "BUNDLED WITH\n   2.6.9\n")
    File.symlink(@old, File.join(@dir, 'current'))
    # アプリ環境を読み取る必要のない fake。実在の rails.env は参照しない。
    env = File.join(@dir, 'rails.env')
    File.write(env, "RBENV_VERSION=3.3.7\nRBENV_DIR=/wrong\n")
    @config = MitsubachiInfra::Configuration.new(data: {
      'server_ip' => '192.168.1.2', 'paths' => { 'rails_root' => @dir, 'rails_env' => env }
    })
    @runner = Runner.new
    @production = Production.new(config: @config, repo_root: File.expand_path('..', __dir__),
                                 runner: @runner, logger: StringIO.new)
    @production.candidate = @new
    @health = Health.new
    @production.health = @health
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_build_gem_bundle_and_boot_failures_preserve_running_release
    [->(argv, _) { argv[0, 2] == %w[rbenv install] },
     ->(argv, _) { argv[0, 2] == %w[gem install] },
     ->(argv, _) { argv == %w[bundle install] },
     ->(argv, _) { argv[0, 4] == %w[bundle exec rails runner] }].each do |failure|
      FileUtils.mkdir_p(@new)
      File.write(File.join(@new, '.ruby-version'), '3.4.11')
      File.write(File.join(@new, 'Gemfile.lock'), "BUNDLED WITH\n   2.6.9\n")
      @runner.failure = failure
      assert_raises(MitsubachiInfra::Error) { deploy }
      assert_equal @old, File.realpath(File.join(@dir, 'current'))
      refute @runner.calls.any? { |argv, _| argv.include?('systemctl') }
    end
  end

  def test_success_prepares_ruby_and_bundle_and_checks_boot_before_restart
    deploy
    assert_equal @new, File.realpath(File.join(@dir, 'current'))
    commands = @runner.calls.map(&:first)
    assert_operator commands.index(%w[rbenv install 3.4.11]), :<, commands.index(%w[bundle install])
    boot = commands.index { |argv| argv.include?('Rails.application.eager_load!') }
    restart = commands.index { |argv| argv.include?('restart') }
    assert_operator boot, :<, restart
    @runner.calls.select { |argv, _| %w[gem bundle].include?(argv.first) }.each do |_, options|
      assert_equal @new, options[:chdir]
      refute options.fetch(:env, {}).key?('RBENV_VERSION')
      refute options.fetch(:env, {}).key?('RBENV_DIR')
    end
    refute commands.any? { |argv| argv[0, 2] == %w[rbenv global] }
  end

  def test_restart_failure_restores_old_release_and_ruby
    failed = false
    @runner.failure = lambda do |argv, _|
      next false unless argv.include?('restart') && !failed

      failed = true
    end
    assert_raises(MitsubachiInfra::Error) { deploy }
    assert_equal @old, File.realpath(File.join(@dir, 'current'))
    assert_equal '3.4.9', File.read(File.join(@dir, 'current/.ruby-version'))
    assert_equal 1, @health.calls
  end

  def test_health_failure_restores_old_release_and_checks_recovery
    @health.failures = 1
    assert_raises(MitsubachiInfra::Error) { deploy }
    assert_equal @old, File.realpath(File.join(@dir, 'current'))
    assert_equal 2, @health.calls
  end

  def test_coordinated_release_prepares_ruby_and_bundler_before_boot
    release = Release.new(config: @config, runner: @runner, logger: StringIO.new)
    release.candidate = @new
    assert_equal [@new, 'a' * 40], release.send(:prepare_backend, 'candidate', 'main')
    commands = @runner.calls.map(&:first)
    assert_includes commands, %w[rbenv install 3.4.11]
    assert_includes commands, %w[gem install bundler --version 2.6.9 --no-document]
    assert_equal @old, File.realpath(File.join(@dir, 'current'))
    refute commands.any? { |argv| argv.include?('systemctl') }
  end

  def test_systemd_units_select_ruby_from_current_release
    root = File.expand_path('..', __dir__)
    %w[templates/systemd/mitsubachi-api.service.erb templates/systemd/mitsubachi-jobs.service.erb
       systemd/mitsubachi-api.service].each do |path|
      content = File.read(File.join(root, path))
      assert_match(%r{WorkingDirectory=.+/current}, content)
      assert_includes content, 'ExecStart=/usr/bin/env -u RBENV_VERSION -u RBENV_DIR '
    end
  end

  def test_rollback_failure_reports_both_errors
    @health.failures = 2
    error = assert_raises(MitsubachiInfra::Error) { deploy }
    assert_includes error.message, 'backend deploy failed: unhealthy'
    assert_includes error.message, 'rollback failed: unhealthy'
  end

  private

  def deploy
    @production.send(:deploy_backend)
  end
end
