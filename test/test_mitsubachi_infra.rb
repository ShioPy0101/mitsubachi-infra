# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "mitsubachi_infra/command_runner"
require "mitsubachi_infra/configuration"
require "mitsubachi_infra/deployment/release_manager"
require "mitsubachi_infra/errors"

class MitsubachiInfraTest < Minitest::Test
  def config_data(overrides = {})
    MitsubachiInfra::Configuration::DEFAULT.merge(overrides)
  end

  def test_invalid_deployment_mode
    assert_raises(MitsubachiInfra::ValidationError) do
      MitsubachiInfra::Configuration.new("/missing", data: config_data("deployment_mode" => "bad"))
    end
  end

  def test_public_hostname_validation
    %w[localhost 127.0.0.1 https://files.example.com files.example.com/path].each do |host|
      data = config_data("deployment_mode" => "public", "https" => { "host" => host, "email" => "ops@example.com", "challenge" => "http-01" })
      assert_raises(MitsubachiInfra::ValidationError) { MitsubachiInfra::Configuration.new("/missing", data: data) }
    end
  end

  def test_public_config_accepts_hostname_and_email
    data = config_data("deployment_mode" => "public", "https" => { "host" => "files.example.com", "email" => "ops@example.com", "challenge" => "http-01" })
    assert_equal "public", MitsubachiInfra::Configuration.new("/missing", data: data).fetch("deployment_mode")
  end

  def test_frontend_output_directory_rejects_traversal
    data = config_data("frontend" => MitsubachiInfra::Configuration::DEFAULT.fetch("frontend").merge("output_directory" => "../dist"))
    assert_raises(MitsubachiInfra::ValidationError) { MitsubachiInfra::Configuration.new("/missing", data: data) }
  end

  def test_build_command_must_not_be_empty
    data = config_data("frontend" => MitsubachiInfra::Configuration::DEFAULT.fetch("frontend").merge("build_command" => []))
    assert_raises(MitsubachiInfra::ValidationError) { MitsubachiInfra::Configuration.new("/missing", data: data) }
  end

  def test_command_runner_masks_secrets_and_dry_runs
    io = StringIO.new
    runner = MitsubachiInfra::CommandRunner.new(logger: io, dry_run: true)
    result = runner.run("echo", "DATABASE_URL=postgresql://user:secret@127.0.0.1/db")
    assert result.success?
    refute_includes io.string, "secret"
    assert_includes io.string, "<redacted>"
  end

  def test_release_manager_keeps_current_release
    Dir.mktmpdir do |dir|
      runner = MitsubachiInfra::CommandRunner.new(logger: StringIO.new, dry_run: false)
      manager = MitsubachiInfra::Deployment::ReleaseManager.new(root: dir, runner: runner, keep: 1)
      FileUtils.mkdir_p(manager.releases_dir)
      old = File.join(manager.releases_dir, "old")
      current = File.join(manager.releases_dir, "current")
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
      id = manager.release_id("abcdef1234567890")
      assert_match(/abcdef123456/, id)
      assert_match(/\d{8}T\d{6}Z-abcdef123456-\d+-[0-9a-f]{6}/, id)
    end
  end
end
