# mitsubachi-infra

`mitsubachi-infra` は、同一ローカルネットワーク内の Ubuntu 24.04 LTS サーバーへ Mitsubachi を LAN HTTP で安全に配置・運用するための Infra リポジトリです。

今回の対象は **LAN 内 HTTP** です。インターネット公開、公開 DNS、Cloudflare、Certbot、公開 HTTPS、Caddy、Docker、Kubernetes、GitHub Actions 自動 deploy は対象外です。

## リポジトリ責務

本システムは 3 つの独立した Git リポジトリで構成します。今回変更するのは Infra だけです。

```text
Infra:
git@github.com:ShioPy0101/mitsubachi-infra.git

Rails API:
git@github.com:ShioPy0101/mitsubachi-ruby.git

Frontend:
git@github.com:ShioPy0101/mitsubachi-front.git
```

```text
mitsubachi-infra
  Ubuntu 初期構築
  Nginx
  systemd
  LAN 設定
  deploy / rollback
  backup
  運用ドキュメント

mitsubachi-ruby
  Rails API
  database migration
  Puma
  Cookie session / CSRF
  file metadata
  X-Accel-Redirect response
  admin API

mitsubachi-front
  frontend application
  static assets
  browser UI
  Rails API client
```

Infra リポジトリの `origin` と、`deploy_api.sh` が取得する Rails API リポジトリは別物です。

```text
現在の repository origin
  = git@github.com:ShioPy0101/mitsubachi-infra.git

deploy_api.sh の既定 --repo-url
  = git@github.com:ShioPy0101/mitsubachi-ruby.git
```

`deploy_api.sh` は Rails API を `/var/www/mitsubachi/repo` へ mirror clone/fetch し、解決した commit SHA から `/var/www/mitsubachi/releases/<release>` を作ります。Infra リポジトリ内へ Rails コードを clone したり、submodule として追加したり、コピーしたりしません。

Frontend は今回未実装です。将来は `git@github.com:ShioPy0101/mitsubachi-front.git` を別手順で build/deploy し、同一 Nginx origin の `/` で公開します。

```text
http://<ubuntu-private-ip>/
  -> mitsubachi-front

http://<ubuntu-private-ip>/api/*
  -> mitsubachi-ruby
```

## Architecture

```text
LAN client
  -> http://<ubuntu-private-ip>
  -> Nginx :80
  -> Rails / Puma 127.0.0.1:3001
  -> PostgreSQL
```

file download:

```text
browser
  -> Rails authentication / authorization
  -> X-Accel-Redirect: /internal/storage/drive_items/:storage_key
  -> Nginx internal location
  -> /mnt/external-hdd/mitsubachi/files/drive_items/:storage_key
```

Rails/Puma の `127.0.0.1:3001` と PostgreSQL の `5432` は LAN に公開しません。LAN client から見える入口は Nginx の `:80` だけです。

## ディレクトリ設計

```text
/var/www/mitsubachi
├── repo
├── releases
├── current -> releases/<release-name>
└── shared
    ├── log
    ├── tmp
    └── deployments.log
```

外付け HDD:

```text
/mnt/external-hdd/mitsubachi/
├── files/
│   └── drive_items/
├── tmp/
│   └── bulk_downloads/
└── backups/
    ├── postgres/
    └── storage/
```

`/srv/mitsubachi` は使いません。PostgreSQL のデータディレクトリ本体は Ubuntu 標準構成の内蔵ディスク上に維持し、backup 成果物だけを外付け HDD に保存します。

## 権限設計

storage 共有 group として `mitsubachi-files` を作ります。

```text
deploy
  Rails service user
  files と tmp に読み書き可能

www-data
  Nginx worker user
  files を読み取り可能
  files へ書き込み不可

backups
  root:root 0700
  一般ユーザーから読めない
```

`bootstrap_ubuntu.sh` は `deploy` と `www-data` を `mitsubachi-files` group に追加します。外付け HDD 上の `files` / `tmp` は `deploy:mitsubachi-files`、mode `0750`、setgid 付きです。Nginx は `X-Accel-Redirect` で files を読むだけなので、`www-data` に write 権限を与えません。

exFAT や NTFS は Unix ownership / permission の扱いが ext4 と異なります。Linux サーバー専用運用なら ext4 を推奨します。

## 外付け HDD

`/mnt/external-hdd` は、ディレクトリが存在するだけでは利用可能と判断しません。すべての保存・backup・Rails 起動前に次を確認します。

```bash
mountpoint -q /mnt/external-hdd
```

これにより、HDD 未接続時に root filesystem 上の `/mnt/external-hdd` へ誤保存する事故を避けます。

UUID 確認:

```bash
lsblk -f
sudo blkid
```

filesystem 確認:

```bash
findmnt /mnt/external-hdd
df -Th /mnt/external-hdd
```

`/etc/fstab` 例:

```fstab
UUID=<your-external-hdd-uuid> /mnt/external-hdd ext4 defaults,nofail,x-systemd.device-timeout=10s 0 2
```

`nofail` を使う場合でも、Rails service は `RequiresMountsFor=/mnt/external-hdd/mitsubachi/files` と `ExecStartPre=/usr/bin/mountpoint -q /mnt/external-hdd` で mount を必須にします。boot は継続できても、HDD がない状態で Rails は起動しません。

mount:

```bash
sudo mkdir -p /mnt/external-hdd
sudo mount /mnt/external-hdd
mountpoint -q /mnt/external-hdd
```

取り外し前:

```bash
sudo systemctl stop mitsubachi-api
sudo systemctl stop nginx
sync
sudo umount /mnt/external-hdd
```

Nginx が file download 中、Rails が upload 中、backup が実行中の取り外しは破損や失敗の原因になります。

## SSH Git access

Ubuntu サーバー上の `deploy` ユーザーには GitHub 読み取り用 SSH key が必要です。private key を Infra リポジトリへ保存してはいけません。deploy script の引数にも渡してはいけません。

推奨権限:

```bash
sudo -u deploy mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
sudo chmod 600 /home/deploy/.ssh/id_ed25519
sudo chmod 644 /home/deploy/.ssh/id_ed25519.pub
sudo chown -R deploy:deploy /home/deploy/.ssh
```

GitHub へ public key または read-only deploy key を登録します。初回接続前に GitHub host key を安全に確認し、`StrictHostKeyChecking=no` を既定にしないでください。SSH agent に依存する場合、systemd や非対話実行では使えないことがあります。

確認:

```bash
sudo -u deploy ssh -T git@github.com
sudo -u deploy git ls-remote git@github.com:ShioPy0101/mitsubachi-ruby.git HEAD
git ls-remote git@github.com:ShioPy0101/mitsubachi-infra.git HEAD
sudo -u deploy git ls-remote git@github.com:ShioPy0101/mitsubachi-front.git HEAD
```

`ssh -T git@github.com` は認証確認用です。成功時でも GitHub が shell access を提供しない旨を返す場合があります。

## 開発端末での確認

```bash
git clone git@github.com:ShioPy0101/mitsubachi-infra.git
cd mitsubachi-infra

bash -n scripts/*.sh scripts/lib/*.sh
shellcheck scripts/*.sh scripts/lib/*.sh
bash test/run_shell_tests.sh
```

## Ubuntu 初期構築

Infra リポジトリ自身の clone 先は固定しません。次のいずれから実行されても、各スクリプトは `BASH_SOURCE` でリポジトリルートを解決します。

```text
/home/deploy/mitsubachi-infra
/home/admin/src/mitsubachi-infra
/opt/src/mitsubachi-infra
```

Ubuntu サーバー:

```bash
git clone git@github.com:ShioPy0101/mitsubachi-infra.git
cd mitsubachi-infra
```

初期構築:

```bash
sudo ./scripts/bootstrap_ubuntu.sh \
  --app-repo git@github.com:ShioPy0101/mitsubachi-ruby.git \
  --install-nginx-config \
  --install-systemd-unit
```

Ruby version は `--ruby-version` で明示できます。未指定かつ `--app-repo` を指定した場合、Rails API の `.ruby-version` を優先します。Bundler version は `Gemfile.lock` の `BUNDLED WITH` を優先します。

PostgreSQL role/database は、無断で削除・再作成しません。明示作成する場合:

```bash
sudo ./scripts/bootstrap_ubuntu.sh \
  --create-db mitsubachi_production \
  --create-db-role mitsubachi
```

password や権限付与は運用方針に合わせて PostgreSQL 側で設定してください。SQL 例:

```sql
CREATE ROLE mitsubachi LOGIN PASSWORD '<strong-password>';
CREATE DATABASE mitsubachi_production OWNER mitsubachi;
```

## LAN 設定

DHCP reservation で Ubuntu サーバーの private IP を固定してください。例では `192.168.1.50` を使います。

```bash
sudo ./scripts/configure_local_network.sh \
  --lan-cidr 192.168.1.0/24 \
  --server-ip 192.168.1.50 \
  --enable-ufw \
  --allow-ssh \
  --install-nginx-config
```

dry-run:

```bash
sudo ./scripts/configure_local_network.sh \
  --lan-cidr 192.168.1.0/24 \
  --server-ip 192.168.1.50 \
  --enable-ufw \
  --allow-ssh \
  --install-nginx-config \
  --dry-run
```

`0.0.0.0/0` は拒否します。TCP 80 は指定 LAN CIDR からのみ許可します。TCP 22 は LAN CIDR または `--ssh-cidr` からのみ許可します。TCP 3001 と 5432 は許可しません。UFW reset は行いません。

## Environment variables

雛形:

```bash
sudo install -o root -g deploy -m 0640 env/rails.env.example /etc/mitsubachi/rails.env
sudoedit /etc/mitsubachi/rails.env
```

主な値:

```text
APP_HOST
  Ubuntu サーバーの固定 private IP。例: 192.168.1.50

FRONTEND_ORIGIN / FRONTEND_URL
  LAN HTTP の同一 origin。例: http://192.168.1.50

FILE_STORAGE_ROOT
  /mnt/external-hdd/mitsubachi/files

SESSION_COOKIE_SECURE
  LAN HTTP 検証では false を指定する。ただし Rails 側がこの環境変数を
  実際に参照しているとは限らない。

DATABASE_URL
  PostgreSQL 接続 URL。password に特殊文字がある場合は URL encode が必要。

RAILS_MASTER_KEY / SECRET_KEY_BASE
  Rails production secret。実値を commit しない。

RESEND_API_KEY / MAIL_FROM
  mail 送信用。未使用なら空でも Rails 側設定に従う。
```

`/etc/mitsubachi/rails.env` の推奨 owner/group/mode は `root:deploy 0640` です。`DATABASE_URL`、`RAILS_MASTER_KEY`、`SECRET_KEY_BASE`、`RESEND_API_KEY` は標準出力やログへ表示しません。

この Infra は Rails code を変更しません。`SESSION_COOKIE_SECURE=false` を Rails が参照していない場合、または production で `secure: true` が固定されている場合、LAN HTTP では Cookie session が送信されず認証できません。これは `mitsubachi-ruby` 側の確認・修正事項です。公開 HTTPS へ移行する時は Secure Cookie を必須へ戻してください。

## Cookie / CSRF

前提:

```text
Rails API base path: /api/v1
CSRF token endpoint: /api/v1/csrf_token
frontend API call: relative /api/v1/...
credentials: "same-origin"
```

初回検証は frontend dev server を別 origin で動かさず、Nginx の同一 origin から行うのが安全です。別 origin にすると CORS、Cookie、CSRF、SameSite の切り分けが複雑になります。

状態変更 API は `/api/v1/csrf_token` で取得した token を `X-CSRF-Token` に入れて呼びます。Devise Cookie session は同一 origin 前提で扱います。

## Deploy

初回 deploy:

```bash
sudo -u deploy ./scripts/deploy_api.sh \
  --repo-url git@github.com:ShioPy0101/mitsubachi-ruby.git \
  --ref main
```

`--repo-url` は省略可能です。既定値は `git@github.com:ShioPy0101/mitsubachi-ruby.git` です。

通常 deploy:

```bash
sudo -u deploy ./scripts/deploy_api.sh --ref main
```

特定 ref:

```bash
sudo -u deploy ./scripts/deploy_api.sh --ref <branch-or-tag-or-sha>
```

処理概要:

```text
1. deploy lock
2. 外付け HDD mount / writable 検査
3. /etc/mitsubachi/rails.env 検査
4. Rails repo clone/fetch
5. ref を commit SHA に固定
6. releases/<UTC timestamp>-<short sha> を作成
7. bundle install
8. shared log/tmp symlink
9. production boot check
10. DB 接続確認
11. rails db:migrate
12. current symlink atomic switch
13. systemd restart
14. ready health check
15. 古い release cleanup
16. deployments.log 追記
```

current 切り替え前の失敗は現行 release に影響しません。current 切り替え後に health check が失敗した場合は直前 release へ symlink を戻し、service restart と health check を再試行します。ただし DB migration の自動 down は行いません。migration は後方互換を保つ設計が必要です。

`deploy` ユーザーから `systemctl restart mitsubachi-api.service` を行うため、必要に応じて限定 sudoers を設定してください。例:

```sudoers
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart mitsubachi-api.service
```

## Rollback

直前 release:

```bash
sudo -u deploy ./scripts/rollback_api.sh
```

release 一覧:

```bash
sudo -u deploy ./scripts/rollback_api.sh --list
```

指定 release:

```bash
sudo -u deploy ./scripts/rollback_api.sh 20260716T000000Z-abcdef123456
```

release 名は basename のみ許可します。`/`、`\`、`..`、空白、NUL、許可外文字を拒否します。rollback は current symlink を切り替えて service restart と health check を行います。DB migration rollback は行いません。

## Nginx

`nginx/mitsubachi-local.conf` は LAN HTTP 専用です。HTTPS 設定、証明書 path、公開 DNS 前提は含みません。

```text
/api/
  -> http://127.0.0.1:3001

/internal/storage/drive_items/
  internal
  alias /mnt/external-hdd/mitsubachi/files/drive_items/

/
  frontend 未配置の暫定 text response
```

Rails 契約:

```text
X-Accel-Redirect: /internal/storage/drive_items/:storage_key
physical path: /mnt/external-hdd/mitsubachi/files/drive_items/:storage_key
```

`alias` の末尾 slash は重要です。`location /internal/storage/drive_items/` と `alias /mnt/external-hdd/mitsubachi/files/drive_items/;` を対応させることで、`:storage_key` が physical path へ正しく連結されます。

`/internal/storage/drive_items/` は `internal;` のため LAN client から直接取得できません。Rails が認証・認可後に `X-Accel-Redirect` を返した場合だけ Nginx が内部転送します。

upload は `client_max_body_size 10G`、大容量 timeout、`proxy_request_buffering off` を設定しています。request body を Nginx 側で過剰に buffering して root filesystem を圧迫しないためです。response buffering は無効化していません。API JSON は小さく、file download は Rails ではなく Nginx internal location が処理するためです。

Range Request は Rails で解析せず Nginx に委譲します。Nginx が static file として internal alias から配信するため、`Range: bytes=...` に対する `206 Partial Content` を期待できます。

## Verification

URL 例:

```text
http://192.168.1.50/
http://192.168.1.50/api/health/live
http://192.168.1.50/api/health/ready
```

verify script:

```bash
sudo ./scripts/verify_installation.sh \
  --server-ip 192.168.1.50 \
  --lan-cidr 192.168.1.0/24 \
  --health-base http://127.0.0.1:3001
```

curl:

```bash
curl -i http://192.168.1.50/
curl -i http://192.168.1.50/api/health/live
curl -i http://192.168.1.50/api/health/ready
curl -i http://192.168.1.50/internal/storage/drive_items/test-key
```

direct internal URI は `403` または `404` を期待します。認証済み download は Rails API の download endpoint から確認してください。`X-Accel-Redirect` 自体は Nginx が消化するため、最終 client へ内部 physical path は露出しません。

Range Request:

```bash
curl -i \
  -H 'Range: bytes=0-1023' \
  -o /tmp/range.part \
  http://192.168.1.50/<authenticated-download-endpoint>
```

期待値:

```text
HTTP/1.1 206 Partial Content
Accept-Ranges: bytes
Content-Range: bytes 0-1023/...
```

logs:

```bash
sudo journalctl -u mitsubachi-api -n 200 --no-pager
sudo tail -n 200 /var/log/nginx/access.log
sudo tail -n 200 /var/log/nginx/error.log
```

## Backup / Restore

PostgreSQL backup:

```bash
./scripts/backup_postgres.sh --retention-days 14
```

出力:

```text
/mnt/external-hdd/mitsubachi/backups/postgres/postgres-<UTC timestamp>.dump
```

storage backup:

```bash
./scripts/backup_storage.sh --retention-days 14
```

出力:

```text
/mnt/external-hdd/mitsubachi/backups/storage/storage-<UTC timestamp>.tar.gz
```

DB と file storage は同じ世代で管理してください。restore 順序は原則として、service 停止、DB restore、storage restore、service 起動、health check です。

PostgreSQL restore 例:

```bash
sudo systemctl stop mitsubachi-api
createdb mitsubachi_restore_check
pg_restore --dbname=mitsubachi_restore_check /mnt/external-hdd/mitsubachi/backups/postgres/postgres-<timestamp>.dump
```

production DB へ restore する場合は、対象 DB を誤って上書きしないよう接続先を必ず確認してください。この README の例では検証用 DB へ restore しています。

storage restore 例:

```bash
sudo systemctl stop mitsubachi-api
sudo -u deploy tar -C /mnt/external-hdd/mitsubachi/files -xzf \
  /mnt/external-hdd/mitsubachi/backups/storage/storage-<timestamp>.tar.gz
sudo systemctl start mitsubachi-api
```

重要: storage backup の source と destination は同じ外付け HDD 上です。これは誤削除や論理破損への補助であり、外付け HDD 自体の故障には耐えません。物理ディスク故障に備えるには、別ディスク、NAS、filesystem snapshot、rsync hard-link backup、または offsite backup へ移行してください。

upload 中の完全な snapshot consistency は保証しません。厳密な同一時点性が必要な場合は、maintenance window、filesystem snapshot、DB と storage の世代 marker などを検討してください。

## Troubleshooting

切り分け順:

1. external HDD mount: `mountpoint -q /mnt/external-hdd`
2. disk free: `df -h /mnt/external-hdd`
3. environment file: `/etc/mitsubachi/rails.env` の存在と `root:deploy 0640`
4. PostgreSQL: `sudo systemctl status postgresql`
5. Rails boot: `sudo -u deploy bash -lc 'cd /var/www/mitsubachi/current && bundle exec rails runner "puts :ok"'`
6. Puma localhost health: `curl -i http://127.0.0.1:3001/api/health/ready`
7. systemd: `sudo journalctl -u mitsubachi-api -n 200 --no-pager`
8. Nginx config: `sudo nginx -t`
9. Nginx proxy: `curl -i http://<server-ip>/api/health/ready`
10. Cookie / CSRF: Secure Cookie、same-origin、`X-CSRF-Token`
11. upload: `client_max_body_size`、timeout、storage write permission
12. X-Accel-Redirect: internal URI と alias 対応
13. Range Request: `curl -H 'Range: bytes=0-1023'`
14. mail job: `RESEND_API_KEY`、`MAIL_FROM`、Rails job/queue 設定

## Security

```text
Rails 3001
  127.0.0.1 bind。LAN へ公開しない。

PostgreSQL 5432
  LAN へ公開しない。

internal URI
  Nginx internal location。client から直接取得不可。

secrets
  commit しない。標準出力へ表示しない。

env file
  /etc/mitsubachi/rails.env root:deploy 0640。

storage
  deploy writable。www-data readable but not writable。

backup
  root:root 0700。dump/archive は 0600。

UFW
  TCP 80 は LAN CIDR のみ。SSH も LAN CIDR または明示 CIDR のみ。
```

## 将来 HTTPS 公開へ移行する時

今回の LAN HTTP 構成に、公開 DNS、Certbot、Cloudflare、Caddy、公開 HTTPS の設定を混ぜないでください。公開 HTTPS へ移行する場合は、別の変更として以下を再設計します。

```text
public DNS
TLS certificate
HTTPS reverse proxy
Secure Cookie true
HSTS
public firewall policy
backup offsite policy
frontend production deploy
```

HTTPS では `SESSION_COOKIE_SECURE=true` 相当を必須に戻します。LAN HTTP のための妥協を公開環境へ持ち込まないでください。
