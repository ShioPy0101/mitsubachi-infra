# 通常アップロード統計と大容量試験の運用手順

通常の単一・複数・フォルダアップロードは、試験用URLやfeature flagなしで常時計測されます。ブラウザは操作ごとにUUIDの`upload_session_id`を1個生成し、同じ操作のファイル・ディレクトリ作成リクエストへ`X-Upload-Session-ID`として付与します。統計にはファイル名、相対パス、本文、Cookie、Authorization、アクセストークン、IPアドレス、User-Agent全文を保存しません。

## system adminでの確認

システム監査の「アップロード統計」を開き、24時間・7日・30日または任意期間を選択します。Organization、状態、ユーザー、サイズ帯、アップロード種別、エラーコード、最低容量・ファイル数で絞り込めます。概要、時系列、ページ分割されたセッション一覧は同じ条件を使います。詳細画面ではサイズ分布、HTTP/エラー集計、進捗停止、Long Task、バックグラウンド時間、バージョン、request ID、関連する操作ログを確認できます。

`completed`だけを成功セッションとし、ファイル成功率とは分けて表示します。p50は対象値を昇順に並べた50パーセンタイル、p95所要時間は95パーセンタイルです。ゼロ値は性能パーセンタイルから除外します。「要確認」は失敗・一部失敗・abandoned、ファイル失敗率5%以上、再試行率10%以上、進捗停止、設定した低速しきい値のいずれかで表示し、障害とは断定しません。

ブラウザからの送信は開始時1回、30秒ごとのUPDATE、終了時1回です。ファイル単位イベントや時系列サンプルはDBへ保存しません。観測APIの失敗はアップロードを失敗させません。`in_progress`の最終観測から既定2時間経過すると`abandoned`、セッション集計は既定180日後に削除されます。しきい値は`UPLOAD_METRIC_ABANDONED_AFTER_MINUTES`、`UPLOAD_METRIC_RETENTION_DAYS`で変更できます。

## リリース

開発環境のCI成功後、リリース用Ubuntuの各リポジトリで先に状態を確認します。

```bash
git status --short
git branch --show-current
git remote -v
git rev-parse HEAD
```

未コミット変更がない場合だけ、対象ブランチを`git pull --ff-only origin <branch>`で取得して通常の統合デプロイとDB migrationを行います。Infraは先にdry-runし、適用後の実設定を検査します。

```bash
cd <infra-repository>
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml --dry-run install
sudo nginx -t
sudo nginx -T
sudo systemctl cat mitsubachi-api.service
sudo systemctl status mitsubachi-api.service --no-pager
```

`config/logrotate-mitsubachi-upload`はデプロイ処理で`/etc/logrotate.d/mitsubachi-upload`へ`root:root 0644`で配置し、`sudo logrotate -d /etc/logrotate.d/mitsubachi-upload`で検査します。開発環境のテンプレート変更だけでは本番へ反映されません。

## 60GB試験とOS負荷採取

通常のDrive画面から対象フォルダを選びます。特別なクエリパラメータは不要です。DevTools NetworkでアップロードPOSTの`X-Upload-Session-ID`を控え、同じ操作の全リクエストで一致することを確認します。開始直前にリリース用Ubuntuで次を実行します。DB URLはコマンド履歴へ直接書かず、管理された環境から読み込んでください。

```bash
sudo /opt/mitsubachi-infra/current/bin/capture-upload-load \
  --session-id '<UUID>' \
  --output-dir /var/log/mitsubachi/load-tests \
  --mount-point /mnt/external-hdd \
  --database-url "$DATABASE_URL"
```

利用可能なら`vmstat 1`、`iostat -xz 1`、`pidstat -durh 1`、`sar -n DEV 1`を採取します。定期スナップショットには容量、メモリ、load average、TCP接続、Nginx・Rails・PostgreSQL・workerのCPU/メモリ/FDを含みます。DB前後値は推定行数を使い、主要テーブルの全件COUNTは行いません。完了または中止時にCtrl-Cを押すと子プロセスを停止して終了スナップショットを保存します。

## ログの突合

- Nginx: `/var/log/nginx/mitsubachi_upload_access.jsonl`。Rails未到達の413/499/502等も記録します。
- Rails: journalの`upload_completed`/`upload_failed`構造化ログ。`upload_session_id`、`request_id`、controller/DB/storage/hash時間を含みます。
- DB/API: `upload_metrics`およびsystem adminの詳細API `GET /api/v1/system_admin/upload_metrics/<UUID>`。
- OS: `/var/log/mitsubachi/load-tests/<UUID>/`の`metadata.json`、前後snapshot、時系列ログ。

まずUUIDでNginx、Rails、`upload_metrics`、OSディレクトリを揃え、NginxとRailsは`request_id`、OS/DBはISO 8601時刻で照合します。詳細APIのJSONはファイル名を含まないため、必要なら認証済みsystem adminセッションで保存できます。

```bash
curl --fail-with-body --cookie cookies.txt \
  'https://mitsubachi-api.example/api/v1/system_admin/upload_metrics/<UUID>' \
  --output "upload-metric-<UUID>.json"
```

## 中止、復旧、ロールバック

中止時はブラウザでアップロードをキャンセルし、採取スクリプトへCtrl-Cを送ります。`child-pids.txt`のPIDが残っていないことを確認します。試験対象サービスを止める必要はありません。容量と`sudo systemctl status mitsubachi-api mitsubachi-worker nginx --no-pager`を確認し、通常のInfra rollback手順を使います。DB migrationは自動で戻らないため、旧コードとの互換性確認前に手動rollbackしないでください。
