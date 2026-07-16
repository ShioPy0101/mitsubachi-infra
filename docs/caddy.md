# Caddy

Caddy は現在の正式構成では使用しません。HTTPS は Nginx + Certbot で管理します。

この文書は将来案または別ブランチで Caddy 移行を検討する場合のメモです。Nginx と Caddy を同時に 80/443 へ bind しないでください。

## Responsibilities

* `mitsubachi.shiosalt.com` を frontend static files へ配信する
* SPA fallback として `try_files {path} /index.html` を使う
* `mitsubachi-api.shiosalt.com` を `127.0.0.1:3000` へ reverse proxy する
* TLS 証明書を Caddy の自動 HTTPS で管理する
* HTTP 80 を HTTPS redirect と ACME に使用する

## Validation

Caddyfile は配置前後に validation します。

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

validation に失敗した場合は reload しません。証明書秘密鍵は Git、`/var/www`、deploy ユーザー home、frontend env に置きません。
