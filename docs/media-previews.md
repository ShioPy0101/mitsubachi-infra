# Media Preview 運用

Mitsubachi の一覧用 Preview は Original から再生成できる派生キャッシュです。
Original は `/mnt/external-hdd/mitsubachi/files/drive_items`、Preview は
`/mnt/external-hdd/mitsubachi/files/previews` に分離します。Rails が生成と認可を
担当し、画像本体は Nginx の `internal` location から X-Accel-Redirect で配信します。

## Ubuntu 24.04 の手動セットアップ

OS package は deploy / bootstrap script から導入しません。サーバー管理者が
メンテナンス手順として次を手動実行してください。`ffmpeg` package には
`ffprobe` も含まれ、`libvips-tools` は Ruby の `ruby-vips` が利用する libvips
runtime と確認用 `vips` command を導入します。

```bash
sudo apt update
sudo apt install ffmpeg libvips-tools
```

管理者 shell だけでなく、mitsubachi-api の実行 user と同じ `deploy` user から
確認します。systemd unit の PATH には `/usr/bin` が含まれます。

```bash
ffmpeg -version
ffprobe -version
vips --version
sudo -u deploy env PATH=/home/deploy/.rbenv/shims:/home/deploy/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ffmpeg -version
sudo -u deploy env PATH=/home/deploy/.rbenv/shims:/home/deploy/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ffprobe -version
sudo -u deploy env PATH=/home/deploy/.rbenv/shims:/home/deploy/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin vips --version
sudo -u deploy ./scripts/check-media-tools.sh
```

`scripts/check-media-tools.sh` は executable の存在と version 表示だけを行い、
package、設定、filesystem を変更しません。標準外の FFmpeg を使う場合だけ、
`/etc/mitsubachi/rails.env` の運用手順で `MEDIA_FFMPEG_PATH` を設定し API を
再起動します。repository 内の `.env` や credentials は変更しません。

## Preview cache directory

通常の初期構築では `scripts/bootstrap_ubuntu.sh` が mountpoint を確認した後、
次の directory を冪等に作成します。既存サーバーへ適用する場合は infra の
install/update 手順を実行し、owner/group/mode を確認してください。

```text
/mnt/external-hdd/mitsubachi/files/previews
owner: deploy
group: mitsubachi-files
mode: 2750
```

Rails (`deploy`) は生成のため write、Nginx (`www-data`) は配信のため read のみ
必要です。`mitsubachi-files` group の setgid directory により、atomic rename 後も
Nginx から読める group を維持します。

```bash
sudo -u deploy test -w /mnt/external-hdd/mitsubachi/files/previews
sudo -u www-data test -r /mnt/external-hdd/mitsubachi/files/previews
sudo -u www-data test ! -w /mnt/external-hdd/mitsubachi/files/previews
sudo nginx -t
```

`/internal/previews/` は Nginx の `internal;` location です。外部 URL から直接
取得できず、Rails が login organization または external share の対象 item を
認可した後に返す X-Accel-Redirect でのみ配信されます。

## Tool がない場合

FFmpeg や libvips を systemd の必須起動条件にはしていません。未導入でも
Mitsubachi API、download、share、通常 Drive は起動します。libvips がなければ
画像 Preview、FFmpeg がなければ動画 Preview の生成 request だけが失敗し、
Frontend は既存の file type icon へフォールバックします。Rails log には
organization ID、DriveItem ID、generator type と失敗理由が記録されます。
