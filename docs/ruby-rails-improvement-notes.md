# Ruby / Rails 改善記録

## 2026-10-23: Ruby のビルド定義と実行環境の選択

- 状況: リリースの `.ruby-version` から Ruby を自動準備するデプロイへ移行した。
- 困った点: ruby-build は fetch のみでは新バージョンの定義が有効にならず、リリース外の `gem` は global Ruby へ Bundler を導入する。環境変数での固定も `.ruby-version` より優先される。
- 望ましい改善: バージョン定義の更新と、対象プロジェクトの Ruby・Bundler の準備・検証を一貫して明示できる仕組み。
- 今回の回避策: ruby-build を変更を保持する fast-forward で更新し、Bundler と Rails はリリース内で実行する。systemd 起動時は Ruby 選択の環境変数を除去し、旧リリースと旧 Ruby を保持する。
