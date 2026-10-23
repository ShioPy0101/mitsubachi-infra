# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require_relative '../lib/mitsubachi_infra/server_identity'
require_relative '../lib/mitsubachi_infra/configuration'
require_relative '../lib/mitsubachi_infra/production'

class ServerIdentityTest < Minitest::Test
  class Runner
    attr_accessor :dry_run
    attr_reader :commands

    def initialize
      @commands = []
    end

    def run(*argv)
      @commands << argv
      Struct.new(:stdout).new('')
    end
  end

  class Production < MitsubachiInfra::Production
    private

    def success?(*); true; end
    def privileged_success?(*); true; end
    def frontend_doctor_lines; []; end
    def http_ok?(*, **); true; end
  end

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'config.yml')
    @identity = File.join(@dir, 'server-id')
    @runner = Runner.new
    @logger = StringIO.new
    write_config(nil)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_registers_one_uuid_when_both_values_are_missing_and_preserves_settings
    id = service.ensure!
    assert_match(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/, id)
    assert_equal id, File.read(@identity).strip
    assert_equal id, YAML.safe_load_file(@path).dig('server', 'server_id')
    assert_equal 'keep-me', YAML.safe_load_file(@path).fetch('custom_setting')
    assert_equal id, @config.fetch('server').fetch('server_id')
    assert_equal 0o640, File.stat(@path).mode & 0o777
    assert_equal 0o644, File.stat(@identity).mode & 0o777
    assert_equal 1, Dir.glob("#{@path}.backup.*").length
  end

  def test_reuses_existing_identity_file
    File.write(@identity, "existing-host\n")
    assert_equal 'existing-host', service.ensure!
    assert_equal 'existing-host', YAML.safe_load_file(@path).dig('server', 'server_id')
    refute @runner.commands.any? { |argv| argv.last == @identity }
  end

  def test_reuses_existing_config_and_does_not_rewrite_it
    write_config('configured-host')
    before = File.binread(@path)
    assert_equal 'configured-host', service.ensure!
    assert_equal "configured-host\n", File.read(@identity)
    assert_equal before, File.binread(@path)
    assert_empty Dir.glob("#{@path}.backup.*")
  end

  def test_empty_values_are_initialized
    write_config(' ')
    File.write(@identity, "\n")
    id = service.ensure!
    assert_equal id, File.read(@identity).strip
    assert_equal id, YAML.safe_load_file(@path).dig('server', 'server_id')
  end

  def test_matching_values_are_not_rewritten_on_repeated_runs
    first = service.ensure!
    before = [File.binread(@path), File.binread(@identity), @runner.commands.dup]
    assert_equal first, service.ensure!
    assert_equal before, [File.binread(@path), File.binread(@identity), @runner.commands]
    write_config(first)
    assert_equal first, service.ensure!
  end

  def test_directory_identity_path_is_rejected_without_writes
    Dir.mkdir(@identity)
    before = File.stat(@identity).mode
    assert_raises(MitsubachiInfra::ValidationError) { service.ensure! }
    assert_equal before, File.stat(@identity).mode
    assert_nil YAML.safe_load_file(@path).dig('server', 'server_id')
    assert_empty @runner.commands
  end

  def test_mismatch_is_rejected_without_writes
    write_config('expected-host')
    File.write(@identity, 'different-host')
    assert_raises(MitsubachiInfra::ValidationError) { service.ensure! }
    assert_equal 'different-host', File.read(@identity)
    assert_equal 'expected-host', YAML.safe_load_file(@path).dig('server', 'server_id')
    assert_empty @runner.commands
  end

  def test_dry_run_does_not_write_or_modify_memory
    @runner.dry_run = true
    before = File.binread(@path)
    assert_nil service.ensure!
    assert_equal before, File.binread(@path)
    refute_path_exists @identity
    assert_nil @config.fetch('server')['server_id']
    assert_includes @logger.string, '[DRY-RUN]'
    assert_empty @runner.commands
  end

  def test_config_write_failure_retains_identity_for_retry
    writer = MitsubachiInfra::AtomicWriter.new(runner: @runner)
    failing_writer = Object.new
    config_path = @path
    failing_writer.define_singleton_method(:write) do |path, *args, **options|
      raise Errno::EACCES, path if path == config_path

      writer.write(path, *args, **options)
    end
    assert_raises(MitsubachiInfra::Error) do
      MitsubachiInfra::ServerIdentity.new(config: @config, runner: @runner, logger: @logger,
                                         writer: failing_writer).ensure!
    end
    id = File.read(@identity).strip
    assert_nil @config.fetch('server')['server_id']
    assert_equal id, service.ensure!
  end

  def test_production_check_registers_identity_then_continues_checks
    production.production_check
    id = File.read(@identity).strip
    assert_equal id, YAML.safe_load_file(@path).dig('server', 'server_id')
    assert_includes @logger.string, 'Rails API service: active'
  end

  def test_deploy_and_doctor_reject_unregistered_identity_without_initializing
    assert_raises(MitsubachiInfra::ValidationError) { production.deploy('backend') }
    assert_raises(MitsubachiInfra::ValidationError) { production.doctor }
    refute_path_exists @identity
    assert_nil YAML.safe_load_file(@path).dig('server', 'server_id')
  end

  def test_dry_run_production_check_does_not_register_identity
    @runner.dry_run = true
    production.production_check
    refute_path_exists @identity
    assert_nil YAML.safe_load_file(@path).dig('server', 'server_id')
    assert_includes @logger.string, '[DRY-RUN]'
  end

  private

  def production
    Production.new(config: @config, runner: @runner, logger: @logger, repo_root: File.expand_path('..', __dir__))
  end

  def write_config(id)
    data = { 'server_ip' => '192.168.1.2', 'custom_setting' => 'keep-me',
             'server' => { 'server_id' => id }, 'paths' => { 'server_id' => @identity } }
    File.write(@path, data.to_yaml)
    @config = MitsubachiInfra::Configuration.new(@path)
  end

  def service
    MitsubachiInfra::ServerIdentity.new(config: @config, runner: @runner, logger: @logger)
  end
end
