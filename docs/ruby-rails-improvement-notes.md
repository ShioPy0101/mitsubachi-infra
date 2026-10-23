# Ruby / Rails 改善記録

## 2026-10-23: Ruby のビルド定義と実行環境の選択

- 状況: リリースの `.ruby-version` から Ruby を自動準備するデプロイへ移行した。
- 困った点: ruby-build は fetch のみでは新バージョンの定義が有効にならず、リリース外の `gem` は global Ruby へ Bundler を導入する。環境変数での固定も `.ruby-version` より優先される。
- 望ましい改善: バージョン定義の更新と、対象プロジェクトの Ruby・Bundler の準備・検証を一貫して明示できる仕組み。
- 今回の回避策: ruby-build を変更を保持する fast-forward で更新し、Bundler と Rails はリリース内で実行する。systemd 起動時は Ruby 選択の環境変数を除去し、旧リリースと旧 Ruby を保持する。


## 2026-10-23: FileUtils のバックアップ API

- 状況: サーバー ID を config.yml に初期登録する際、既存 AtomicWriter のバックアップを実行した。
- 困った点: OS の `cp -a` と同じつもりで指定された `FileUtils.cp_a` が Ruby に存在せず、設定保存が NoMethodError で停止した。
- 望ましい改善: OS コマンドのオプションと Ruby 標準 API の対応を確認しやすいドキュメントと、実ファイルを使うバックアップの回帰検証。
- 今回の回避策: `FileUtils.cp_r` に `preserve: true, dereference_root: false` を指定し、通常ファイルと symlink のバックアップをテストした。
