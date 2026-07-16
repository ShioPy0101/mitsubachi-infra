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
    ├─ Caddy :80/:443
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
8. backend は `mitsubachi-api.service` と `mitsubachi-jobs.service` を restart する
9. Caddy と HTTPS endpoint を確認する

## Human Tasks

初回公開時に人間が行う作業:

* DNS A/AAAA レコードを本番 Ubuntu へ向ける
* ルーターで TCP 80/443 を本番 Ubuntu へ forwarding する
* deploy ユーザーに GitHub read-only deploy key を設定する
* `/etc/mitsubachi/rails.env` の秘密値を設定する
* Resend の送信元、SPF、DKIM、DMARC を確認する
* Minecraft 25565/25566 が既存どおり到達することを確認する
