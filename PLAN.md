# action_mailer.cr — порт ActionMailer

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

Неймспейс: `ActionMailer` — 1:1. Оценка: ~80%. Главная скрытая работа —
не DSL, а минимальный порт mail-гема (MIME-сборка + SMTP).

## API 1:1

### DSL
- `class UserMailer < ApplicationMailer` (`ApplicationMailer <
  ActionMailer::Base`; `default from: ...`, `layout "mailer"`)
- `def welcome_email(user); mail(to:, subject:) end` — экшен = метод;
  макрос генерит классовый `UserMailer.welcome_email(user)` →
  MessageDelivery (в Rails это class-level method_missing)
- `.with(user: u).welcome_email` (parameterized)
- `.deliver_now / .deliver_now! / .deliver_later(wait: 5.minutes,
  queue:, priority:) / .message`
- `attachments["x.pdf"] = {mime_type:, content:}`, `attachments.inline`,
  `headers["X-Custom"] = v`
- `mail do |format| format.text { render "x" } format.html { } end`
  (фикс-методы коллектора)
- Коллбэки: `before_action/after_action/around_action`,
  `before_deliver/after_deliver/around_deliver`; `rescue_from`
- Subject через I18n: `user_mailer.welcome_email.subject` — 1:1
- Multipart auto-discovery: `welcome_email.{html,text}.ecr` →
  multipart/alternative
- `register_observer/register_interceptor`
- Previews: `UserMailerPreview < ActionMailer::Preview`,
  `/rails/mailers` dev-страничка (compile-time список preview-классов)
- Delivery methods: `:smtp/:sendmail/:file/:test` +
  `smtp_settings (address/port/user_name/password/enable_starttls_auto/
  openssl_verify_mode/...)`, `raise_delivery_errors`,
  `perform_deliveries`, `deliveries` (test)

### MessageDelivery
Ленивый прокси: `.message`, `.deliver_now/.deliver_later(...)`,
делегация к Mail::Message.

## Реализация

- **mail-port** (`mail/` внутри шарда): MIME-сборка (multipart/alternative,
  mixed, related; quoted-printable/base64; вложения), заголовки,
  SMTP-клиент (STARTTLS/SSL), sendmail-вызов, file-стрелялка.
  RFC 5322/2045/2047 subset, достаточный для 99% транзакционных писем.
- `deliver_later` сериализует имя мейлера+экшен+аргументы в ActiveJob —
  compile-time registry классов мейлеров (список известен при сборке).
- MessageDelivery — явный facade с перечисленными методами
  Mail::Message (без method_missing).

## Статус (Iteration 5 — P0 готов)

- Oracle: `oracle/cases.rb` → `oracle/expected.yml`, 24 кейса сняты с
  actionmailer 8.1.4 + mail 2.9.1 (delivery :test; DSL/MIME/multipart/
  attachments/headers/unicode). Зеркало: `spec/oracle_spec.cr` — 25/25.
- SMTP: `src/smtp.cr` (RFC 5321 subset: EHLO/MAIL/RCPT/DATA/QUIT,
  dot-stuffing; STARTTLS/auth — P1) + `src/rfc2822.cr` (wire-рендер).
  Оракулом не покрыт (нет SMTP-сервера в среде) — протокол зафиксирован
  фейк-серверным спеком `spec/smtp_spec.cr` (26/26 всего).
- Реализовано: `mail.cr` (Mail::Message/Part/Attachment/Body/Field,
  CTE 7bit/base64 по контенту), `base.cr` (DSL: default/mail/
  format-коллектор/attachments[]/headers[], классовые экшен-методы
  через registry+codegen → ленивая мемоизированная MessageDelivery,
  :test delivery).
- Семантика, снятая оракулом: ASCII-аттач едет 7bit; UTF-8 тело без
  явного CTE — passthrough (без QP); from/to читаются массивами;
  1 формат → single part, 2 → multipart/alternative, аттачи →
  multipart/mixed сверху.
- Не в P0 (зафиксировано): parameterized .with ✅, inline attachments,
  observers/interceptors, previews ✅, i18n-subject, QP/base64 тела,
  sendmail/file методы ✅ (фаза D), STARTTLS.
- deliver_later (P1) — готов: `MessageDelivery#deliver_later(wait:)`
  энкуит `MailDeliveryJob` (queue :mailers) через active_job_cr с
  аргументами Rails 8.1 1:1 (`[mailer, action, "deliver_now",
  {"args" => [...], "_aj_ruby2_keywords" => ["args"]}]`); оракул
  расширен до 28 кейсов (dl_*: класс джобы, аргументы, отсутствие
  доставки, scheduled). Спек: 30/30.
- Delivery-адаптеры (фаза D) — готово: `src/delivery.cr` — порт
  ActionMailer::DeliveryMethods: реестр `add_delivery_method(symbol,
  klass, default_settings)`, `delivery_method` (:smtp/:file/:test/
  зарегистрированный символ или сам объект DeliveryMethod),
  `delivery_settings(symbol)` + `smtp_settings`/`file_settings`,
  `raise_delivery_errors` (дефолт true), `Base.deliver` маршрутизирует
  (perform_deliveries/проглатывание ошибок — семантика do_delivery
  mail-гема). Адаптеры: `DeliveryMethod::Smtp` (существующий
  SmtpClient), `FileDelivery` (mail 2.9.1 1:1 — файл на получателя,
  имя = адрес, без .eml; дефолт tmp/mails), `TestMailer`
  (Base.deliveries). `MailDeliveryJob` honouring delivery_method.
- Resend (фаза D) — `src/resend.cr`: POST {scheme}://{host}:{port}/emails,
  Bearer api_key (hook-property `Resend.api_key` → ENV RESEND_API_KEY),
  JSON from/to/cc/bcc/subject/html/text/attachments[{filename,
  content_base64}], 2xx ок иначе DeliveryError. Зарегистрирован как
  :resend. Оракул расширен dm_* кейсами (custom/file/smtp-swallowed/
  unknown → 40 кейсов), зеркало + unit-спеки против локального
  stub-сервера (`spec/delivery_spec.cr`, без сети). Спек: 66/66.
- Parameterized `.with` (P1) — готово: `Mailer.with(user: u).action` →
  `src/parameterized.cr` (`Parameterized::Mailer` + вложенный
  `<Mailer>::Parameterized` с action-твинами из codegen в base.cr);
  внутри mailer-методов доступен `params["user"]` (Hash(String,
  ArgValue), дефолт `{}`); MessageDelivery несёт params (класс
  `ActionMailer::Parameterized::MessageDelivery` — как в Rails);
  deliver_later кладёт их kwargs'ом `params:` (`{"params" => {...,
  "_aj_symbol_keys" => [...]}, "args" => [...], "_aj_ruby2_keywords"
  => ["params","args"]}` — byte-1:1 с Ruby; маркер `_aj_symbol_keys`
  эмитится при сериализации, т.к. в порте ключи строковые — Crystal
  не умеет делать Symbol из строки в runtime), `MailDeliveryJob`
  применяет params к инстансу (пропуская `_aj_*`). Oracle: 8 кейсов
  with_* (subject/body/to/class/params-default/deliver_now/dl_job/
  dl_args). Deviation: ключи params — String, не Symbol; значения
  ArgValue-сериализуемые (`params["user"].as(String)`).
- Previews (P2) — готово: `src/preview.cr` — `ActionMailer::Preview`
  с compile-time реестром (macro inherited, как MAILERS; замена
  DescendantsTracker + Dir-загрузки): `Preview.all/find/exists?`,
  `.preview_name` (`UserMailerPreview` → `user_mailer`),
  `.emails/.email_exists?`, `.call(email, params)` и instance
  `#email(name)` (case-ladder вместо public_send — классы известны
  при сборке). `src/preview_server.cr` — рендер /rails/mailers
  (индекс + письмо, выбор part через ?part=text|html, дефолт html);
  монтируется через `CRails.dev_endpoints` (см. railties.cr).
  Спеки: `spec/preview_spec.cr` (14). Preview-interceptors — P2+
  (как observers).

## Фазы

- P0: mail-core (MIME + plain/text/html + вложения), SMTP, DSL
  (`default/layout/mail/deliver_now`), test-метод.
- P1: `deliver_later` (через active_job.cr), parameterized `.with`,
  multipart auto-discovery, inline attachments, observers/interceptors.
- P2: previews, i18n-subject полный, file/sendmail методы.

## Готово, когда

`UserMailer.welcome_email(user).deliver_now` отправляет реальное письмо
через SMTP с multipart/alternative + вложением, а
`.deliver_later` кладёт джобу в очередь.

## Зависимости

active_support.cr, action_view.cr (шаблоны), active_job.cr (P1).
