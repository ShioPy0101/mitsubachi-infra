# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class LegacyRubyRuntimeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(@bin)
    @log = File.join(@dir, 'commands')
    File.write(File.join(@dir, '.ruby-version'), "3.4.11\n")
    write_command('rbenv', <<~SH)
      printf 'rbenv %s\n' "$*" >> "$COMMAND_LOG"
      case "$1" in
        root) printf '%s\n' "$FAKE_ROOT" ;;
        versions) printf '%s\n' "${INSTALLED_RUBY:-}" ;;
        install) exit "${INSTALL_STATUS:-0}" ;;
        exec) [[ "$RBENV_VERSION" == 3.4.11 && -z "${RBENV_DIR:-}" ]] ;;
      esac
    SH
    write_command('git', 'printf "git %s\n" "$*" >> "$COMMAND_LOG"')
    @env = { 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'COMMAND_LOG' => @log, 'FAKE_ROOT' => @dir,
             'RBENV_VERSION' => '3.3.7', 'RBENV_DIR' => '/wrong' }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_missing_ruby_is_built_without_changing_global
    _, stderr, status = prepare
    assert status.success?, stderr
    assert_includes File.read(@log), 'rbenv install 3.4.11'
    refute_includes File.read(@log), 'rbenv global'
  end

  def test_installed_ruby_does_not_build_or_fetch
    @env['INSTALLED_RUBY'] = '3.4.11'
    _, stderr, status = prepare
    assert status.success?, stderr
    refute_includes File.read(@log), 'rbenv install'
    refute_includes File.read(@log), 'git '
  end

  def test_build_failure_stops_before_execution
    @env['INSTALL_STATUS'] = '1'
    _, _, status = prepare
    refute status.success?
    refute_includes File.read(@log), 'rbenv exec'
  end

  def test_invalid_and_missing_versions_do_not_execute_commands
    File.write(File.join(@dir, '.ruby-version'), "3.4.11\n3.3.7")
    refute prepare.last.success?
    FileUtils.rm_f(File.join(@dir, '.ruby-version'))
    refute prepare.last.success?
    refute_path_exists @log
  end

  private

  def write_command(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/usr/bin/env bash\nset -euo pipefail\n#{body}\n")
    File.chmod(0o755, path)
  end

  def prepare
    helper = File.expand_path('../scripts/lib/ruby_runtime.sh', __dir__)
    Open3.capture3(@env, 'bash', '-c', 'source "$1"; prepare_release_ruby "$2"', 'test', helper, @dir)
  end
end
