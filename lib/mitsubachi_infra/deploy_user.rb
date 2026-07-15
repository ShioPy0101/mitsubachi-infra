# frozen_string_literal: true

require "etc"
require "fileutils"

module MitsubachiInfra
  class DeployUser
    def initialize(config:, runner:)
      @config = config
      @runner = runner
    end

    def ensure!
      deploy = @config.fetch("deploy")
      user = deploy.fetch("user")
      home = deploy.fetch("home")
      unless user_exists?(user)
        @runner.run("useradd", "--system", "--create-home", "--home-dir", home, "--shell", "/bin/bash", "--user-group", user)
      end
      @runner.run("install", "-d", "-o", user, "-g", user, "-m", "0700", File.join(home, ".ssh"))
      @runner.run("install", "-d", "-o", user, "-g", user, "-m", "0755", @config.fetch("deploy").fetch("app_root"))
      @runner.run("install", "-d", "-o", user, "-g", user, "-m", "0755", @config.backend_root, @config.frontend_root, @config.repositories_root)
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
