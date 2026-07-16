# frozen_string_literal: true

module MitsubachiInfra
  module EnvTemplates
    module_function

    def rails_env(config)
      api = config.fetch("domains").fetch("api")
      frontend = "https://#{config.fetch("domains").fetch("frontend")}"
      <<~ENV
        RAILS_ENV=production
        RACK_ENV=production
        RAILS_LOG_TO_STDOUT=true
        RAILS_SERVE_STATIC_FILES=false

        APP_HOST=#{api}
        FRONTEND_ORIGIN=#{frontend}
        FRONTEND_URL=#{frontend}

        SESSION_COOKIE_SECURE=true

        DATABASE_URL=
        DATABASE_CACHE_URL=
        DATABASE_QUEUE_URL=
        DATABASE_CABLE_URL=

        RAILS_MASTER_KEY=
        SECRET_KEY_BASE=

        RESEND_API_KEY=
        MAIL_FROM=
      ENV
    end

    def frontend_env(config)
      "VITE_API_BASE_URL=https://#{config.fetch("domains").fetch("api")}\n"
    end
  end
end
