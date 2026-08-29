# Troubleshooting

## Nginx

```bash
systemctl status nginx
journalctl -u nginx -n 200 --no-pager
nginx -t
ss -ltnp | grep -E ':(80|443)\b'
```

Mitsubachi の server block は通常 `default_server` を付けません。既存の他サービスや Ubuntu default site は勝手に削除しません。`/etc/nginx/sites-enabled/default` を外す必要がある場合だけ、明示オプションで symlink を無効化します。

## Certbot / HTTPS

```bash
mitsubachi-infra https status
certbot certificates
systemctl status certbot.timer
systemctl list-timers certbot.timer
curl -Iv https://mitsubachi.shiosalt.com/
curl -Iv https://mitsubachi-api.shiosalt.com/api/health/ready
```

証明書は frontend/API の host ごとに個別管理します。

```text
/etc/letsencrypt/live/mitsubachi.shiosalt.com/fullchain.pem
/etc/letsencrypt/live/mitsubachi-api.shiosalt.com/fullchain.pem
```

`https enable --staging` は Certbot staging endpoint だけを使います。通常の `https enable` は production endpoint を使い、staging 証明書を production として再利用しません。

## Rails API

```bash
systemctl status mitsubachi-api
journalctl -u mitsubachi-api -n 200 --no-pager
curl -H 'Host: mitsubachi-api.shiosalt.com' http://127.0.0.1:3000/api/health/ready
curl -I https://mitsubachi-api.shiosalt.com/api/health/ready
```

## Solid Queue

```bash
systemctl status mitsubachi-worker
journalctl -u mitsubachi-worker -n 200 --no-pager
```

## Frontend

```bash
mitsubachi-infra config show
mitsubachi-infra doctor frontend
test -f /var/www/mitsubachi-frontend/current/dist/index.html
curl -I https://mitsubachi.shiosalt.com
curl -I https://mitsubachi.shiosalt.com/some/spa/path
```

White screen with `VITE_API_BASE_URL is not configured`:

```bash
sudoedit /etc/mitsubachi/frontend.env
# VITE_API_BASE_URL=https://mitsubachi-api.shiosalt.com
sudo mitsubachi-infra deploy frontend --ref main
```

For LAN verification use:

```env
VITE_API_BASE_URL=http://192.168.10.151
```

Force refresh the browser after redeploy. If Cloudflare/CDN is enabled, purge or bypass HTML cache so old `index.html` does not keep loading old JavaScript.

## Network

```bash
ss -lntp
ufw status numbered
curl -I http://mitsubachi.shiosalt.com
curl -I https://mitsubachi.shiosalt.com
```

Common causes:

* DNS A/AAAA record does not point to production IP
* router does not forward 80/443
* Cloudflare Proxy is enabled before origin HTTPS / upload / timeout behavior is verified
* Nginx cannot read frontend `dist`
* Rails is not listening on `127.0.0.1:3000`
* `rails.env` is missing required DB URLs or Resend variables
* frontend was not rebuilt after `VITE_API_BASE_URL` change
* CORS or Cookie Secure settings do not match separate frontend/API domains
* `mitsubachi-worker.service` is stopped, so `deliver_later` is queued but not delivered
* Resend API key invalid or `MAIL_FROM` is not verified
* `sudo bundle exec` is used instead of deploy-user rbenv path through systemd
