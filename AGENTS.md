## 開発環境とリリース環境

このリポジトリの開発環境と、本番リリース先のUbuntuサーバーは別のマシンです。

### 開発用Ubuntu

- ソースコードの編集、テスト、コミット、pushを行う環境
- Codexによる実装作業は原則としてこの環境で行う
- `/etc/nginx`、`/etc/systemd/system`、`/var/www` など、リリース用Ubuntu上の実ファイルが存在するとは限らない
- 開発環境上のOS設定を直接変更しても、本番環境には反映されない

### リリース用Ubuntu

- Mitsubachiの本番サービスを稼働させる環境
- Nginx、systemd、Rails、フロントエンド、PostgreSQL、外部ストレージなどが配置されている
- 開発用Ubuntuとはファイルシステム、ユーザー、サービス状態、インストール済みパッケージが異なる
- 本番環境へのSSH接続やコマンド実行は、原則として利用者が手動で行う

## ソースコードの反映方法

開発用Ubuntuとリリース用Ubuntuのソースコードは、共有ディレクトリや直接同期ではなくGitで管理する。

基本的な反映フローは次のとおり。

```text
開発用Ubuntuで変更
→ テスト・Lint
→ Git commit
→ リモートリポジトリへpush
→ リリース用Ubuntuでgit pullまたはデプロイ処理
→ 設定生成・配置
→ サービスのreloadまたはrestart
```

Codexは、開発用Ubuntuでファイルを変更しただけでリリース用Ubuntuへ反映されたと判断してはならない。

また、リリース用Ubuntu上のファイルを直接編集することを通常の反映手段として提案しないこと。恒久的な変更は、原則としてこのリポジトリのコード、テンプレート、設定ファイル、またはデプロイ処理へ実装する。

## Git作業ブランチの扱い

Codexは、commitを作成する前に必ず現在のbranchとremote追跡状態を確認すること。

```bash
git status --short --branch
git branch --show-current
```

実装は最後にまとめてcommitせず、調査後にcommit分割を先に決め、実装と並行して小さくcommitすること。Nginx設定、運用スクリプト、ドキュメント、テストなど独立してレビューできる責務は別commitにする。目安として、1commitが5ファイルまたは差分300行を超えそうなら、不可分である理由がない限りさらに分割すること。新しい責務へ進む前に直前の責務をテストしてcommitし、単一の巨大なfeature commitを作らないこと。

各commitは、原則として次を満たすこと。

- 目的が1つで、commit messageだけで責務が分かる
- 対応するテストまたは検証を同じcommitへ含める
- 可能な限り単独でbuild・test可能である
- 後続commitを読まなくてもレビューできる
- リポジトリ横断作業でも、各リポジトリ内をさらに責務別に分割する

`main` 上で作業している場合、利用者から明示的に許可されていない限り、直接commitしてはならない。先に用途が分かる作業branchを作成して切り替えること。

```bash
git switch -c feat/<topic>
```

一度pushしたcommit、または利用者が取り込んだ可能性があるcommitは、利用者から明示的に依頼されていない限り書き換えないこと。`git commit --amend`、interactive rebase、通常rebase、force pushは避け、修正は追加commitとして積む。

誤って `main` にcommitした場合は、pushする前に次の順序で修正すること。

```text
1. 現在のHEADを作業branchへ退避する
2. 退避branchにcommitが残っていることを確認する
3. mainをorigin/mainへ戻す
4. 作業branchへ戻って作業を続ける
```

この修正では、commitを失わないことを最優先する。`git reset --hard` を使う場合は、対象commitが別branchに退避済みであることを確認してから実行する。

## 実装完了時のGitHub反映

利用者からリポジトリ内の実装を依頼された場合、明示的に禁止されていない限り、Codexは実装とテストだけで止めず、次まで行うこと。

```text
1. 用途が分かる作業branchを作成する
2. 変更対象だけをstageする
3. テスト結果を確認する
4. commitを作成する
5. remoteへpushする
6. GitHubにdraft PRを作成する
```

GitHub認証や権限不足でpushまたはPR作成だけができない場合も、可能なbranch作成、テスト、commitまでは先に完了し、できなかった工程と利用者が必要な対応を明示すること。

## テストの記載言語

Codexが新規追加または更新するテストケースの名称・説明は、原則として日本語で記載すること。テスト実行結果とPR本文のテスト欄も日本語で記載し、成功件数、失敗件数、未実行または環境起因の制約を区別して報告すること。

障害調査のためにリリース用Ubuntu上のファイルを一時的に編集する場合は、以下を明示すること。

- 一時的な調査変更であること
- Git管理された実装へ後から反映する必要があること
- 次回のデプロイや設定適用で上書きされる可能性があること
- 調査終了後に元へ戻す必要があること

## リリース用Ubuntuの状態を前提にしない

Codexは、開発環境から次の状態を推測してはならない。

- 現在リリースされているGitコミット
- 現在のブランチ
- 未コミット変更の有無
- `/etc/nginx/nginx.conf` などの実際の内容
- systemd unitの実際の内容
- 現在有効なNginx設定
- 実行中サービスの状態
- データベースの状態
- 設定ファイルや環境変数の現在値

本番状態の確認が必要な場合は、利用者がリリース用Ubuntuで実行できる確認コマンドを提示すること。

例:

```bash
cd /path/to/repository
git status
git branch --show-current
git rev-parse HEAD
git log -1 --oneline
git remote -v
```

Nginxやsystemdについては、リポジトリ内のテンプレートだけでなく、リリース用Ubuntu上で生成・配置された実設定を確認する手順も提示すること。

```bash
sudo nginx -T
sudo systemctl cat mitsubachi-api.service
sudo systemctl status mitsubachi-api.service --no-pager
```

## git pullに関する注意

リリース用Ubuntuでは、リモートリポジトリから変更を取得するために `git pull` を使用している。

ただし、Codexは無条件に `git pull` を実行する手順を作らないこと。先に以下を確認すること。

```bash
git status --short
git branch --show-current
git remote -v
```

未コミット変更がある場合、`git pull`、`git reset --hard`、`git clean` などで変更を破棄してはならない。

通常は、対象ブランチを明示して次のように更新する。

```bash
git pull --ff-only origin <branch>
```

`--ff-only` で更新できない場合は、自動的にmergeやrebaseを行わず、履歴の不一致として停止すること。

## IaC変更の扱い

Nginx、systemd、ディレクトリ、権限、証明書、環境変数などの変更は、可能な限り `mitsubachi-infra` のコードまたはテンプレートとして実装する。

開発用Ubuntuでテンプレートを変更した後は、次の段階を区別すること。

```text
1. 開発用Ubuntu上で実装・テスト
2. commitおよびpush
3. リリース用Ubuntuでgit pull
4. dry-run
5. 実際の適用
6. 配置結果とサービス状態の確認
```

開発用Ubuntu上でテストが成功したことと、リリース用Ubuntuへの適用が成功したことは別の状態として扱うこと。

実装完了時には、必要に応じて次を分けて提示すること。

- 開発用Ubuntuで実行するコマンド
- リリース用Ubuntuで実行するコマンド
- リリース後の確認コマンド
- ロールバック手順
