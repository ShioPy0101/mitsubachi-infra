# Environment Variables

## Rails: `/etc/mitsubachi/rails.env`

| Name | Required | Secret | Example | Purpose | Operation after change |
| --- | --- | --- | --- | --- | --- |
| `RAILS_ENV` | yes | no | `production` | Rails environment | restart API/jobs |
| `RACK_ENV` | yes | no | `production` | Rack environment | restart API/jobs |
| `APP_HOST` | yes | no | `mitsubachi-api.shiosalt.com` | Rails host authorization and URL generation | restart API/jobs |
| `ALLOWED_HOSTS` | yes | no | `mitsubachi-api.shiosalt.com,127.0.0.1,localhost` | Rails Host Authorization allowlist | restart API/jobs |
| `FRONTEND_ORIGIN` | yes | no | `https://mitsubachi.shiosalt.com` | CORS / CSRF origin | restart API/jobs |
| `FRONTEND_URL` | yes | no | `https://mitsubachi.shiosalt.com` | Mail and frontend links | restart API/jobs |
| `SESSION_COOKIE_SECURE` | yes | no | `true` | Secure Cookie | restart API/jobs |
| `DATABASE_URL` | yes | yes | redacted | primary DB | restart API/jobs |
| `DATABASE_CACHE_URL` | yes | yes | redacted | Rails cache DB | restart API/jobs |
| `DATABASE_QUEUE_URL` | yes | yes | redacted | Solid Queue DB | restart API/jobs |
| `DATABASE_CABLE_URL` | yes | yes | redacted | Action Cable DB | restart API/jobs |
| `RAILS_MASTER_KEY` | yes | yes | redacted | credentials decrypt | restart API/jobs |
| `SECRET_KEY_BASE` | yes | yes | redacted | cookies/signing | restart API/jobs |
| `RESEND_API_KEY` | yes | yes | redacted | Rails mail delivery | restart API/jobs |
| `MAIL_FROM` | yes | no | `Mitsubachi <no-reply@shiosalt.com>` | verified sender | restart API/jobs |

## Frontend: `/etc/mitsubachi/frontend.env`

| Name | Required | Secret | Example | Purpose | Operation after change |
| --- | --- | --- | --- | --- | --- |
| `VITE_API_BASE_URL` | yes | no | `https://mitsubachi-api.shiosalt.com` | Vite build-time API base URL | rebuild frontend |

`VITE_` variables are embedded in browser assets. Do not put `RESEND_API_KEY`, DB passwords, Rails master key, SMTP password, or signing keys into frontend env.

## HTTPS config: `/etc/mitsubachi/config.yml`

HTTPS の公開 host は Rails/frontend env ではなく infra config で管理します。frontend と Rails API は別 host です。

```yaml
deployment_mode: public

https:
  frontend_host: mitsubachi.shiosalt.com
  api_host: mitsubachi-api.shiosalt.com
  email: admin@example.com
  challenge: http-01
  acme_webroot: /var/lib/mitsubachi/acme
  enable_hsts: false
```

`https.host` は旧 schema であり拒否されます。`staging` は永続設定ではなく、`mitsubachi-infra https enable --staging` の CLI オプションとしてだけ指定します。証明書秘密鍵や ACME account credential は config/env に保存しません。
