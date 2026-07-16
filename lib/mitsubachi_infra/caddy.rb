# frozen_string_literal: true

require 'erb'
require 'tempfile'

module MitsubachiInfra
  class Caddy
    def initialize(config:, runner:, repo_root:)
      @config = config
      @runner = runner
      @repo_root = repo_root
    end

    def install
      result = @runner.run('which', 'caddy', allow_failure: true)
      privileged('apt-get', 'install', '-y', 'caddy', timeout: 1800) unless result.success?
      privileged('systemctl', 'enable', 'caddy')
    end

    def configure
      target = @config.fetch('paths').fetch('caddyfile')
      Tempfile.create(['mitsubachi-caddy', '.Caddyfile']) do |tmp|
        tmp.write(render)
        tmp.flush
        tmp.fsync
        privileged('caddy', 'validate', '--config', tmp.path)
        backup(target)
        privileged('install', '-o', 'root', '-g', 'root', '-m', '0644', tmp.path, target)
      end
      privileged('caddy', 'validate', '--config', target)
      privileged('systemctl', 'reload', 'caddy')
    end

    def render
      template = File.read(File.join(@repo_root, 'templates', 'caddy', 'Caddyfile.erb'))
      ERB.new(template, trim_mode: '-').result(binding)
    end

    private

    attr_reader :config

    def backup(path)
      return unless File.exist?(path) || File.symlink?(path)

      stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
      privileged('cp', '-a', path, "#{path}.backup.#{stamp}")
    end

    def privileged(*command, **options)
      if Process.euid.zero?
        @runner.run(*command, **options)
      else
        @runner.run('sudo', '-n', *command, **options)
      end
    end
  end
end
