# frozen_string_literal: true

require_relative 'errors'

module MitsubachiInfra
  class RubyRuntime
    RBENV_REPOSITORY = 'https://github.com/rbenv/rbenv.git'
    RUBY_BUILD_REPOSITORY = 'https://github.com/rbenv/ruby-build.git'

    def initialize(config:, runner:)
      @config = config
      @runner = runner
    end

    # release 指定時はアプリの宣言だけを信頼し、ホスト全体の Ruby は変更しない。
    # 設定値はアプリ取得前の bootstrap 用にだけ残す。
    def ensure!(release: nil)
      home = @config.fetch('deploy').fetch('home')
      version = release ? release_version(release) : validate_version!(@config.fetch('runtime').fetch('ruby_version'))
      return if version.nil? # dry-run では未取得の release を読めない。
      rbenv_root = File.join(home, '.rbenv')
      install_rbenv(rbenv_root)
      install_ruby(rbenv_root, version)
      @runner.deploy('rbenv', 'global', version, config: @config) unless release
      @runner.deploy('ruby', '-e', "abort RUBY_VERSION unless RUBY_VERSION == #{version.inspect}",
                     config: @config, chdir: release, env: { 'RBENV_VERSION' => version })
      version
    end

    # 欠落・複数行・シェル式などを許可せず、設定値への暗黙の退避もしない。
    def release_version(release)
      path = File.join(release, '.ruby-version')
      return nil if @runner.dry_run && !File.exist?(path)
      raise ValidationError, "missing release Ruby version: #{path}" unless File.file?(path)

      validate_version!(File.read(path).strip)
    end

    private

    def validate_version!(version)
      return version if version.is_a?(String) && version.match?(/\A[0-9]+\.[0-9]+\.[0-9]+\z/)

      raise ValidationError, 'Ruby version must be an exact numeric major.minor.patch'
    end

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
        # fetch だけでは新しい Ruby のビルド定義が作業ツリーに反映されない。
        # ローカルの変更や分岐した履歴を上書きせず、更新できなければ準備段階で停止する。
        @runner.deploy('git', '-C', ruby_build, 'diff', '--exit-code', 'HEAD', config: @config)
        @runner.deploy('git', '-C', ruby_build, 'fetch', 'origin', 'HEAD', config: @config, timeout: 1800)
        @runner.deploy('git', '-C', ruby_build, 'merge', '--ff-only', 'FETCH_HEAD', config: @config)
      else
        @runner.deploy('git', 'clone', RUBY_BUILD_REPOSITORY, ruby_build, config: @config, timeout: 1800)
      end
    end

    def install_ruby(rbenv_root, version)
      versions = @runner.deploy('rbenv', 'versions', '--bare', config: @config, allow_failure: true).stdout.lines.map(&:strip)
      return if versions.include?(version)

      install_ruby_build(rbenv_root)
      @runner.deploy('rbenv', 'install', version, config: @config, timeout: 7200,
                                                   env: { 'RUBY_CONFIGURE_OPTS' => '--disable-install-doc' })
      ruby_path = File.join(rbenv_root, 'versions', version, 'bin', 'ruby')
      @runner.deploy(ruby_path, '-v', config: @config)
    end
  end
end
