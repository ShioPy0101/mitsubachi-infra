# frozen_string_literal: true

require 'English'
require 'erb'
require 'fileutils'

module MitsubachiInfra
  class Nginx
    TARGET = '/etc/nginx/sites-available/mitsubachi.conf'
    ENABLED = '/etc/nginx/sites-enabled/mitsubachi.conf'
    UBUNTU_DEFAULT = '/etc/nginx/sites-enabled/default'

    def initialize(config:, runner:, repo_root:)
      @config = config
      @runner = runner
      @repo_root = repo_root
    end

    def render(mode:)
      template = File.read(File.join(@repo_root, 'templates', 'nginx', "#{mode}.conf.erb"))
      ERB.new(template, trim_mode: '-').result(binding)
    end

    def install(mode:)
      content = render(mode: mode)
      tmp = "/tmp/mitsubachi-nginx-#{$PROCESS_ID}.conf"
      File.write(tmp, content)
      safe_apply(tmp)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end

    def test!
      @runner.run('nginx', '-t')
    end

    def reload
      @runner.run('systemctl', 'reload', 'nginx')
    end

    private

    attr_reader :config

    def safe_apply(source)
      backup = backup_path
      previous_link = readlink(ENABLED)
      default_link = readlink(UBUNTU_DEFAULT)
      had_target = File.exist?(TARGET) || File.symlink?(TARGET)
      had_enabled = File.exist?(ENABLED) || File.symlink?(ENABLED)
      backup_existing(backup) if had_target

      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0644', source, TARGET)
      remove_ubuntu_default_site(default_link)
      @runner.run('ln', '-sfn', TARGET, ENABLED)
      test!
      reload
    rescue StandardError
      restore(target_backup: backup, had_target: had_target, had_enabled: had_enabled,
              previous_link: previous_link, default_link: default_link)
      raise
    ensure
      FileUtils.rm_f(backup) if backup && File.exist?(backup)
    end

    def backup_existing(backup)
      @runner.run('cp', '-a', TARGET, backup)
    end

    def restore(target_backup:, had_target:, had_enabled:, previous_link:, default_link:)
      @runner.run('cp', '-a', target_backup, TARGET, allow_failure: true) if had_target
      @runner.run('rm', '-f', TARGET, allow_failure: true) unless had_target

      if had_enabled && previous_link
        @runner.run('ln', '-sfn', previous_link, ENABLED, allow_failure: true)
      elsif !had_enabled
        @runner.run('rm', '-f', ENABLED, allow_failure: true)
      end

      @runner.run('ln', '-sfn', default_link, UBUNTU_DEFAULT, allow_failure: true) if default_link
      result = @runner.run('nginx', '-t', allow_failure: true)
      return if result.success?

      raise Error, "nginx rollback failed\nstdout=#{@runner.mask(result.stdout)}\nstderr=#{@runner.mask(result.stderr)}"
    end

    def remove_ubuntu_default_site(default_link)
      if default_link || @runner.dry_run
        @runner.run('rm', '-f', UBUNTU_DEFAULT)
      end
    end

    def readlink(path)
      return nil unless File.symlink?(path)

      File.readlink(path)
    end

    def backup_path
      "/tmp/mitsubachi-nginx-rollback-#{$PROCESS_ID}.conf"
    end
  end
end
