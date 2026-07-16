# mitsubachi-infra

`mitsubachi-infra` は、Mitsubachi の本番 Ubuntu 上で Rails API、Solid Queue worker、React/Vite frontend、Nginx、Certbot、systemd、UFW、release/rollback を管理する Infra リポジトリです。

現行の本番運用は、利用者が本番 Ubuntu へ SSH 接続した後、その本番 Ubuntu 上で Ruby CLI を実行する方式です。`mitsubachi-infra` が開発 Ubuntu から本番 Ubuntu へ SSH 接続する実装は採用しません。

```text
開発 Ubuntu
  commit / push
    ↓
利用者が本番 Ubuntu へ SSH 接続
    ↓
本番 Ubuntu 上で ruby exe/mitsubachi-infra deploy
    ↓
backend / frontend を Git から取得して release deploy
```

公開ドメイン:

```text
Frontend: https://mitsubachi.shiosalt.com
Rails API: https://mitsubachi-api.shiosalt.com
```

Nginx が 80/443 を受け、frontend は `/var/www/mitsubachi-frontend/current/dist` から静的配信し、Rails API は `127.0.0.1:3000` の Puma へ reverse proxy します。Minecraft で使用する TCP `25565` / `25566` は UFW 設定で維持し、用途を変更しません。

詳細:

```text
docs/commands.md
docs/production-deployment.md
docs/environment-variables.md
docs/mail-delivery.md
docs/troubleshooting.md
```

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
  Nginx / Certbot
  systemd
  UFW
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

Frontend は Ruby CLI の production deploy で `git@github.com:ShioPy0101/mitsubachi-front.git` から取得し、Nginx で静的配信します。

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
  -> Nginx :80/:443
  -> Rails / Puma 127.0.0.1:3000
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

Rails/Puma の `127.0.0.1:3000` と PostgreSQL の `5432` は LAN に公開しません。LAN client から見える入口は Nginx の `:80/:443` だけです。

## Ruby CLI

通常運用の入口は Ruby 製 CLI の `mitsubachi-infra` です。Infra CLI は Rails アプリケーションの `Gemfile` や release directory に依存せず、system Ruby と Ruby 標準ライブラリだけで起動します。Rails 用 Ruby/rbenv が壊れていても、状態確認や復旧操作を始められることを優先します。

```bash
sudo mitsubachi-infra install --interactive
sudo mitsubachi-infra install --dry-run
sudo mitsubachi-infra install --interactive --remove-nginx-default-site
sudo mitsubachi-infra deploy
sudo mitsubachi-infra deploy backend --ref main
sudo mitsubachi-infra deploy frontend --ref main
sudo mitsubachi-infra rollback backend
sudo mitsubachi-infra rollback frontend
sudo mitsubachi-infra status
sudo mitsubachi-infra status --json
sudo mitsubachi-infra https check
sudo mitsubachi-infra https enable --staging
sudo mitsubachi-infra https enable
sudo mitsubachi-infra https renew
sudo mitsubachi-infra https status
```

`--dry-run` は `install`、`deploy`、`rollback`、`https enable` などで利用できます。dry-run でも secret は表示しません。

`install`、`bootstrap`、`configure`、`deploy`、`rollback`、`https enable`、`https renew` は system 領域や service を変更するため root で実行します。非rootで実行した場合は lock 取得前に `error: install must be run as root` のようなCLIエラーで停止します。`help` と `status` はroot必須ではありません。

初回 install は root 権限で OS パッケージ、deploy ユーザー、Node.js、rbenv/Ruby、Nginx、Certbot、systemd unit を整えます。アプリケーションの Git clone、Bundler、Rails task、npm、frontend build は deploy ユーザーで実行します。秘密鍵はリポジトリへ入れず、`/home/deploy/.ssh` に手動配置してください。`known_hosts` は GitHub の SSH host key を非対話で確認できるよう install 時に準備します。

CLI 自身は `bin/mitsubachi-infra` 単体ではなく、実行に必要な `bin/` と `lib/` を `/opt/mitsubachi-infra/releases/<timestamp>/` へ配置し、`/opt/mitsubachi-infra/current` と `/usr/local/bin/mitsubachi-infra` を symlink で切り替えます。再install時も新しいreleaseを作ってからsymlinkを切り替えるため、途中失敗で壊れた `/usr/local/bin/mitsubachi-infra` を残しません。

Node.js は `runtime.node_major` を要求majorとして扱い、既存 `node --version` が要求以上なら再導入しません。不足している場合は NodeSource apt repository から Node.js を導入し、最後に `node --version` と `npm --version` を確認します。Ubuntu標準aptの古い `nodejs/npm` を frontend production build 用の正常状態とは扱いません。

Nginx の `default_server` は IPv4 `:80` と IPv6 `[::]:80` それぞれで 1 つだけ設定できます。Mitsubachi の Nginx テンプレートは通常 `default_server` を付けません。既存 Nginx を使っている環境では、他サービスの default server を維持したまま frontend/API の `server_name` だけを追加します。

Ubuntu 標準の `/etc/nginx/sites-enabled/default` を Mitsubachi 用に無効化したい場合だけ、`--remove-nginx-default-site` または `nginx.remove_default_site: true` を使います。この処理は `/etc/nginx/sites-enabled/default` が symlink の場合にその symlink だけを外します。`/etc/nginx/sites-available/default` の原本や他サービスの Nginx 設定は削除しません。対象が存在しない場合は成功扱いです。

install は変更前に `/etc/nginx/nginx.conf`、`/etc/nginx/conf.d/*`、`/etc/nginx/sites-enabled/*` を調べ、`default_server` の所在、既存 `mitsubachi.conf`、`sites-enabled/default`、初期 `nginx -t` の状態をログへ出します。初期状態で `nginx -t` が失敗している場合は、Mitsubachi の変更を開始せず「既存 Nginx 設定が壊れている」として停止します。

設定更新はバックアップ、`nginx -t`、reload、失敗時復元の順で行い、HTTPS 化に失敗した場合も HTTP challenge 設定を維持します。rollback 後にも `nginx -t` を実行し、rollback が失敗した場合は元のエラーと復元操作の内容を両方表示します。

公開時の段階:

```text
1. HTTP only 設定を生成し、ACME challenge を公開する
2. nginx -t に成功した場合だけ Nginx を reload する
3. Certbot で frontend/API それぞれの証明書を取得または既存証明書を再利用する
4. 証明書ファイル確認後に HTTPS 設定を生成する
5. nginx -t に成功した場合だけ reload する
```

運用確認:

```bash
sudo nginx -t
sudo systemctl status nginx
sudo systemctl status mitsubachi-api
sudo systemctl status mitsubachi-worker
sudo journalctl -u mitsubachi-api -n 200 --no-pager
sudo journalctl -u mitsubachi-worker -n 200 --no-pager
sudo certbot certificates
sudo ufw status verbose
sudo -u deploy ssh -T git@github.com
sudo -u deploy env HOME=/home/deploy RBENV_ROOT=/home/deploy/.rbenv PATH=/home/deploy/.rbenv/bin:/home/deploy/.rbenv/shims:/usr/local/bin:/usr/bin:/bin bash -lc 'cd /var/www/mitsubachi/current && bundle exec rails runner "puts :ok"'
```

install 完了確認では `systemctl restart` 直後に固定 sleep せず、内部Puma endpoint `http://127.0.0.1:<rails_port>/api/health/ready` を最大30回、1秒間隔で確認します。public mode の Host は API domain、LAN mode の Host は明示された `server_ip` です。上限まで失敗した場合は `systemctl status mitsubachi-api.service`、`journalctl -u mitsubachi-api.service -n 100`、`ss -ltnp` を表示します。worker は active 判定に失敗した場合に同様に status と journal を表示します。

Nginx 手動復旧:

```bash
sudo nginx -t
sudo ls -l /etc/nginx/sites-enabled
sudo grep -R \"listen .*default_server\" /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled
sudo cp -a /etc/nginx/sites-available/mitsubachi.conf.backup.YYYYmmddTHHMMSSZ /etc/nginx/sites-available/mitsubachi.conf
sudo ln -sfn /etc/nginx/sites-available/mitsubachi.conf /etc/nginx/sites-enabled/mitsubachi.conf
sudo nginx -t
sudo systemctl reload nginx
```

`/etc/nginx/sites-enabled/default` を戻す必要がある場合は、原本が残っていることを確認して symlink だけを再作成します。

```bash
sudo ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```

環境変数は `/etc/mitsubachi/rails.env` と `/etc/mitsubachi/frontend.env` に分離します。`frontend.env` の `VITE_API_BASE_URL` は build 時に成果物へ埋め込まれるため、秘密情報を置いてはいけません。本番値は `https://mitsubachi-api.shiosalt.com` です。

rollback:

```bash
sudo mitsubachi-infra rollback backend
sudo mitsubachi-infra rollback frontend
```

backend rollback は DB migration を戻しません。破壊的 migration の前には database backup を取得してください。

Shell に残している主な処理は `scripts/install_local.sh` の最小 bootstrap だけです。これは root 権限確認、`ruby-full` / `git` / `sudo` の導入、`bin/mitsubachi-infra install` の起動だけを担当します。既存の `deploy_api.sh` などは互換・移行用として残していますが、新しい通常運用は Ruby CLI 側へ移します。

CLI の主な責務:

```text
lib/mitsubachi_infra/command_runner.rb
  OS command 実行、dry-run、secret masking、deploy ユーザー実行。

lib/mitsubachi_infra/configuration.rb
  /etc/mitsubachi/config.yml の読み込みと検証。

lib/mitsubachi_infra/deployment/
  backend/frontend release deploy と rollback。

lib/mitsubachi_infra/nginx.rb
  Nginx 設定の生成、安全な適用、validation、reload、失敗時復元。

lib/mitsubachi_infra/certbot.rb
  HTTP-01 証明書取得、既存証明書再利用、renew 後の Nginx 検証。

lib/mitsubachi_infra/production.rb
  本番 Ubuntu 上での bootstrap、backend/frontend deploy、rollback、production-check、mail-test。
```

設定 schema 例は `env/config.yml.example` を参照してください。非秘密の infra 設定は `/etc/mitsubachi/config.yml` に保存します。Rails secret と DB password を含む値は `/etc/mitsubachi/rails.env` に分離します。frontend env には DB password、Rails master key、secret key base、署名鍵、証明書秘密鍵、ACME credential を置かないでください。

## 正式なディレクトリ設計

この節のパスを正式な設計として採用します。README、シェルスクリプト、Nginx 設定、systemd unit、環境変数雛形、テストはこの構成に揃えています。

```text
Backend:
  /var/www/mitsubachi/repo
  /var/www/mitsubachi/releases
  /var/www/mitsubachi/current -> releases/<release-name>
  /var/www/mitsubachi/shared

Frontend:
  /var/www/mitsubachi-frontend/repo
  /var/www/mitsubachi-frontend/releases
  /var/www/mitsubachi-frontend/current -> releases/<release-name>
```

各ディレクトリの責務:

```text
/var/www/mitsubachi/repo
  mitsubachi-ruby の Git リポジトリキャッシュ。
  deploy_api.sh が clone または fetch に使用する。
  実行中アプリケーションの作業ツリーとして直接使用しない。

/var/www/mitsubachi/releases
  commit SHA から作成した release を保存する。
  各 release は独立したディレクトリとする。

/var/www/mitsubachi/current
  現在稼働中の release を指す symlink。
  releases/<release-name> へ atomic に切り替える。

/var/www/mitsubachi/shared/log
  release 間で共有する Rails log 領域。

/var/www/mitsubachi/shared/tmp
  release 間で共有する Rails 通常 tmp 領域。
  外付け HDD 上の bulk download 用一時 ZIP 領域とは別物。

/var/www/mitsubachi/shared/deployments.log
  deploy / rollback の履歴を記録する。
  commit SHA、release 名、実行日時、結果を記録する。
  秘密情報は記録しない。
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

各ディレクトリの責務:

```text
/mnt/external-hdd/mitsubachi/files
  Rails の FILE_STORAGE_ROOT。

/mnt/external-hdd/mitsubachi/files/drive_items
  DriveItem の物理ファイル保存先。
  実ファイルは storage_key をファイル名として保存する。

/mnt/external-hdd/mitsubachi/tmp/bulk_downloads
  一括 download 用 ZIP の一時作成先。
  Rails の通常 tmp 領域とは分離する。

/mnt/external-hdd/mitsubachi/backups/postgres
  pg_dump による PostgreSQL backup 成果物の保存先。

/mnt/external-hdd/mitsubachi/backups/storage
  file storage backup 成果物の保存先。
```

使用禁止パス:

```text
/srv/mitsubachi
/srv/mitsubachi/files
/srv/mitsubachi/tmp
/srv/mitsubachi/backups
/var/www/mitsubachi-ruby
```

これらは過去設計や別案としても使いません。PostgreSQL のデータディレクトリ本体は Ubuntu 標準構成の内蔵ディスク上に維持し、backup 成果物だけを外付け HDD に保存します。PostgreSQL cluster を `/mnt/external-hdd` 上へ作成したり、PostgreSQL 本体の起動を外付け HDD 上の data directory へ依存させたりしません。

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

systemd unit の起動前検査:

```text
/mnt/external-hdd が mount point である
/mnt/external-hdd/mitsubachi/files が書き込み可能である
/mnt/external-hdd/mitsubachi/files/drive_items が存在する
deploy ユーザーが files / drive_items へ書き込める
mktemp により filesystem が read-only ではないことを確認する
```

`www-data` の読み取り可否と書き込み不可は `verify_installation.sh` で確認します。systemd service は `User=deploy` で実行されるため、Nginx worker user の権限確認は破壊的変更をしない verify 側へ分離しています。

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
shellcheck scripts/*.sh scripts/lib/*.sh test/run_shell_tests.sh
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

### 対話セットアップ

`install --interactive` は `/etc/mitsubachi/config.yml` を読み込んだ後、不足している必須値だけを質問します。既存値がある項目は質問せず、最後に secret を含まない summary を表示して続行確認を行います。EOFの場合は停止し、非対話実行へ自動フォールバックしません。

```bash
sudo mitsubachi-infra install --interactive
```

質問対象は mode、LAN mode の `server_ip`、public mode の frontend/API domain と Certbot email、Rails port、Ruby version、Node major version、backend/frontend repository、backend/frontend ref です。Rails secret、DATABASE URL、API key は対話入力しません。

設定値の優先順位:

```text
1. CLI の --config で指定した YAML
2. /etc/mitsubachi/config.yml
3. コード上の安全な非環境依存デフォルト
```

LAN modeでは `server_ip` が必須です。コード上のデフォルトには例示IPを持たせていないため、未設定なら `apt-get` や Nginx 変更より前に停止します。public modeでは health check の Host に API domain を使います。

`install --interactive` で不足値を入力した場合は `/etc/mitsubachi/config.yml` へ atomic に保存します。既存ファイルは backup し、owner/group/mode は `root:deploy 0640` です。`--dry-run --interactive` ではsummaryと変更予定を確認できますが、設定ファイルは書き込みません。

`scripts/install_local.sh` は root で実行する最小bootstrapです。system Ruby、git、sudoがない環境でそれらを入れてから Ruby CLI の `install` を起動します。

### 設定ファイルを使う方法

```bash
sudo install -d -o root -g deploy -m 0750 /etc/mitsubachi
sudo install -o root -g deploy -m 0640 env/config.yml.example /etc/mitsubachi/config.yml
sudoedit /etc/mitsubachi/config.yml
sudo mitsubachi-infra --config /etc/mitsubachi/config.yml install --dry-run
```

`config/local.env.example` は legacy shell 用の例です。Ruby CLI の正式入力は YAML です。

### 非対話実行

```bash
sudo mitsubachi-infra --config /etc/mitsubachi/config.yml install
```

非対話モードでは必須値不足時に即時失敗し、対話入力へ自動フォールバックしません。

事前確認だけを行う場合:

```bash
sudo mitsubachi-infra --config /etc/mitsubachi/config.yml --dry-run install
```

`--dry-run` は変更予定コマンドを表示し、`/etc/mitsubachi/config.yml`、`/etc/mitsubachi/rails.env`、systemd、Nginx、UFW、deploy を変更しません。secret の値も stdout/stderr へ出しません。

### Rails env の更新

既存 `/etc/mitsubachi/rails.env` がある場合、`install_local.sh` は既存コメントと未知の key を可能な限り保持し、不足 key だけ追加します。既存 key は明示指定なしに変更しません。

```text
--update-rails-env
  既存の非秘密 key の変更を許可する。

--update-secrets
  既存の secret key の変更を許可する。

--overwrite-rails-env
  既存ファイル全体を置換する。置換前に timestamp 付き backup を作る。
```

`SECRET_KEY_BASE` が未設定の場合、対話モードでは次を選べます。

```text
1. openssl rand -hex 64 で自動生成する
2. 手入力する
3. Rails credentials に任せて省略する
```

`RAILS_MASTER_KEY` は既存 Rails credentials の復号に必要なため、Infra 側で勝手に生成しません。

secret 保護方針:

```text
config/local.env
  非秘密情報だけ。secret は保存しない。

/etc/mitsubachi/rails.env
  secret の正式保存先。root:deploy 0640。

stdout / stderr / deployments.log / journalctl
  secret の値そのものを出さない。

temporary file
  secret を含む場合は mode 0600。処理後に削除する。
```

初期構築:

```bash
sudo ./scripts/bootstrap_ubuntu.sh \
  --app-repo git@github.com:ShioPy0101/mitsubachi-ruby.git \
  --install-nginx-config \
  --install-systemd-unit
```

Ruby version は `--ruby-version` で明示できます。未指定かつ `--app-repo` を指定した場合、Rails API の `.ruby-version` を優先します。Bundler version は `Gemfile.lock` の `BUNDLED WITH` を優先します。

Ruby CLI の `install` は PostgreSQL package と service 前提の準備までを担当し、role/database 作成は自動実行しません。Rails production は primary / cache / queue / cable の 4 DB を使います。role は 4 DB すべてで `mitsubachi` に統一し、host は Unix socket ではなく `127.0.0.1` を明示します。

DB初期化は現時点では legacy bootstrap の明示オプション、または手動SQLで実施します。`install` 完了summaryでもDB未初期化であることを表示します。

```bash
sudo ./scripts/bootstrap_ubuntu.sh \
  --create-db mitsubachi_production \
  --create-db-role mitsubachi
```

作成対象:

```text
mitsubachi_production
mitsubachi_production_cache
mitsubachi_production_queue
mitsubachi_production_cable
```

初回作成時だけ `DATABASE_URL` の password で role を作成します。既存 role の password は無条件変更しません。既存 DB の owner が `mitsubachi` 以外なら停止します。

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

`0.0.0.0/0` は拒否します。TCP 80 は指定 LAN CIDR からのみ許可します。TCP 22 は LAN CIDR または `--ssh-cidr` からのみ許可します。TCP 3000 と 5432 は許可しません。UFW reset は行いません。

## Public HTTPS

public mode は Nginx + Certbot で HTTPS を実装します。Certbot が Let's Encrypt 証明書の取得・更新を担当し、Nginx が取得済み証明書を使って TLS 終端、frontend 静的配信、Rails API への reverse proxy、HTTP から HTTPS への redirect、ACME HTTP-01 challenge の公開を担当します。

`/etc/mitsubachi/config.yml` では frontend と Rails API を別 host として設定します。`staging` は永続設定へ保存せず、`https enable --staging` の CLI オプションだけで指定します。旧 `https.host` は拒否されます。

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

証明書は host ごとに個別取得します。

```text
/etc/letsencrypt/live/mitsubachi.shiosalt.com/fullchain.pem
/etc/letsencrypt/live/mitsubachi.shiosalt.com/privkey.pem
/etc/letsencrypt/live/mitsubachi-api.shiosalt.com/fullchain.pem
/etc/letsencrypt/live/mitsubachi-api.shiosalt.com/privkey.pem
```

先に DNS と port forwarding を確認してください。

```bash
sudo mitsubachi-infra https check
sudo mitsubachi-infra https enable --staging
sudo mitsubachi-infra https enable
sudo mitsubachi-infra https renew
sudo mitsubachi-infra https status
```

通常の `https enable` は production の Let's Encrypt endpoint を使います。`--staging` が明示された場合だけ staging endpoint を使い、staging 証明書は production 証明書として再利用しません。HTTPS 設定は `nginx -t` 成功後にだけ reload します。DNS が本番 Ubuntu を指していない場合、Certbot の ACME 証明書取得は失敗します。

router / DNS:

```text
TCP 80
  ACME HTTP-01 challenge と HTTP -> HTTPS redirect に必要。

TCP 443
  public HTTPS に必要。

A / AAAA record
  mitsubachi.shiosalt.com と mitsubachi-api.shiosalt.com を本番サーバーの public IP へ向ける。

CGNAT
  ISP の CGNAT 配下では通常の port forwarding が使えない可能性がある。
```

UFW では 80/443 を開けても、SSH は無条件に全世界へ公開しないでください。LAN CIDR、管理元 CIDR、VPN、Tailscale 等の明示範囲に限定してください。PostgreSQL、Puma、Node.js development server は外部公開しません。

Cloudflare:

```text
DNS only
  初期推奨。Let's Encrypt HTTP-01 を origin で直接処理するため、router で TCP 80/443 forwarding が必要。

Cloudflare Proxy
  将来対応。origin HTTPS、real IP 設定、upload size、timeout、大容量 upload/download、Range Request への影響を確認する。初期推奨ではない。

Cloudflare Tunnel
  今回の必須対象外。
```

## Environment variables

雛形:

```bash
sudo install -o root -g deploy -m 0640 env/rails.env.example /etc/mitsubachi/rails.env
sudoedit /etc/mitsubachi/rails.env
```

主な値:

```text
APP_HOST
  単一の Rails application host。public mode は mitsubachi-api.shiosalt.com、
  LAN mode は Ubuntu サーバーの固定 private IP。例: 192.168.1.50

ALLOWED_HOSTS
  Rails Host Authorization 用のカンマ区切り allowlist。
  public mode: mitsubachi-api.shiosalt.com,127.0.0.1,localhost
  LAN mode: <server-private-ip>,127.0.0.1,localhost

FRONTEND_ORIGIN / FRONTEND_URL
  public mode は https://mitsubachi.shiosalt.com。
  LAN mode は LAN HTTP の同一 origin。例: http://192.168.1.50

FILE_STORAGE_ROOT
  /mnt/external-hdd/mitsubachi/files

BULK_DOWNLOAD_TMP
  /mnt/external-hdd/mitsubachi/tmp/bulk_downloads
  Rails の通常 tmp とは分離した一括 download ZIP 作成先。

SESSION_COOKIE_SECURE
  LAN HTTP 検証では false を指定する。ただし Rails 側がこの環境変数を
  実際に参照しているとは限らない。

WEB_CONCURRENCY
  既定は 0。Puma を single mode で起動し、worker 数 1 の cluster mode
  警告を避ける。複数 worker を使う場合だけ 2 以上を明示する。
  Rails 側の Puma 設定が WEB_CONCURRENCY を参照していない場合は
  mitsubachi-ruby 側の修正が必要。

DATABASE_URL / DATABASE_CACHE_URL / DATABASE_QUEUE_URL / DATABASE_CABLE_URL
  Rails production 複数 DB 用の PostgreSQL 接続 URL。4 つすべて必須。
  DB 名は順に mitsubachi_production、mitsubachi_production_cache、
  mitsubachi_production_queue、mitsubachi_production_cable。
  role は mitsubachi、host は 127.0.0.1、port は 5432 に統一する。
  password に特殊文字がある場合は URL encode が必要。

RAILS_MASTER_KEY / SECRET_KEY_BASE
  Rails production secret。実値を commit しない。

RESEND_API_KEY / MAIL_FROM
  mail 送信用。未使用なら空でも Rails 側設定に従う。
```

`/etc/mitsubachi/rails.env` の推奨 owner/group/mode は `root:deploy 0640` です。4 つの `DATABASE*_URL`、`RAILS_MASTER_KEY`、`SECRET_KEY_BASE`、`RESEND_API_KEY` は標準出力やログへ表示しません。単一 `DATABASE_URL` だけの旧構成は Rails production 起動前に停止します。

この Infra は Rails code を変更しません。`SESSION_COOKIE_SECURE=false` を Rails が参照していない場合、または production で `secure: true` が固定されている場合、LAN HTTP では Cookie session が送信されず認証できません。これは `mitsubachi-ruby` 側の確認・修正事項です。公開 HTTPS へ移行する時は Secure Cookie を必須へ戻してください。

Rails 側が `ALLOWED_HOSTS` を参照していない場合は、`mitsubachi-ruby` 側で `config.hosts` に `ENV["ALLOWED_HOSTS"].split(",")` を追加する必要があります。`config.hosts.clear` は使いません。確認例:

```bash
sudo -u deploy -H env \
  HOME=/home/deploy \
  RBENV_ROOT=/home/deploy/.rbenv \
  PATH=/home/deploy/.rbenv/bin:/home/deploy/.rbenv/shims:/usr/local/bin:/usr/bin:/bin \
  bash -lc '
    set -a
    source /etc/mitsubachi/rails.env
    set +a
    cd /var/www/mitsubachi/current
    bundle exec rails runner "
      puts ENV[\"APP_HOST\"].inspect
      puts ENV[\"ALLOWED_HOSTS\"].inspect
      pp Rails.application.config.hosts
    "
  '
```

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
7. commit SHA を release directory へ checkout
8. bundle install
9. shared log/tmp symlink
10. production boot check
11. DB 接続確認
12. rails db:migrate
13. current symlink atomic switch
14. systemd restart
15. ready health check
16. 古い release cleanup
17. deployments.log 追記
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
  -> http://127.0.0.1:3000

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
  --health-base http://127.0.0.1:3000 \
  --health-host 192.168.1.50
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

storage backup の対象は `/mnt/external-hdd/mitsubachi/files` のみに限定します。`/mnt/external-hdd/mitsubachi` 全体を対象にすると、`backups` ディレクトリを再帰的に archive へ含める危険があります。

upload 中の完全な snapshot consistency は保証しません。厳密な同一時点性が必要な場合は、maintenance window、filesystem snapshot、DB と storage の世代 marker などを検討してください。

## Troubleshooting

切り分け順:

1. external HDD mount: `mountpoint -q /mnt/external-hdd`
2. disk free: `df -h /mnt/external-hdd`
3. environment file: `/etc/mitsubachi/rails.env` の存在と `root:deploy 0640`
4. PostgreSQL: `sudo systemctl status postgresql`
5. Rails boot: `sudo -u deploy env HOME=/home/deploy RBENV_ROOT=/home/deploy/.rbenv PATH=/home/deploy/.rbenv/bin:/home/deploy/.rbenv/shims:/usr/local/bin:/usr/bin:/bin bash -lc 'cd /var/www/mitsubachi/current && bundle exec rails runner "puts :ok"'`
6. Puma localhost health: `curl -i -H 'Host: <server-ip>' http://127.0.0.1:3000/api/health/ready`
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
Rails 3000
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

正式な公開 HTTPS 構成は Nginx + Certbot です。Caddy は将来案または別ブランチの設計として扱い、Nginx と Caddy を同時に 80/443 へ bind しません。

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
