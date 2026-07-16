# Production Deployment

## Topology

```text
開発 Ubuntu
  commit / push
    ↓
本番 Ubuntuへ手動SSH
    ↓
mitsubachi-infra CLI
    ├─ git clone/fetch mitsubachi-ruby as deploy
    ├─ git clone/fetch mitsubachi-front as deploy
    ├─ Rails/Puma 127.0.0.1:3000
    ├─ Solid Queue worker
    ├─ Nginx :80/:443
    └─ UFW keeps 25565/25566
```

## Server ID

誤ったホストへのデプロイを避けるため、`/etc/mitsubachi/server-id` と `config.yml` の `server.server_id` を一致させます。一致しない場合、deploy と env 更新は停止します。

## Release Layout

```text
/var/www/mitsubachi/releases/<release>
/var/www/mitsubachi/current

/var/www/mitsubachi-frontend/releases/<release>
/var/www/mitsubachi-frontend/current
```

各 release は Git repository から新規取得します。既存作業ツリーへの単純な `git pull` は使用しません。

## Deploy Flow

1. server ID を確認する
2. deploy ユーザーで repository ref を確認する
3. release directory を作成する
4. detached HEAD で commit SHA を checkout する
5. backend は bundle install、migration、`bin/jobs` 確認を行う
6. frontend は `frontend.env` を build 時に読み込み `npm run build` を行う
7. 成功時だけ `current` を atomic に切り替える
8. backend は `mitsubachi-api.service` と `mitsubachi-worker.service` を restart する
9. Nginx と HTTPS endpoint を確認する

## Human Tasks

初回公開時に人間が行う作業:

* DNS A/AAAA レコードを本番 Ubuntu へ向ける
* ルーターで TCP 80/443 を本番 Ubuntu へ forwarding する
* deploy ユーザーに GitHub read-only deploy key を設定する
* `/etc/mitsubachi/rails.env` の秘密値を設定する
* Resend の送信元、SPF、DKIM、DMARC を確認する
* Minecraft 25565/25566 が既存どおり到達することを確認する

## HTTPS

正式構成は Nginx + Certbot です。Caddy は採用しません。Nginx と Caddy を同時に 80/443 へ bind しないでください。

`/etc/mitsubachi/config.yml` の HTTPS schema:

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

Certbot は frontend/API それぞれの証明書を個別に取得します。`staging` は config に保存せず、`sudo mitsubachi-infra https enable --staging` のときだけ使います。production の `https enable` は staging 証明書を production 証明書として再利用しません。

事前確認:

```bash
dig +short A mitsubachi.shiosalt.com
dig +short AAAA mitsubachi.shiosalt.com
dig +short A mitsubachi-api.shiosalt.com
dig +short AAAA mitsubachi-api.shiosalt.com

sudo nginx -t
sudo ss -ltnp | grep -E ':(80|443)\b'
sudo ufw status verbose
sudo systemctl status nginx
```

有効化:

```bash
sudo mitsubachi-infra https check
sudo mitsubachi-infra https enable --staging
sudo mitsubachi-infra https enable
```

確認:

```bash
sudo certbot certificates
sudo systemctl status certbot.timer
sudo systemctl list-timers certbot.timer
curl -Iv https://mitsubachi.shiosalt.com/
curl -Iv https://mitsubachi-api.shiosalt.com/api/health/ready
```

Cloudflare は初期運用では DNS only を推奨します。Cloudflare Proxy は大容量 upload/download、Range Request、timeout、real client IP、Cloudflare 側 upload 制限への影響を確認するまで完全対応済みとして扱いません。
