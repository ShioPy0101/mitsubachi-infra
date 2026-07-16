# frozen_string_literal: true

require 'English'
require 'erb'
require 'fileutils'
require_relative 'atomic_writer'
require_relative 'deploy_user'
require_relative 'nginx'
require_relative 'postgresql'
require_relative 'systemd'

module MitsubachiInfra
  class Installer
    PACKAGES = %w[
      git curl ca-certificates build-essential postgresql postgresql-contrib
      nginx ufw certbot ruby-full nodejs npm rsync jq shellcheck
    ].freeze

    def initialize(config:, runner:, repo_root:)
      @config = config
      @runner = runner
      @repo_root = repo_root
    end

    def install(interactive: false)
      @runner.run('apt-get', 'update')
      @runner.run('apt-get', 'install', '-y', *PACKAGES)
      DeployUser.new(config: @config, runner: @runner).ensure!
      install_cli
      install_directories
      install_templates
    end

    private

    def install_cli
      source = File.join(@repo_root, 'bin', 'mitsubachi-infra')
      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0755', source, '/usr/local/bin/mitsubachi-infra')
    end

    def install_directories
      root = @config.fetch('deploy').fetch('app_root')
      %w[backend frontend repositories].each do |dir|
        @runner.run('install', '-d', '-o', @config.fetch('deploy').fetch('user'), '-g',
                    @config.fetch('deploy').fetch('user'), '-m', '0755', File.join(root, dir))
      end
      @runner.run('install', '-d', '-o', 'root', '-g', 'root', '-m', '0755', '/var/lib/mitsubachi/acme')
      @runner.run('install', '-d', '-o', 'root', '-g', @config.fetch('deploy').fetch('user'), '-m', '0750',
                  '/etc/mitsubachi')
    end

    def install_templates
      nginx = Nginx.new(config: @config, runner: @runner, repo_root: @repo_root)
      nginx.install(mode: @config.public? ? 'public_http_challenge' : 'lan')
      unit = ERB.new(File.read(File.join(@repo_root, 'templates', 'systemd', 'mitsubachi-api.service.erb')),
                     trim_mode: '-').result(binding)
      tmp = "/tmp/mitsubachi-api.service.#{$PROCESS_ID}"
      File.write(tmp, unit)
      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0644', tmp,
                  '/etc/systemd/system/mitsubachi-api.service')
      Systemd.new(runner: @runner).daemon_reload
      Systemd.new(runner: @runner).enable('mitsubachi-api.service')
    ensure
      FileUtils.rm_f(tmp) if tmp
    end
  end
end
