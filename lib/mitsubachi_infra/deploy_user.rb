# frozen_string_literal: true

require 'etc'
require 'fileutils'

module MitsubachiInfra
  class DeployUser
    def initialize(config:, runner:)
      @config = config
      @runner = runner
    end

    def ensure!
      deploy = @config.fetch('deploy')
      user = deploy.fetch('user')
      home = deploy.fetch('home')
      unless user_exists?(user)
        @runner.run('useradd', '--system', '--create-home', '--home-dir', home, '--shell', '/bin/bash', '--user-group',
                    user)
      end
      @runner.run('install', '-d', '-o', user, '-g', user, '-m', '0700', File.join(home, '.ssh'))
      @runner.run('touch', File.join(home, '.ssh', 'authorized_keys'))
      @runner.run('chown', "#{user}:#{user}", File.join(home, '.ssh', 'authorized_keys'))
      @runner.run('chmod', '0600', File.join(home, '.ssh', 'authorized_keys'))
      @runner.run('touch', File.join(home, '.ssh', 'known_hosts'))
      @runner.run('chown', "#{user}:#{user}", File.join(home, '.ssh', 'known_hosts'))
      @runner.run('chmod', '0644', File.join(home, '.ssh', 'known_hosts'))
      known_hosts = File.join(home, '.ssh', 'known_hosts')
      known = @runner.run('ssh-keygen', '-F', 'github.com', '-f', known_hosts, allow_failure: true).success?
      unless known
        result = @runner.run('ssh-keyscan', '-H', 'github.com', allow_failure: true)
        File.open(known_hosts, 'a') { |file| file.write(result.stdout) } if result.success? && !@runner.dry_run
        @runner.run('chown', "#{user}:#{user}", known_hosts)
        @runner.run('chmod', '0644', known_hosts)
      end
      @runner.run('install', '-d', '-o', user, '-g', user, '-m', '0755', @config.fetch('deploy').fetch('app_root'))
      @runner.run('install', '-d', '-o', user, '-g', user, '-m', '0755',
                  @config.backend_root, File.join(@config.backend_root, 'releases'), @config.backend_repository_cache,
                  @config.frontend_root, File.join(@config.frontend_root, 'releases'),
                  @config.frontend_repository_cache)
    end

    private

    def user_exists?(user)
      Etc.getpwnam(user)
      true
    rescue ArgumentError
      false
    end
  end
end
