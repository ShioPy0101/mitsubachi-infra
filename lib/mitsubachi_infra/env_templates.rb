# frozen_string_literal: true

module MitsubachiInfra
  module EnvTemplates
    module_function

    def rails_env(config)
      frontend = config.public? ? "https://#{config.frontend_host}" : "http://#{config.fetch('server_ip')}"
      <<~ENV
        RAILS_ENV=production
        RACK_ENV=production
        RAILS_LOG_TO_STDOUT=true
        RAILS_SERVE_STATIC_FILES=false

        APP_HOST=#{config.app_host}
        ALLOWED_HOSTS=#{config.allowed_hosts.join(',')}
        FRONTEND_ORIGIN=#{frontend}
        FRONTEND_URL=#{frontend}

        SESSION_COOKIE_SECURE=true

        DATABASE_URL=
        DATABASE_CACHE_URL=
        DATABASE_QUEUE_URL=
        DATABASE_CABLE_URL=

        RAILS_MASTER_KEY=
        SECRET_KEY_BASE=

        WEB_CONCURRENCY=0
        RESEND_API_KEY=
        MAIL_FROM=
        PORT=#{config.fetch('ports').fetch('rails')}
      ENV
    end

    def frontend_env(config)
      "VITE_API_BASE_URL=https://#{config.api_host}\n"
    end
  end
end
