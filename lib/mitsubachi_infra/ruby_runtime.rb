# frozen_string_literal: true

module MitsubachiInfra
  class RubyRuntime
    RBENV_REPOSITORY = 'https://github.com/rbenv/rbenv.git'
    RUBY_BUILD_REPOSITORY = 'https://github.com/rbenv/ruby-build.git'

    def initialize(config:, runner:)
      @config = config
      @runner = runner
    end

    def ensure!
      home = @config.fetch('deploy').fetch('home')
      version = @config.fetch('runtime').fetch('ruby_version')
      rbenv_root = File.join(home, '.rbenv')
      install_rbenv(rbenv_root)
      install_ruby_build(rbenv_root)
      install_ruby(rbenv_root, version)
      @runner.deploy('rbenv', 'global', version, config: @config)
      @runner.deploy('ruby', '-v', config: @config)
    end

    private

    def install_rbenv(rbenv_root)
      if File.directory?(File.join(rbenv_root, '.git'))
        @runner.deploy('git', '-C', rbenv_root, 'fetch', '--prune', config: @config, timeout: 1800)
      else
        @runner.deploy('git', 'clone', RBENV_REPOSITORY, rbenv_root, config: @config, timeout: 1800)
      end
    end

    def install_ruby_build(rbenv_root)
      plugins = File.join(rbenv_root, 'plugins')
      ruby_build = File.join(plugins, 'ruby-build')
      @runner.deploy('mkdir', '-p', plugins, config: @config)
      if File.directory?(File.join(ruby_build, '.git'))
        @runner.deploy('git', '-C', ruby_build, 'fetch', '--prune', config: @config, timeout: 1800)
      else
        @runner.deploy('git', 'clone', RUBY_BUILD_REPOSITORY, ruby_build, config: @config, timeout: 1800)
      end
    end

    def install_ruby(rbenv_root, version)
      versions = @runner.deploy('rbenv', 'versions', '--bare', config: @config, allow_failure: true).stdout.lines.map(&:strip)
      return if versions.include?(version)

      @runner.deploy('rbenv', 'install', version, config: @config, timeout: 7200,
                                                   env: { 'RUBY_CONFIGURE_OPTS' => '--disable-install-doc' })
      ruby_path = File.join(rbenv_root, 'versions', version, 'bin', 'ruby')
      @runner.deploy(ruby_path, '-v', config: @config)
    end
  end
end
