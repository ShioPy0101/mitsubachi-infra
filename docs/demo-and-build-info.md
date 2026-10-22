# デモ専用ホストとビルド情報の運用

この変更は設定・サービス生成までを実装する。本番 Ubuntu への適用と DNS 変更は別工程であり、
開発環境でのテスト成功は適用済みを意味しない。既存の本番 DB 設定・秘密情報は変更しない。

## デモの構成

| 対象 | ホスト / 経路 |
| --- | --- |
| 通常 frontend | mitsubachi.shiosalt.com |
| デモ frontend | demo.mitsubachi.shiosalt.com |
| 通常 API | mitsubachi-api.shiosalt.com → 127.0.0.1:3000 |
| デモ API | mitsubachi-demo-api.shiosalt.com → 127.0.0.1:3002 |

frontend の同一ビルド成果物からホストに応じて独立したデモアプリを起動する。
デモでは通常の認証プロバイダー・実テナント向け画面を起動せず、専用 API とだけ通信する。
API は同じ backend release のコードを別 systemd プロセス・別環境ファイルで起動する。
Nginx もデモ API には `/api/v1/demo/*` と liveness だけを許可し、通常 API・実ファイル配信を公開しない。

## 有効化前の準備

1. frontend / backend / infra の対応 PR を取り込む。リリース対象のブランチ・commit を確認する。
2. 2つのデモホストの DNS A（IPv6 を使う場合は AAAA）を本番サーバーへ向ける。
3. `/etc/mitsubachi/demo-rails.env` を本番 Ubuntu 上で管理者が新規に用意する。
   所有権と権限は既存の Rails 環境ファイルと同じ運用で保護する。本番用ファイルはコピーしない。
4. デモ専用の SECRET_KEY_BASE と、独立した DATABASE_URL / DATABASE_CACHE_URL /
   DATABASE_QUEUE_URL / DATABASE_CABLE_URL を設定する。デモ DB と cache schema の準備も別途必要。
   既存の本番 DB 接続先を転用しない。デモでは User / Organization / DriveItem を登録しない。
5. 現行 Rails の起動設定は RESEND_API_KEY の値を要求する。デモでは実送信しないため、
   本番用 API key を転用せず `unused-demo` などのダミー値を指定する。
   必要な Ruby / bundle と通常 backend release が配置されていることを確認する。

デモモード、専用 Host/Origin、別ポート、ストレージへのアクセス制限は専用 unit に定義する。
環境ファイルでこれらを通常テナント用に再定義しない。

## 有効化と適用

`/etc/mitsubachi/config.yml` の追加設定は以下。既定では無効。

```yaml
demo:
  enabled: true
  api_port: 3002
  rails_env: /etc/mitsubachi/demo-rails.env
```

`demo.enabled` を有効にすると、証明書取得対象にデモ2ホストを追加し、Nginx と
`mitsubachi-demo-api.service` を生成する。通常 API と同一ポート・同一環境ファイルの指定は拒否する。

本番 Ubuntu 上で infra checkout の状態・branch・remote を確認し、変更がないことを確認する。
対象ブランチを確認した後だけ `git pull --ff-only origin <branch>` で更新する。
適用は更新した checkout の CLI を使用する。

```bash
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml --dry-run install
sudo ./bin/mitsubachi-infra --config /etc/mitsubachi/config.yml install
sudo mitsubachi-infra https check
sudo mitsubachi-infra https enable
```

既存の install と同様、サービスの反映・再起動や HTTPS 設定の適用を伴う。
`https enable` は DNS が解決可能で TCP 80/443 が到達可能な環境で実行する。
frontend も通常の deploy 手順で再ビルドする。`demo.enabled=true` のときだけ
`VITE_FEATURE_DEMO_TENANT=true` をビルドに渡す。
frontend.env に `VITE_FEATURE_DEMO_TENANT=false` を設定すると導線だけを無効にできる。
未指定・無効時にデモを公開しない方針を frontend と backend の両方で維持する。

通常の release deploy・backend deploy・rollback では、デモ有効時だけ専用サービスも再起動する。
デモプロセスの直接起動・systemd のセキュリティ設定は Ubuntu 上で検証すること。

## 確認

```bash
sudo systemctl cat mitsubachi-demo-api.service
sudo systemctl status mitsubachi-demo-api.service --no-pager
sudo journalctl -u mitsubachi-demo-api.service -n 50 --no-pager
sudo nginx -T
curl -I https://demo.mitsubachi.shiosalt.com/login
curl https://mitsubachi-demo-api.shiosalt.com/api/health/live
```

通常ログインに `demo@tenant.example` を入力し、別ホストへの即時移動、未送信メールの
モーダル、認証リンク、左上の demo バッジ、フォルダーの移動、転送制限の表示を確認する。
POST の Origin・認証リンクの有効期限と一回制限・API の feature flag も backend テストで確認している。

## 無効化・ロールバック

frontend.env の flag を false にして再ビルドすると新規導線を止められる。
全体を止める場合は `demo.enabled: false` として install / HTTPS 設定を再適用し、
不要になった `mitsubachi-demo-api.service` は `systemctl disable --now` で停止する。
通常 frontend / API のホスト・サービス・データは維持する。
アプリの rollback には既存 rollback 手順を使い、DB を戻す操作は追加しない。

## ビルド情報

- frontend build: 解決した Git SHA と UTC ビルド時刻を Vite に渡し、bundle に固定する。
- frontend production: `dist/release-info.json` に現在配信中の SHA・ビルド日時・反映日時を記録する。
- backend: release 内の `build-info.json` に同じ項目を記録し、管理 API が返す。
- release 切り替え前に deployed_at を記録する。rollback 時は旧 release の成果物がそのまま復元される。
- 情報がない古い release は管理画面で「未記録」と表示し、プロセス起動時刻で代用しない。

管理画面では frontend のビルドと本番配信、backend のビルドと稼働中 release を比較できる。
これらの JSON は秘密情報や環境変数全体を含まない。
