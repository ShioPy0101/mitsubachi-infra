# Mail Delivery

メール配信は Rails API と Solid Queue worker の責務です。frontend は Rails API を呼ぶだけで、Resend API や SMTP を直接使用しません。

```text
Frontend
  -> HTTPS API request
Rails API
  -> deliver_later
Solid Queue database
  -> mitsubachi-worker.service
ActionMailer::MailDeliveryJob
  -> Resend SMTP/API
  -> Recipient
```

`mitsubachi-ruby` では `bin/jobs` が存在し、production の queue adapter は `solid_queue` です。Infra は `mitsubachi-worker.service` を Puma と分けて起動します。

## Test Mail

```bash
ruby exe/mitsubachi-infra mail-test --to test@example.com
```

このコマンドは本番 Rails の Action Mailer 設定を使います。API key は引数、ログ、frontend env に出しません。

## Checks

* `systemctl status mitsubachi-worker`
* `journalctl -u mitsubachi-worker -n 200 --no-pager`
* `RESEND_API_KEY` configured
* `MAIL_FROM` verified
* SPF / DKIM / DMARC configured
* Mail links use `https://mitsubachi.shiosalt.com`
