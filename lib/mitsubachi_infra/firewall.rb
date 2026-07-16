# frozen_string_literal: true

module MitsubachiInfra
  class Firewall
    def initialize(config:, runner:)
      @config = config
      @runner = runner
    end

    def configure_lan
      cidr = @config.fetch('lan_cidr')
      @runner.run('ufw', 'allow', 'from', cidr, 'to', 'any', 'port', '80', 'proto', 'tcp')
      @runner.run('ufw', 'allow', 'from', cidr, 'to', 'any', 'port', '22', 'proto', 'tcp')
    end

    def configure_public(ssh_cidr:)
      @runner.run('ufw', 'allow', '80/tcp')
      @runner.run('ufw', 'allow', '443/tcp')
      @runner.run('ufw', 'allow', 'from', ssh_cidr, 'to', 'any', 'port', '22', 'proto', 'tcp')
    end
  end
end
