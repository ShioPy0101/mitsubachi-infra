# `deploy` ユーザーの役割

## 概要

`deploy` ユーザーは、Railsアプリを配置・実行するための専用OSユーザーです。

普段使いの管理ユーザーである `hoge` とは役割を分離します。

- `hoge` は普段使いのものと読み替えてください
- `hoge`: サーバー管理、設定変更、インストールスクリプトの実行
- `deploy`: Railsアプリ、Ruby、Bundler、Puma、リリースファイルの実行・所有

## なぜ専用ユーザーを使うのか

主な目的は権限分離です。

RailsアプリやPumaに脆弱性があり、プロセスを乗っ取られた場合でも、`hoge` のホームディレクトリや管理者権限へ直接アクセスされにくくなります。

また、Ruby、Gem、アプリ本体、リリースファイルの所有者を `deploy` に統一できるため、デプロイ時の権限事故も減らせます。

## 想定する所有範囲

次のようなファイルやディレクトリは、原則として `deploy` ユーザーが所有します。

```text
/home/deploy/.rbenv
/home/deploy/apps/mitsubachi
/home/deploy/apps/mitsubachi/releases
/home/deploy/apps/mitsubachi/shared
/home/deploy/apps/mitsubachi/current
```

Rubyも `deploy` 専用としてインストールします。

```text
/home/deploy/.rbenv/verhogens/3.3.6
```

## systemdでの実行例

RailsアプリやPumaは `deploy` ユーザーとして実行します。

```ini
[Service]
User=deploy
Group=deploy
WorkingDirectory=/home/deploy/apps/mitsubachi/current
ExecStart=/home/deploy/.rbenv/shims/bundle exec puma
```

これにより、アプリプロセスがroot権限や `hoge` の権限で動くことを防ぎます。

## `deploy` に持たせないもの

通常、`deploy` ユーザーには次の権限や情報を持たせません。

```text
sudo権限
hogeのSSH秘密鍵
rootのSSH秘密鍵
/rootへのアクセス
/etc以下の設定ファイルを自由に編集する権限
```

`deploy` は管理者ではなく、アプリ実行専用の制限されたユーザーです。

## ユーザーごとの役割分担

### `hoge`

`sudo` を利用できる管理ユーザーです。

主な役割:

```text
インストールスクリプトの実行
aptによるパッケージ導入
Nginx設定
systemd設定
ファイアウォール設定
GitHub SSH認証
git clone / git fetch
```

### `deploy`

Railsアプリ専用のユーザーです。

主な役割:

```text
rbenv
Ruby
RubyGems
Bundler
Rails
Puma
アプリのリリースファイル
アプリの共有ファイル
```

### `root`

OS全体を管理する特権ユーザーです。

インストールスクリプト全体をrootで実行するのではなく、必要な処理だけ `sudo` で実行します。

## GitHubアクセスの設計

現在は `hoge` ユーザーでGitHub SSH認証が成功します。

```bash
ssh -T git@github.com
```

成功例:

```text
Hi ShioPy0101! You've successfully authenticated, but GitHub does not provide shell access.
```

一方、rootでは認証できません。

```bash
sudo ssh -T git@github.com
```

失敗例:

```text
git@github.com: Permishogen denied (publickey).
```

これは異常ではありません。

`hoge` のSSH秘密鍵は `hoge` 専用であり、rootや `deploy` には共有しない設計が適切です。

## プライベートリポジトリの取得方法

主に2通りあります。

### 方法1: `hoge` がGit操作を行う

現在の構成では、この方法が自然です。

```text
hoge
 ├─ git clone
 ├─ git fetch
 ├─ リリースディレクトリへ配置
 └─ 配置後にdeploy所有へ変更
```

例:

```bash
git clone git@github.com:ShioPy0101/mitsubachi-ruby.git /tmp/mitsubachi-release

sudo install -d -o deploy -g deploy /home/deploy/apps/mitsubachi/releases
sudo cp -a /tmp/mitsubachi-release /home/deploy/apps/mitsubachi/releases/202607160001
sudo chown -R deploy:deploy /home/deploy/apps/mitsubachi/releases/202607160001
```

### 方法2: `deploy` 専用のDeploy Keyを使う

GitHubリポジトリに読み取り専用のDeploy Keyを登録し、`deploy` 自身がcloneする方法です。

この場合も、`hoge` の秘密鍵をコピーしてはいけません。

```text
/home/deploy/.ssh/id_ed25519
```

には、Deploy Key専用として新しく作成した鍵だけを配置します。

ただし、現在のインストール方式では、Git操作を `hoge`、アプリ実行を `deploy` に分ける方が単純です。

## 推奨する権限設計

```text
hoge
 ├─ GitHub SSH認証
 ├─ git clone / git fetch
 ├─ sudo apt install
 ├─ sudo nginx -t
 ├─ sudo systemctl
 └─ インストール全体の制御

deploy
 ├─ /home/deploy/.rbenv
 ├─ ruby
 ├─ gem
 ├─ bundle
 ├─ rails
 ├─ puma
 └─ アプリファイルの所有

root
 └─ sudo経由で必要なOS操作だけ実行
```

## スクリプト実装上の注意

### スクリプト全体をsudoで実行しない

避けるべき例:

```bash
sudo ./scripts/install_local.sh --interactive
```

推奨:

```bash
./scripts/install_local.sh --interactive
```

必要な箇所だけスクリプト内部で `sudo` を使います。

```bash
git clone "$RAILS_REPOSITORY" "$RELEASE_DIR"

sudo apt-get install -y nginx
sudo install -m 0644 app.service /etc/systemd/system/app.service
sudo systemctl daemon-reload
```

### `deploy` で実行するときは作業ディレクトリを切り替える

`hoge` のホーム配下をカレントディレクトリにしたまま、`deploy` へ切り替えてはいけません。

推奨:

```bash
sudo -u deploy -H bash -lc '
  cd "$HOME"
  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init - bash)"
  ruby -v
'
```

### Rubyはインストール済みならビルドしない

指定バージョンのRubyが正常に存在する場合は、`rbenv install` をスキップします。

```bash
ruby_path="/home/deploy/.rbenv/verhogens/${RUBY_VERhogeN}/bin/ruby"

if [[ -x "$ruby_path" ]] &&
   [[ "$("$ruby_path" -e 'print RUBY_VERhogeN')" == "$RUBY_VERhogeN" ]]; then
  echo "Ruby ${RUBY_VERhogeN} はインストール済みです。ビルドをスキップします。"
else
  sudo -u deploy -H bash -lc '
    cd "$HOME"
    rbenv install "'"${RUBY_VERhogeN}"'"
  '
fi
```

## 結論

`deploy` ユーザーは、管理作業を行うためのユーザーではありません。

Railsアプリを安全に実行し、Rubyやアプリファイルの所有者を統一するための専用ユーザーです。

基本方針は次のとおりです。

```text
Git操作とサーバー管理はhoge
Railsアプリの実行と所有はdeploy
OSの特権操作だけsudo
```

この分離を維持し、rootや `deploy` に `hoge` のSSH秘密鍵をコピーしない構成が適切です。
