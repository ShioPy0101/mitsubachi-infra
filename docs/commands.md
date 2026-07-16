# Commands

すべての本番操作は、利用者が本番 Ubuntu へ SSH 接続した後、その本番 Ubuntu 上で実行します。`mitsubachi-infra` が開発 Ubuntu から SSH を自動実行する設計ではありません。

正式な実行形式:

```bash
mitsubachi-infra <command>
```

## install / bootstrap

目的: Nginx、Certbot、systemd、UFW、deploy ユーザー、directory、env 雛形を冪等に整備します。

```bash
sudo mitsubachi-infra --config /etc/mitsubachi/config.yml install --interactive
sudo mitsubachi-infra --config /etc/mitsubachi/config.yml install --interactive --remove-nginx-default-site
sudo mitsubachi-infra --config /etc/mitsubachi/config.yml bootstrap
```

root 権限が必要な操作は `sudo -n` または root 実行で行います。Git clone、bundle、npm は deploy ユーザーで実行します。

`--remove-nginx-default-site` は `/etc/nginx/sites-enabled/default` が symlink の場合にその symlink だけを外します。`sites-available/default` の原本や他の Nginx 設定は変更しません。Mitsubachi の Nginx 設定は通常 `default_server` を付けません。

## deploy / redeploy

backend と frontend を Git repository から取得し、release directory を新規作成して成功時だけ `current` を切り替えます。

```bash
sudo mitsubachi-infra deploy
sudo mitsubachi-infra deploy --all
sudo mitsubachi-infra deploy --backend
sudo mitsubachi-infra deploy --frontend
sudo mitsubachi-infra deploy --backend-ref main --frontend-ref main
sudo mitsubachi-infra redeploy
```

未 push の開発 Ubuntu 作業ツリーは本番へ入りません。本番では設定された Git repository と ref だけを取得します。

`/etc/mitsubachi/frontend.env` の `VITE_API_BASE_URL` を変更した場合は frontend だけを再ビルドできます。

```bash
sudo mitsubachi-infra config show
sudo mitsubachi-infra deploy --frontend
```

## deploy-backend / deploy-frontend

片方だけを更新します。

```bash
sudo mitsubachi-infra deploy-backend --ref main
sudo mitsubachi-infra deploy-frontend --ref main
```

## rollback

直前の release へ `current` symlink を戻します。backend rollback は DB migration を戻しません。

```bash
sudo mitsubachi-infra rollback-backend
sudo mitsubachi-infra rollback-frontend
```

## production-check / doctor

production-check は本番 service、Nginx、TLS endpoint、Minecraft port 設定を確認します。doctor はローカル command availability も併せて確認します。

```bash
sudo mitsubachi-infra production-check
mitsubachi-infra doctor
mitsubachi-infra doctor frontend
mitsubachi-infra config show
```

## https

public mode の HTTPS は Nginx + Certbot で管理します。Certbot が Let's Encrypt 証明書を取得・更新し、Nginx は取得済み証明書で TLS 終端、frontend 静的配信、Rails API reverse proxy、HTTP -> HTTPS redirect、ACME HTTP-01 challenge 配信を行います。

設定キーは frontend/API の2ホストです。旧 `https.host` と永続 `https.staging` は使いません。

```yaml
https:
  frontend_host: mitsubachi.shiosalt.com
  api_host: mitsubachi-api.shiosalt.com
  email: admin@example.com
  challenge: http-01
  acme_webroot: /var/lib/mitsubachi/acme
  enable_hsts: false
```

```bash
sudo mitsubachi-infra https check
sudo mitsubachi-infra https enable --staging
sudo mitsubachi-infra https enable
sudo mitsubachi-infra https renew
sudo mitsubachi-infra https status
sudo mitsubachi-infra https status --json
```

`https enable` は通常 production endpoint を使います。`--staging` を明示した場合だけ Certbot へ `--staging` を渡します。dry-run は subcommand 後にも指定できます。

```bash
sudo mitsubachi-infra https enable --staging --dry-run
sudo mitsubachi-infra https renew --dry-run
```

## mail-test

本番 Rails の Action Mailer 設定を使ってテストメールを送信します。`RESEND_API_KEY` は引数へ渡しません。

```bash
sudo mitsubachi-infra mail-test --to test@example.com
```

## postgres wal-archive

PostgreSQL の WAL アーカイブを外付け HDD へ保存する設定です。PostgreSQL version / cluster は `pg_lsclusters` から自動検出します。稼働中 cluster が複数ある場合は、`/etc/mitsubachi/config.yml` の `postgresql.wal_archive.version` と `cluster` を指定してください。

```yaml
postgresql:
  wal_archive:
    mount_point: /mnt/external-hdd
    archive_directory: /mnt/external-hdd/mitsubachi/backups/wal
    archive_script: /usr/local/libexec/mitsubachi/archive-wal
    config_filename: 90-mitsubachi-wal-archive.conf
    version:
    cluster:
    archive_timeout:
```

```bash
sudo mitsubachi-infra postgres wal-archive configure
sudo mitsubachi-infra postgres wal-archive configure --verify
sudo mitsubachi-infra postgres wal-archive verify
sudo mitsubachi-infra postgres wal-archive status
sudo mitsubachi-infra postgres wal-archive status --json
```

`configure` は `/mnt/external-hdd` が mount point であることを確認してから、`postgres:postgres 0700` の保存先、`/usr/local/libexec/mitsubachi/archive-wal`、PostgreSQL の `conf.d/90-mitsubachi-wal-archive.conf` を冪等に配置します。2回目以降、設定と runtime が期待値なら PostgreSQL を再起動しません。

WAL アーカイブだけでは復旧できません。PITR にはベースバックアップが必要です。WAL を日数だけで削除する運用は禁止し、保存期限管理は pgBackRest / Barman などのバックアップツールで扱います。

## dry-run

破壊的変更を行わず、予定コマンドを表示します。秘密値は表示しません。

```bash
sudo mitsubachi-infra --dry-run bootstrap
sudo mitsubachi-infra --dry-run deploy
```
