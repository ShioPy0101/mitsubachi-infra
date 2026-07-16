# frozen_string_literal: true

require 'tmpdir'
require_relative 'errors'

module MitsubachiInfra
  class NodeRuntime
    def initialize(config:, runner:)
      @config = config
      @runner = runner
    end

    def ensure!
      required = Integer(@config.fetch('runtime').fetch('node_major'))
      return verify_npm if installed_major.to_i >= required

      install_nodesource(required)
      return verify_npm if @runner.dry_run

      major = installed_major
      raise Error, "Node.js major #{required} is required, got #{major || 'missing'}" unless major.to_i >= required

      verify_npm
    end

    private

    def installed_major
      result = @runner.run('node', '--version', allow_failure: true)
      return nil unless result.success?

      result.stdout[/v?(\d+)/, 1]&.to_i
    end

    def install_nodesource(major)
      @runner.run('apt-get', 'install', '-y', 'ca-certificates', 'curl', 'gnupg')
      @runner.run('install', '-d', '-m', '0755', '/etc/apt/keyrings')
      @runner.run('bash', '-lc',
                  'curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg')
      write_source_list(major)
      @runner.run('apt-get', 'update')
      @runner.run('apt-get', 'install', '-y', 'nodejs')
    end

    def write_source_list(major)
      content = "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_#{major}.x nodistro main\n"
      tmp = File.join(Dir.tmpdir, "mitsubachi-nodesource-#{$PROCESS_ID}.list")
      File.write(tmp, content)
      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0644', tmp,
                  '/etc/apt/sources.list.d/nodesource.list')
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def verify_npm
      @runner.run('node', '--version')
      @runner.run('npm', '--version')
    end
  end
end
