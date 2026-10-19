# Спека: проверка списков e-mail (Emails · Newsletters · CRM)

Статус: черновик на согласование владельцем · 2026-10-19 · задача I304
Источник требований: PLAN-pi.md (Python verifier-core) — берём движок и требования,
архитектура — PhoenixKit (Ecto/Postgres, Oban, LiveView).

## 1. Цель

Проверять адреса подписчиков рассылок (Newsletters) и контактов CRM по конвейеру
syntax → словари → DNS MX → SMTP RCPT (+ catch-all) и показывать статус в админке.
Один общий движок, два потребителя.

## 2. Где живёт движок — `phoenix_kit_emails`

Решение: движок, таблицы и Oban-воркер — в `phoenix_kit_emails`
(`PhoenixKit.Modules.Emails.Verification.*`). Newsletters и CRM обращаются к нему
**мягко** (`Code.ensure_loaded?/1` + `function_exported?/3`, как `PhoenixKitCRM.StaffLink`),
без новой зависимости в `mix.exs` (кроме `only: :test`).

Почему так:
- Emails — инфраструктурный модуль «почты» хоста: в нём уже blocklist, лог отправок,
  Oban-воркеры; ядро `PhoenixKit.Mailer` уже мягко зовёт `Emails.RateLimiter.check_blocklist/1`
  при каждой отправке. Результат проверки естественно стыкуется с blocklist (этап 3, за флагом).
- Ни CRM, ни Newsletters не владеют «адресом» как сущностью: у Newsletters нет таблицы
  подписчиков вовсе (аудитория = CRM-список или роли пользователей, резолвится при отправке),
  в CRM e-mail — поле контакта + снапшот в `list_members`. Положить движок в один из них —
  значит заставить другого зависеть от чужого домена (Newsletters уже мягко зависит от CRM,
  обратная связь дала бы цикл).
- Результат хранится по нормализованному адресу (одна таблица на весь хост) → таблицы
  CRM/Newsletters **не меняются** (нет миграций adopted-таблиц, нет конфликта с
  core `ExpectedSchema`), dev-данные не трогаются.

Альтернатива (не выбрана): отдельный пакет `phoenix_kit_email_verifier`. Чище по
границам, но новый репозиторий вне форков и ещё один модуль в каждом хосте.
Можно вынести позже без смены схемы.

Цена решения: в цепочке миграций Emails пока только «усыновление» таблиц ядра —
нужен версионный блок создания собственных таблиц (по образцу
`PhoenixKitNewsletters.Migrations` V2 / `phoenix_kit_newsletters_layouts`).

## 3. Конвейер и статусы

Шаги (каждый пишет строку в `log`; конвейер останавливается на первом окончательном
вердикте):

| # | Шаг | Окончательный исход |
|---|-----|---------------------|
| 1 | Нормализация: trim, нижний регистр домена (IDN → punycode), local-part как есть | — |
| 2 | Syntax (RFC 5321/5322 упрощённо: длины 64/254, точки, допустимые символы) | Invalid `syntax` |
| 3 | TLD по списку IANA | Invalid `bad_tld` |
| 4 | DEA (одноразовые домены) | `email_verify_disposable_status`: Temp `disposable` (дефолт, как в LetsExtract, ANALYSIS §7; решение владельца Q8) или Invalid `disposable`; флаг `disposable` ставится в обоих случаях |
| 5 | Флаги без вердикта: `free` (gmail.com…), `role` (info@, sales@…), `fake`, `curse`, `typo` (шаг `marks` сразу после syntax, чтобы флаги ставились при любом исходе) | — |
| 6 | DNS MX (кэш → `:inet_res`); нет MX → A/AAAA (implicit MX, RFC 5321 §5.1) | нет ни MX, ни A: Invalid `no_mx`; SERVFAIL/таймаут: Temp `dns_error` |
| 7 | SMTP RCPT — **только при `email_verify_smtp_enabled = true`** (дефолт ВЫКЛ) | см. ниже |

Статусы: `valid | invalid | temp | not_sure` + `catch_all :: boolean | nil`.

Срез алиаса: `user+tag@domain` проверяется как `user@domain` (флаги, роль, SMTP-клиент);
результат хранится под исходным нормализованным адресом, в `log` шага `normalize` —
`"checked_as"`. Анти-DNS-hijack: при падении на implicit MX резолвится заведомо
несуществующее имя (`<случайное>.com`, раз в час на VM и резолвер); если оно «существует»,
его адреса вычитаются из A-ответов домена. `fake`/`curse`/`typo` — флаги без вердикта
(владелец: «Fake Pattern и Curse Words — не вердикт»), хранятся булевыми колонками
`fake`, `curse`, `typo` в `phoenix_kit_email_verifications`, нигде не показываются и
статус не меняют (решение владельца Q9: только флаги, никогда не вердикт).

Без SMTP (этап 1, дефолт): прошедший шаги 1–6 адрес получает `not_sure` с
`level = "mx"` (домен принимает почту, ящик не проверен). `valid` выдаёт только SMTP.
В UI: «Домен OK (без SMTP)». См. вопрос владельцу Q3.

Коды `reason` для этого случая (реализация этапа 1):
- `smtp_disabled` - флаг `email_verify_smtp_enabled` выключен, шаг SMTP пропущен
  (`status = not_sure`, `level = "mx"`). Метка «Домен OK (без SMTP)» = `level "mx"` + `smtp_disabled`.
- `smtp_unavailable` - флаг включён, но настроенный клиент - заглушка `Smtp.Disabled`
  (`not_sure`, `level = "mx"`).
- `smtp_error` - клиент вернул иную ошибку (`not_sure`, `level = "mx"`).

SMTP (этап 2, за флагом): HELO = FQDN из настройки, MAIL FROM из настройки,
RCPT TO адреса; классификация по коду: 250 → valid; 550/551/553 «user unknown» → invalid;
450/451/452 + greylist-маркеры → temp (отложенный повтор); 421/554 «blocked/spam» →
temp + блок-счётчик домена; таймаут → backoff. Catch-all: RCPT на случайный
`<random>@domain` → 250 ⇒ домен catch-all, адрес → `not_sure`, `catch_all = true`
(не «улучшаем», как в оригинале).

Результат: `status`, `reason`, `level` (`syntax|dict|mx|smtp`), `catch_all`, `free`,
`role`, `disposable`, `mx` (preferred host), `log` (список шагов с таймингами),
`checked_at`, `source` (`direct|cache`).

## 4. Словари

Файлы в `priv/email_verification/` (один домен/префикс на строку), загружаются лениво
в `:persistent_term`:
- `disposable.txt`, `free.txt`, `tlds.txt`, `role_prefixes.txt`, `not_fake.txt` (whitelist).
- Источник: снапшоты Kellerman из прототипа Пая (если владелец даст — Q1); иначе
  открытые списки: `disposable-email-domains` (CC0), IANA `tlds-alpha-by-domain.txt`,
  собранный free-список. Обновление списков (cron) — этап 3.
- Хост может дополнить своими списками: каталог `email_verify_lists_dir` (или app env
  `:verification_lists_dir`). Каталог Kellerman принимается как есть (CRLF, TLD с точкой,
  имена `DEA_Sorted.txt`, `FreeEmail_Sorted.txt`, `TopLevelDomains.txt`, `Typos_Sorted.txt`,
  `FakeAddresses_Sorted.txt`, `CurseWords_Sorted.txt`, `Greylisting_Sorted.txt`,
  `MailboxQuota_Sorted.txt`, `Blocking_Sorted.txt`); последние три — фразы классификации
  ответа SMTP для этапа 2, пока не используются. В git эти файлы не кладутся.

## 5. Данные (миграция Emails V4, только CREATE, ничего не меняет в существующих таблицах)

`phoenix_kit_email_verifications` — последний результат по адресу:
`uuid`, `email citext UNIQUE`, `domain`, `status`, `reason`, `level`, `catch_all`,
`free`, `role`, `disposable`, `fake`, `curse`, `typo`, `mx`, `log jsonb`, `attempts`, `checked_at`, timestamps.
Индексы: `(status)`, `(domain)`.

`phoenix_kit_email_verify_domains` — персистентный кэш и состояние домена (одна строка
на домен вместо четырёх таблиц прототипа; у каждого поля свой timestamp → свой TTL):
`domain PK`, `mx jsonb`, `has_mx`, `mx_checked_at` (TTL 24 ч; отсутствие MX — тот же
TTL 24 ч), `catch_all`, `catch_all_checked_at` (TTL 7 сут), `grey_message`, `grey_at`
(TTL 24 ч), `last_smtp_at`, `blocks jsonb` (метки блоков за час), `paused_until`.

`phoenix_kit_email_verify_batches` — пакет: `uuid`, `source_type`
(`newsletters_crm_list|newsletters_user_group|crm_list|crm_contacts|manual`),
`source_ref`, `title`, `state` (`queued|running|done|cancelled`), `total`,
`processed`, `counts jsonb` (по статусам), `created_by_uuid`, `started_at`,
`finished_at`, timestamps.

`phoenix_kit_email_verify_batch_items` — состав пакета: `batch_uuid`, `email`,
`state` (`pending|done`), `next_attempt_at`; unique `(batch_uuid, email)`.

TTL — настройки (`email_verify_ttl_mx_hours=24`, `…_catch_all_days=7`,
`…_no_mx_hours=24`, `…_grey_hours=24`, `…_result_days=30` — повтор адреса раньше
срока берётся из `verifications` с `source = cache`).

## 6. Фоновые задачи

- Очередь `email_verification` (объявляется через `oban_queues/0` модуля Emails,
  лимит = глобальный лимит одновременных проверок, дефолт 5). Без очереди в конфиге
  хоста — UI показывает предупреждение (известная ловушка «job никогда не выполнится»).
- `BatchStartWorker` раскладывает пакет в `batch_items` и ставит `VerifyEmailWorker`
  по одному на адрес (`unique: [keys: [:batch_uuid, :email], states: :incomplete]`).
- `VerifyEmailWorker`: результат из кэша, если свежий; иначе конвейер. Обновляет
  `verifications`, item, счётчики пакета (атомарный `UPDATE … SET processed = processed + 1`),
  шлёт PubSub `email_verify:batch:<uuid>` для прогресса в LiveView.
- Retry / greylist: `temp greylist` → `{:snooze, 15–30 мин}` (настройка), до N попыток,
  потом остаётся `temp`. Таймаут SMTP → backoff 30 с → 60 с → `not_sure`.
- Троттлинг (только SMTP): перед соединением — `SELECT … FOR UPDATE` строки домена;
  если `now - last_smtp_at < email_verify_domain_interval_s` (60) или `paused_until > now`
  → `{:snooze, остаток}`. 2+ блоков за час → `paused_until = now + 1 ч`, лог-предупреждение
  (алерт в TG — вне PhoenixKit, этап 3 через хост).
- DNS-стадия не троттлится по домену (кэш MX и так даёт один запрос на домен в сутки).

## 7. Публичный API движка (для потребителей)

```elixir
Verification.enabled?() :: boolean
Verification.verify(email, opts) :: {:ok, Result.t()}       # синхронно, без SMTP по умолчанию
Verification.start_batch(emails, source_type, source_ref, opts) :: {:ok, Batch.t()} | {:error, term}
Verification.get_batch(uuid) / list_batches(source_type, source_ref)
Verification.results_for(emails) :: %{email => Result.t()}  # для колонок статуса
Verification.summary(emails) :: %{valid: n, invalid: n, temp: n, not_sure: n, unchecked: n}
Verification.subscribe_batch(uuid)
```

Потребители передают **список адресов** (резолвят свою аудиторию сами) — движок не знает
о CRM/Newsletters.

## 8. UI

**Newsletters (этап 1).** Новая видимая подвкладка «Проверка адресов»
(`/admin/newsletters/verification`): выбор аудитории (CRM-список или группа ролей —
те же резолверы `CRMSource`/`UserGroupSource.sendable_recipients/1`, что у отправки),
таблица адрес / статус / причина / catch-all / проверен, фильтр по статусу
(`?status=`, `push_patch`), сводка-плашки по статусам, кнопка «Проверить список»
→ пакет, прогресс-бар по PubSub. Если Emails не установлен/выключен — вкладка
показывает «требуется модуль Emails». Этап 2: сводка рядом с preflight в редакторе рассылки.

**CRM (этап 2).** `ListMembersLive`: кнопка «Проверить список» в шапке, колонка
статуса, фильтр `?verify=`; `ContactsLive`: колонка статуса и фильтр. Через
`PhoenixKitCRM.EmailsLink` (мягкая связь).

**Emails.** Подвкладка «Проверка» с историей пакетов и настройками (этап 2).

## 9. Безопасность и ограничения

- SMTP-стадия выключена по умолчанию (`email_verify_smtp_enabled = false`); при
  выключенной стадии код SMTP не открывает сокет вовсе. В тестах SMTP-клиент — behaviour
  с mock-реализацией; живой SMTP — только 2–3 своих адреса (hydroforce.ee, eurobalt.net)
  после решения Q2.
- В тестах DNS тоже подменяется (behaviour `Resolver`); живой DNS — только в
  тегированных `:external` тестах, по умолчанию исключённых.
- Данные CRM/Newsletters не меняются; запись в blocklist — этап 3, отдельный флаг, дефолт ВЫКЛ.

## 10. Не делаем (вне рамок)

Внешний HTTP API наружу (Q4), скрипт-режим LetsExtract, prefilter по Brevo-истории,
сверка с `.lvp`/golden-тесты — фазы 3–4 плана Пая, после решения владельца.
