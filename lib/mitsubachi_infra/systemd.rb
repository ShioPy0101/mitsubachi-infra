# frozen_string_literal: true

module MitsubachiInfra
  class Systemd
    def initialize(runner:)
      @runner = runner
    end

    def daemon_reload
      @runner.run("systemctl", "daemon-reload")
    end

    def enable(unit)
      @runner.run("systemctl", "enable", unit)
    end

    def restart(unit)
      @runner.run("systemctl", "restart", unit)
    end

    def active?(unit)
      @runner.run("systemctl", "is-active", "--quiet", unit, allow_failure: true).success?
    end
  end
end
