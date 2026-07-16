# Commands

すべての本番操作は、利用者が本番 Ubuntu へ SSH 接続した後、その本番 Ubuntu 上で実行します。`mitsubachi-infra` が開発 Ubuntu から SSH を自動実行する設計ではありません。

正式な実行形式:

```bash
ruby exe/mitsubachi-infra <command>
```

## install / bootstrap

目的: Nginx、Certbot、systemd、UFW、deploy ユーザー、directory、env 雛形を冪等に整備します。

```bash
ruby exe/mitsubachi-infra --config /etc/mitsubachi/config.yml install --interactive
ruby exe/mitsubachi-infra --config /etc/mitsubachi/config.yml install --interactive --remove-nginx-default-site
ruby exe/mitsubachi-infra --config /etc/mitsubachi/config.yml bootstrap
```

root 権限が必要な操作は `sudo -n` または root 実行で行います。Git clone、bundle、npm は deploy ユーザーで実行します。

`--remove-nginx-default-site` は `/etc/nginx/sites-enabled/default` が symlink の場合にその symlink だけを外します。`sites-available/default` の原本や他の Nginx 設定は変更しません。Mitsubachi の Nginx 設定は通常 `default_server` を付けません。

## deploy / redeploy

backend と frontend を Git repository から取得し、release directory を新規作成して成功時だけ `current` を切り替えます。

```bash
ruby exe/mitsubachi-infra deploy
ruby exe/mitsubachi-infra deploy --backend-ref main --frontend-ref main
ruby exe/mitsubachi-infra redeploy
```

未 push の開発 Ubuntu 作業ツリーは本番へ入りません。本番では設定された Git repository と ref だけを取得します。

## deploy-backend / deploy-frontend

片方だけを更新します。

```bash
ruby exe/mitsubachi-infra deploy-backend --ref main
ruby exe/mitsubachi-infra deploy-frontend --ref main
```

## rollback

直前の release へ `current` symlink を戻します。backend rollback は DB migration を戻しません。

```bash
ruby exe/mitsubachi-infra rollback-backend
ruby exe/mitsubachi-infra rollback-frontend
```

## production-check / doctor

production-check は本番 service、Nginx、TLS endpoint、Minecraft port 設定を確認します。doctor はローカル command availability も併せて確認します。

```bash
ruby exe/mitsubachi-infra production-check
ruby exe/mitsubachi-infra doctor
```

## mail-test

本番 Rails の Action Mailer 設定を使ってテストメールを送信します。`RESEND_API_KEY` は引数へ渡しません。

```bash
ruby exe/mitsubachi-infra mail-test --to test@example.com
```

## dry-run

破壊的変更を行わず、予定コマンドを表示します。秘密値は表示しません。

```bash
ruby exe/mitsubachi-infra --dry-run bootstrap
ruby exe/mitsubachi-infra --dry-run deploy
```
