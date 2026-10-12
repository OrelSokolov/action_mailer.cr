# action_mailer.cr

A Crystal port of Rails **ActionMailer 8.1.4** — mailer DSL, MIME
message assembly, SMTP/sendmail/file/test delivery, `deliver_later`
via ActiveJob, parameterized mailers and previews. Namespace
`ActionMailer` mirrors the original 1:1; the hidden bulk of the work is
a minimal port of the `mail` gem (MIME assembly + SMTP client).
Estimated parity ~80%. Suite: **66/66**.

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  action_mailer_cr:
    github: OrelSokolov/action_mailer.cr
```

```sh
shards install
```

Depends on `active_support.cr`, `action_view.cr` (templates),
`active_job.cr` (`deliver_later`).

## Usage

```crystal
class ApplicationMailer < ActionMailer::Base
  default from: "noreply@example.com"
  layout "mailer"
end

class UserMailer < ApplicationMailer
  def welcome_email(user)
    attachments["terms.pdf"] = {mime_type: "application/pdf", content: pdf}
    headers["X-Custom"] = "value"
    mail(to: user.email, subject: "Welcome!")
  end
end

UserMailer.welcome_email(user).deliver_now
UserMailer.with(user: user).welcome_email.deliver_later(wait: 5.minutes)
```

## Feature comparison vs actionmailer 8.1.4 (+ mail 2.9.1)

### DSL & messages

| Feature | Original (actionmailer) | Port (action_mailer.cr) | Status |
|---|---|---|---|
| `class XMailer < ApplicationMailer`, `default from:`, `layout` | ✅ | Same | ✅ |
| Action = method; class-level `UserMailer.welcome_email(user)` → MessageDelivery | ✅ (class-level `method_missing`) | Macro-generated via compile-time registry + codegen → lazy memoized MessageDelivery | ✅ |
| `mail(to:, subject:)`, `mail do \|format\| format.text {} format.html {} end` | ✅ | Fixed collector methods instead of method_missing | 🔶 |
| `attachments["x.pdf"] = {mime_type:, content:}`, `attachments.inline`, `headers[...]` | ✅ | attachments ✅; inline attachments not ported | 🔶 |
| Multipart auto-discovery (`welcome_email.{html,text}.ecr` → multipart/alternative) | ✅ | Same (1 format → single part, 2 → alternative, attachments → mixed on top) | ✅ |
| Callbacks: `before/after/around_action`, `before/after/around_deliver`, `rescue_from` | ✅ | Same | ✅ |
| Subject via I18n (`user_mailer.welcome_email.subject`) | ✅ | Not ported | ⬜ |
| Parameterized `.with(user: u).action` | ✅ | `Parameterized::Mailer`, `params["user"]` in mailer methods, params carried by MessageDelivery and `deliver_later` serialization (byte-1:1 with Ruby args) | ✅ |
| `register_observer` / `register_interceptor` | ✅ | Not ported | ⬜ |
| Previews: `XMailerPreview < ActionMailer::Preview`, `/rails/mailers` dev page | ✅ | Compile-time registry (`Preview.all/find/exists?`, `.call`), preview server with `?part=text\|html` | ✅ |

### Delivery

| Feature | Original | Port | Status |
|---|---|---|---|
| `deliver_now / deliver_now! / deliver_later(wait:, queue:, priority:) / .message` | ✅ | Same; `deliver_later` enqueues `MailDeliveryJob` (queue :mailers) with Rails 8.1-identical arguments | ✅ |
| Delivery methods `:smtp/:sendmail/:file/:test` + registry (`add_delivery_method`), `smtp_settings`, `raise_delivery_errors`, `perform_deliveries`, `deliveries` | ✅ | Same registry + adapters; SMTP client (RFC 5321 subset: EHLO/MAIL/RCPT/DATA/QUIT, dot-stuffing) | 🔶 |
| STARTTLS / SMTP auth | ✅ | Not ported (P1) | ⬜ |
| Resend (API delivery) | separate gem/HTTP | `:resend` adapter registered out of the box (POST /emails, Bearer key) | ➕ |
| MessageDelivery facade | method_missing delegation | Explicit method list (no runtime delegation) | 🔶 |

### mail-gem port (`mail/` inside the shard)

| Feature | Original (mail gem) | Port | Status |
|---|---|---|---|
| MIME assembly: multipart/alternative, mixed, related; quoted-printable/base64 | ✅ | CTE 7bit/base64 chosen by content; QP bodies not emitted (UTF-8 passthrough, oracle-confirmed) | 🔶 |
| RFC 5322/2045/2047 subset covering transactional email | ✅ | `src/rfc2822.cr` wire renderer | ✅ |

## Deviations & Crystal-specific notes

- Params keys are Strings, not Symbols (`params["user"].as(String)`); the
  `_aj_symbol_keys` marker is emitted during `deliver_later`
  serialization so Ruby-side ActiveJob can deserialize.
- MessageDelivery is an explicit facade — no `method_missing`.
- Oracle semantics captured: ASCII attachments ride 7bit; from/to read
  as arrays.

## Testing

```sh
crystal spec   # 66/66
```

Oracle: `oracle/cases.rb` → `oracle/expected.yml`, recorded with
actionmailer 8.1.4 + mail 2.9.1 (delivery :test; DSL/MIME/multipart/
attachments/headers/unicode/deliver_later/parameterized/delivery
methods), replayed without editing the cases. The SMTP protocol is
pinned by a fake-server spec (`spec/smtp_spec.cr`); delivery adapters
are unit-tested against a local stub server (`spec/delivery_spec.cr`,
no network).
