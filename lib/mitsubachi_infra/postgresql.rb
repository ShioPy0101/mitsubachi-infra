# frozen_string_literal: true

module MitsubachiInfra
  class PostgreSQL
    DATABASES = %w[
      mitsubachi_production
      mitsubachi_production_cache
      mitsubachi_production_queue
      mitsubachi_production_cable
    ].freeze

    def initialize(runner:)
      @runner = runner
    end

    def ensure_role_and_databases(role:)
      @runner.run('sudo', '-u', 'postgres', 'psql', '-v', 'ON_ERROR_STOP=1', '-c', 'SELECT 1')
      DATABASES.each do |db|
        @runner.run('sudo', '-u', 'postgres', 'createdb', '--owner', role, db, allow_failure: true)
      end
    end
  end
end
