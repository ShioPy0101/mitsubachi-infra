# Troubleshooting

## Caddy

```bash
systemctl status caddy
journalctl -u caddy -n 200 --no-pager
caddy validate --config /etc/caddy/Caddyfile
```

## Rails API

```bash
systemctl status mitsubachi-api
journalctl -u mitsubachi-api -n 200 --no-pager
curl http://127.0.0.1:3000/api/health
curl -I https://mitsubachi-api.shiosalt.com/api/health
```

## Solid Queue

```bash
systemctl status mitsubachi-jobs
journalctl -u mitsubachi-jobs -n 200 --no-pager
```

## Frontend

```bash
test -f /var/www/mitsubachi-frontend/current/dist/index.html
curl -I https://mitsubachi.shiosalt.com
curl -I https://mitsubachi.shiosalt.com/some/spa/path
```

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
* Caddy cannot read frontend `dist`
* Rails is not listening on `127.0.0.1:3000`
* `rails.env` is missing required DB URLs or Resend variables
* frontend was not rebuilt after `VITE_API_BASE_URL` change
* CORS or Cookie Secure settings do not match separate frontend/API domains
* `mitsubachi-jobs.service` is stopped, so `deliver_later` is queued but not delivered
* Resend API key invalid or `MAIL_FROM` is not verified
* `sudo bundle exec` is used instead of deploy-user rbenv path through systemd
