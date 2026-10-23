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

`install` / `bootstrap` / `configure` / `sudo mitsubachi-infra production-check` は、識別情報が未登録なら自動で初期登録します。
両方が未設定・空なら UUID を生成し、片方だけが登録済みならその値を引き継いでもう片方を補完します。
両方が登録済みで不一致なら上書きせず停止します。`--dry-run` は登録予定のみを表示し、UUID の生成や設定変更を行いません。

初期登録は他の infra 操作と同じ排他ロック内で実行します。識別ファイルを先に保存するため、config 保存の途中で失敗しても次回は同じ ID を再利用します。
設定保存時はバックアップを作成し、既存の設定値・未知のキーを保持します。YAML の再出力によりコメントや書式は変わる場合があります。
config は既存 owner/group を保って 0640、識別ファイルは root:root 0644 で配置します。
デプロイと rollback は未登録状態を自動登録せず停止し、`doctor` は読み取り専用の識別確認を維持します。

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
6. frontend は `/etc/mitsubachi/frontend.env` を安全に解析し、`VITE_API_BASE_URL` を `npm run build` の環境変数として渡す
7. 成功時だけ `current` を atomic に切り替える
8. frontend は `dist/index.html` を確認し、Nginx reload と health check を行う
9. backend は `mitsubachi-api.service` と `mitsubachi-worker.service` を restart する
10. Nginx と HTTPS endpoint を確認する

Frontend の公開 root は `/var/www/mitsubachi-frontend/current/dist` です。SPA fallback は Nginx の `try_files $uri $uri/ /index.html;` で処理します。API domain とは分離し、`mitsubachi.shiosalt.com` は React/Vite、`mitsubachi-api.shiosalt.com` は Rails API へ向けます。

## Human Tasks

初回公開時に人間が行う作業:

* DNS A/AAAA レコードを本番 Ubuntu へ向ける
* ルーターで TCP 80/443 を本番 Ubuntu へ forwarding する
* deploy ユーザーに GitHub read-only deploy key を設定する
* `/etc/mitsubachi/rails.env` の秘密値を設定する
* Resend の送信元、SPF、DKIM、DMARC を確認する
* Minecraft 25565/25566 が既存どおり到達することを確認する
* 外付け HDD が `/mnt/external-hdd` に mount されていることを確認し、必要なら WAL アーカイブを有効化する

## PostgreSQL WAL Archive

WAL アーカイブは通常 deploy とは別に有効化します。`pg_wal` を直接コピーせず、PostgreSQL の `archive_command` が `/usr/local/lib/mitsubachi-infra/postgresql/archive-wal %p %f` を呼び出して外付け HDD へ保存します。

```bash
sudo mitsubachi-infra postgres wal-archive enable
sudo mitsubachi-infra postgres wal-archive enable --verify
sudo mitsubachi-infra postgres wal-archive test
sudo mitsubachi-infra postgres wal-archive status
sudo mitsubachi-infra postgres base-backup create
sudo mitsubachi-infra postgres base-backup prune --dry-run
```

保存先:

```text
/mnt/external-hdd/mitsubachi/postgresql/
├── wal-archive/
├── base-backups/
└── scripts/
```

`archive-wal` は実行ごとに `/mnt/external-hdd` が mount point であることを確認します。外付け HDD が外れた場合は非0で失敗し、PostgreSQL は WAL を `pg_wal` に保持して再試行します。失敗が続くと `pg_wal` が肥大化するため、`postgres wal-archive status` と `pg_stat_archiver` を監視してください。

WAL アーカイブだけでは復旧できません。PITR にはベースバックアップが必要です。`base-backup create` で `pg_basebackup` によるベースバックアップを作成し、`base-backup prune` はベースバックアップのみを安全に削除します。WAL を `find -mtime -delete` のように日数だけで削除する運用は禁止です。同じ物理ディスクへの保存はディスク故障対策にならないため、別媒体への複製と復元訓練が必要です。

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


## リリースごとの Ruby バージョン

Rails の Ruby は、取得した commit の `.ruby-version`（数値の `major.minor.patch`）で決定する。
デプロイ時にファイルがない場合や不正な場合は停止し、`runtime.ruby_version` へ暗黙にフォールバックしない。
既存の `/etc/mitsubachi/config.yml` の `runtime.ruby_version: 3.3.7` は、そのまま残してよい。
これはアプリ取得前の install/bootstrap 用の明示的な初期値に限定され、デプロイ先 Ruby の固定値ではない。

Git 取得後、未導入の Ruby を deploy ユーザーの rbenv にビルドし、対象リリースの作業ディレクトリで
`Gemfile.lock` の Bundler、依存 Gem、Rails 起動・DB 接続を確認してから `current` を切り替える。
新 Ruby の準備中は `rbenv global` を変更せず、Puma/worker の停止や再起動も行わない。
ビルド、Gem 導入、起動検査に失敗した場合は旧リリースが稼働を継続する。
統合 `release` コマンドは従来どおり準備前に maintenance を有効にするが、Puma は停止せず、
migration 開始前の準備失敗では maintenance を解除する。

Ruby が未導入の場合は ruby-build を fetch しただけでなく、作業ツリーも fast-forward してからビルドする。
ローカルの追跡ファイルの変更や履歴分岐で更新できない場合は自動破棄せず停止する。
初回のこの変更の導入では、install/bootstrap で追加のビルド依存パッケージを導入し、
API/worker の systemd unit を再生成・配置する必要がある。
実際の適用とサービス再起動はリリース用ホストで利用者が実行する。開発ホストでテストしても適用済みとはならない。

systemd は `WorkingDirectory=current` の `.ruby-version` を使い、環境ファイルの
`RBENV_VERSION` / `RBENV_DIR` は起動時に除去する。
切り替え後の restart または health check が失敗した場合は、旧 `current` に戻して再起動するため、
旧 Ruby と旧リリースの Gem が同時に選択される。旧 Ruby は自動削除しない。
旧リリースが存在しない初回デプロイには切り戻し先がない。DB migration の自動 down は行わないため、
migration は旧コードと互換性を保つ必要がある。準備・切り替えに成功しても restart による短い停止は生じ得る。

導入順は infra PR の適用を先にし、アプリの `.ruby-version` 更新 PR を後にする。
実ホストでの Ruby ビルド、systemd 再起動、切り戻しは開発環境の fake テストとは別に確認する。
