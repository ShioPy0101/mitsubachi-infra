# Commands

すべての本番操作は、利用者が本番 Ubuntu へ SSH 接続した後、その本番 Ubuntu 上で実行します。`mitsubachi-infra` が開発 Ubuntu から SSH を自動実行する設計ではありません。

## 実行場所ごとの入口

初回構築前はPATH上のCLIがまだ存在しないため、cloneしたInfraリポジトリで次を実行します。system Ruby、Git、sudoが未導入のUbuntuでは最小bootstrapを使います。

```bash
cd /path/to/mitsubachi-infra
sudo ./scripts/install_local.sh --interactive
```

必要なコマンドが既に揃っている場合や、更新内容を先に確認する場合はリポジトリ版CLIを直接使います。

```bash
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml --dry-run install
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml install
```

初回install後の日常運用は、`/usr/local/bin`へ導入されたCLIをPATHから実行します。

```bash
sudo mitsubachi-infra <command>
```

`--config`と`--dry-run`はグローバルオプションなので、正規の記載ではcommandより前に置きます。

```bash
sudo mitsubachi-infra --config /etc/mitsubachi/config.yml --dry-run deploy frontend --ref main
```

`ruby exe/mitsubachi-infra`、`deploy-backend`、`deploy-frontend`、`rollback-backend`などの旧入口・別名は通常手順では使用しません。互換用スクリプトを使う必要がある障害対応を除き、以降の用途別コマンドを使用してください。

## install / bootstrap

目的: Nginx、Certbot、systemd、UFW、deploy ユーザー、directory、env 雛形を冪等に整備します。

```bash
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml --dry-run install
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml install --interactive
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml install --interactive --remove-nginx-default-site
```

root 権限が必要な操作は `sudo -n` または root 実行で行います。Git clone、bundle、npm は deploy ユーザーで実行します。

`--remove-nginx-default-site` は `/etc/nginx/sites-enabled/default` が symlink の場合にその symlink だけを外します。`sites-available/default` の原本や他の Nginx 設定は変更しません。Mitsubachi の Nginx 設定は通常 `default_server` を付けません。

## 通常のアプリ更新

backend と frontend を Git repository から取得し、release directory を新規作成して成功時だけ `current` を切り替えます。

```bash
sudo mitsubachi-infra deploy
sudo mitsubachi-infra deploy backend --ref main
sudo mitsubachi-infra deploy frontend --ref main
```

未 push の開発 Ubuntu 作業ツリーは本番へ入りません。本番では設定された Git repository と ref だけを取得します。

`/etc/mitsubachi/frontend.env` の `VITE_API_BASE_URL` を変更した場合は frontend だけを再ビルドできます。

```bash
sudo mitsubachi-infra config show
sudo mitsubachi-infra --dry-run deploy frontend --ref main
sudo mitsubachi-infra deploy frontend --ref main
```

backendとfrontendを別々のrefへ固定し、DBバックアップ、migration、smoke test、release reportを一体で扱う本番リリースには統合リリースを使います。

```bash
sudo mitsubachi-infra --dry-run deploy release --backend-ref <commit-or-tag> --frontend-ref <commit-or-tag>
sudo mitsubachi-infra deploy release --backend-ref <commit-or-tag> --frontend-ref <commit-or-tag>
```

## rollback

直前の release へ `current` symlink を戻します。backend rollback は DB migration を戻しません。

```bash
sudo mitsubachi-infra --dry-run rollback backend
sudo mitsubachi-infra rollback backend
sudo mitsubachi-infra rollback frontend
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
    root_directory: /mnt/external-hdd/mitsubachi/postgresql
    archive_directory: /mnt/external-hdd/mitsubachi/postgresql/wal-archive
    base_backup_directory: /mnt/external-hdd/mitsubachi/postgresql/base-backups
    scripts_directory: /mnt/external-hdd/mitsubachi/postgresql/scripts
    archive_script: /usr/local/lib/mitsubachi-infra/postgresql/archive-wal
    version:
    cluster:
    archive_timeout: 300s
    base_backup_retention_days: 30
    minimum_base_backups: 2
```

```bash
sudo mitsubachi-infra postgres wal-archive enable
sudo mitsubachi-infra postgres wal-archive enable --verify
sudo mitsubachi-infra postgres wal-archive test
sudo mitsubachi-infra postgres wal-archive status
sudo mitsubachi-infra postgres wal-archive status --json
sudo mitsubachi-infra postgres wal-archive disable
sudo mitsubachi-infra postgres base-backup create
sudo mitsubachi-infra postgres base-backup list
sudo mitsubachi-infra postgres base-backup prune --dry-run
```

`enable` は `/mnt/external-hdd` が mount point であることを確認してから、`postgres:postgres 0700` の保存先、root所有の `/usr/local/lib/mitsubachi-infra/postgresql/archive-wal` を冪等に配置し、`ALTER SYSTEM SET` で `wal_level=replica`、`archive_mode=on`、`archive_command`、`archive_timeout=300s` を設定します。`wal_level` または `archive_mode` が変わる場合は `pg_ctlcluster <version> <cluster> restart` を実行します。

WAL アーカイブだけでは復旧できません。PITR にはベースバックアップが必要です。`base-backup create` は `pg_basebackup --wal-method=stream --manifest-checksums=SHA256` を使い、`.partial` ディレクトリから成功時だけ正式名へ rename します。`prune` は保持対象外のベースバックアップだけを削除し、WAL は自動削除しません。保持中の最古ベースバックアップに必要なWALを誤削除しないためです。

同じ物理ディスクへ保存したバックアップは、DB本体ディスクの故障対策になりません。別ディスク、NAS、またはoffsite backupへ複製してください。

## dry-run

破壊的変更を行わず、予定コマンドを表示します。秘密値は表示しません。

```bash
sudo mitsubachi-infra --dry-run install
sudo mitsubachi-infra --dry-run deploy
```

## Infra自身の更新

アプリの`deploy`はbackend/frontendだけを更新し、Infra CLIやNginx/systemdテンプレートは更新しません。Infra自身は、本番Ubuntu上のclone済みリポジトリを管理ユーザーで更新した後、そのチェックアウトに含まれるCLIから`install`を再実行して反映します。Git操作に`sudo`は付けません。

まずリポジトリと対象branchを確認します。次の`<infra-repository>`と`<branch>`は実際のclone先・リリース対象branchへ置き換えてください。

```bash
cd <infra-repository>
git status --short
git branch --show-current
git remote -v
git rev-parse HEAD
```

未コミット変更が表示された場合は停止し、内容と作成者を確認します。`git pull`、`git reset --hard`、`git clean`で破棄してはいけません。branchが正しいことを確認できた場合だけfast-forwardで取得し、反映対象commitを記録します。

```bash
git pull --ff-only origin <branch>
git rev-parse HEAD
git log -1 --oneline
```

`--ff-only`で失敗した場合は履歴不一致として停止し、自動merge/rebaseを行いません。取得後は、インストール済みの旧CLIではなく、更新したリポジトリの`./bin/mitsubachi-infra`を使う点が重要です。

```bash
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml --dry-run install
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml install
```

`install`は新しいCLI releaseを`/opt/mitsubachi-infra/releases/`へ作成し、`/opt/mitsubachi-infra/current`と`/usr/local/bin/mitsubachi-infra`をsymlinkで切り替えます。更新元CLIから新CLIへ一度だけ再実行した後、Nginx、systemd、directory、env雛形などを冪等に適用します。開発Ubuntuでのcommit/pushだけでは、この工程は実行されません。

反映後はCLIの実体、生成・配置された設定、serviceを本番Ubuntuで確認します。

```bash
readlink -f /usr/local/bin/mitsubachi-infra
readlink -f /opt/mitsubachi-infra/current
sudo mitsubachi-infra status
sudo mitsubachi-infra production-check
sudo nginx -T
sudo systemctl cat mitsubachi-api.service
sudo systemctl cat mitsubachi-worker.service
sudo systemctl status mitsubachi-api.service mitsubachi-worker.service nginx.service --no-pager
```

### Infra更新のロールバック

適用前のcommit SHAを確認し、そのcommitを通常のGit手順でbranchまたはtagとして取得できる状態にしてから、旧commitのチェックアウトに含まれる`./bin/mitsubachi-infra install`を再実行します。`/opt/mitsubachi-infra/current`を手作業で付け替えるだけでは、既に配置されたNginx/systemd設定を戻せないため、通常のロールバック手段にはしません。

```bash
git status --short
git branch --show-current
git remote -v
git switch <rollback-branch>
git rev-parse HEAD
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml --dry-run install
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml install
```

未コミット変更がある場合や、旧commitを指すbranchが用意されていない場合はここで停止します。反映後は上記と同じ`nginx -T`、`systemctl cat`、`status`、`production-check`で確認してください。アプリreleaseのrollbackとDB復元はInfra自身の更新とは別作業です。
