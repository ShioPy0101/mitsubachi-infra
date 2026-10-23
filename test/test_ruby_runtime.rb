# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/mitsubachi_infra/ruby_runtime'
require_relative '../lib/mitsubachi_infra/command_runner'

class RubyRuntimeTest < Minitest::Test
  class Runner
    attr_reader :calls
    attr_accessor :dry_run, :installed, :fail_install

    def initialize
      @calls = []
    end

    def deploy(*argv, **options)
      @calls << [argv, options]
      raise MitsubachiInfra::Error, 'build failed' if fail_install && argv[0, 2] == %w[rbenv install]

      stdout = argv == %w[rbenv versions --bare] ? installed.to_s : ''
      MitsubachiInfra::CommandRunner::Result.new(stdout: stdout, status: 0)
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @runner = Runner.new
    @config = { 'deploy' => { 'home' => @dir }, 'runtime' => { 'ruby_version' => '3.3.7' } }
    @runtime = MitsubachiInfra::RubyRuntime.new(config: @config, runner: @runner)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_release_version_overrides_bootstrap_setting_without_changing_global
    File.write(File.join(@dir, '.ruby-version'), "3.4.11\n")
    assert_equal '3.4.11', @runtime.ensure!(release: @dir)
    assert_includes commands, %w[rbenv install 3.4.11]
    refute commands.any? { |argv| argv[0, 2] == %w[rbenv global] }
    assert_equal({ 'RBENV_VERSION' => '3.4.11' }, @runner.calls.last.last[:env])
  end

  def test_bootstrap_retains_explicit_config_fallback
    @runtime.ensure!
    assert_includes commands, %w[rbenv global 3.3.7]
  end

  def test_missing_release_version_fails_before_any_command
    assert_raises(MitsubachiInfra::ValidationError) { @runtime.ensure!(release: @dir) }
    assert_empty commands
  end

  def test_invalid_release_versions_fail_before_any_command
    ["", "system", "3.4.11\n3.3.7", "3.4.11;id", "../3.4.11"].each do |version|
      File.write(File.join(@dir, '.ruby-version'), version)
      assert_raises(MitsubachiInfra::ValidationError) { @runtime.ensure!(release: @dir) }
    end
    assert_empty commands
  end

  def test_installed_ruby_is_verified_without_rebuilding_or_updating_definitions
    File.write(File.join(@dir, '.ruby-version'), '3.4.11')
    @runner.installed = "3.4.11\n"
    @runtime.ensure!(release: @dir)
    refute commands.any? { |argv| argv[0, 2] == %w[rbenv install] }
    refute commands.any? { |argv| argv.include?('FETCH_HEAD') }
    assert_equal 'ruby', commands.last.first
  end

  def test_build_definitions_are_updated_before_install
    File.write(File.join(@dir, '.ruby-version'), '3.4.11')
    build = File.join(@dir, '.rbenv/plugins/ruby-build')
    FileUtils.mkdir_p(File.join(build, '.git'))
    @runtime.ensure!(release: @dir)
    update = commands.index(['git', '-C', build, 'merge', '--ff-only', 'FETCH_HEAD'])
    assert update
    assert_operator update, :<, commands.index(%w[rbenv install 3.4.11])
  end

  def test_build_failure_never_changes_global_ruby
    File.write(File.join(@dir, '.ruby-version'), '3.4.11')
    @runner.fail_install = true
    assert_raises(MitsubachiInfra::Error) { @runtime.ensure!(release: @dir) }
    refute commands.any? { |argv| argv[0, 2] == %w[rbenv global] }
  end

  def test_dry_run_does_not_guess_version_of_unfetched_release
    @runner.dry_run = true
    assert_nil @runtime.ensure!(release: @dir)
    assert_empty commands
  end

  private

  def commands
    @runner.calls.map(&:first)
  end
end
