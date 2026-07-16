# frozen_string_literal: true

require 'fileutils'
require 'tempfile'

module MitsubachiInfra
  class AtomicWriter
    def initialize(runner:)
      @runner = runner
    end

    def write(path, content, owner: 'root', group: 'root', mode: '0644', backup: true)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      Tempfile.create([".#{File.basename(path)}", '.tmp'], dir) do |tmp|
        tmp.write(content)
        tmp.flush
        tmp.fsync
        File.chmod(mode.to_i(8), tmp.path)
        backup_path(path) if backup && (File.exist?(path) || File.symlink?(path))
        FileUtils.mv(tmp.path, path)
      end
      @runner.run('chown', "#{owner}:#{group}", path)
      @runner.run('chmod', mode, path)
    end

    private

    def backup_path(path)
      stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
      FileUtils.cp_a(path, "#{path}.backup.#{stamp}")
    end
  end
end
