# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/mitsubachi_infra/atomic_writer'

class AtomicWriterTest < Minitest::Test
  class Runner
    def run(*); end
  end

  def test_backups_preserve_file_contents_and_permissions
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, 'old contents')
      File.chmod(0o640, path)
      MitsubachiInfra::AtomicWriter.new(runner: Runner.new).write(path, 'new contents', mode: '0640')
      backup = Dir.glob("#{path}.backup.*").fetch(0)
      assert_equal 'old contents', File.read(backup)
      assert_equal 0o640, File.stat(backup).mode & 0o777
      assert_equal 'new contents', File.read(path)
    end
  end

  def test_backups_preserve_symlink_without_overwriting_target
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'original')
      path = File.join(dir, 'config.yml')
      File.write(target, 'original contents')
      File.symlink(target, path)
      MitsubachiInfra::AtomicWriter.new(runner: Runner.new).write(path, 'new contents')
      backup = Dir.glob("#{path}.backup.*").fetch(0)
      assert File.symlink?(backup)
      assert_equal target, File.readlink(backup)
      assert_equal 'original contents', File.read(target)
      assert_equal 'new contents', File.read(path)
    end
  end
end
