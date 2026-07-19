# PhoenixKitEmails

[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.18-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)

Email tracking, analytics, and AWS SES integration for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit). Drop-in email logging, delivery event tracking, engagement metrics, templating, rate limiting, and an admin dashboard.

## Features

- **Email logging** — comprehensive logging of all outgoing emails with optional body/header storage
- **AWS SES integration** — SQS-based event polling for delivery, bounce, complaint, open, and click events
- **Analytics & metrics** — system stats, engagement rates, campaign performance, and provider comparison
- **Email templates** — create and manage reusable email templates with a LiveView editor
- **Rate limiting** — configurable protection against abuse and spam via [Hammer](https://github.com/ExHammer/hammer)
- **Blocklist** — manage blocked email addresses
- **Queue management** — view and manage outgoing email queue
- **Archival** — automatic cleanup, body compression, and S3 archival of old email data
- **Webhook processing** — process incoming delivery/bounce/complaint webhooks
- **CSV export** — export email logs via controller endpoint
- **Email open/click tracking** — pixel tracking and link rewriting for engagement metrics
- **Admin dashboard** — LiveView pages for logs, metrics, templates, queue, blocklist, and settings
- **Auto-discovery** — implements `PhoenixKit.Module` behaviour; PhoenixKit finds it at startup with zero config

## Installation

Add `phoenix_kit_emails` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_emails, "~> 0.1"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

> **Note:** For development or if not yet published to Hex, you can use:
> ```elixir
> {:phoenix_kit_emails, github: "BeamLabEU/phoenix_kit_emails"}
> ```

PhoenixKit auto-discovers the module at startup — no additional configuration needed.

## Quick Start

1. Add the dependency to `mix.exs`
2. Run `mix deps.get`
3. Enable the module in admin settings (`email_enabled: true`)
4. Configure your AWS SES configuration set name in settings
5. Email logs and analytics are available at `/admin/emails`

## Usage

### System management

```elixir
alias PhoenixKit.Modules.Emails

# Check if system is enabled
Emails.enabled?()

# Enable/disable the system
Emails.enable_system()
Emails.disable_system()

# Get current configuration
config = Emails.get_config()
```

### Email logging

```elixir
# Create a log entry
{:ok, log} = Emails.create_log(%{
  to: "user@example.com",
  from: "noreply@example.com",
  subject: "Welcome!",
  status: "sent"
})

# List logs with filters
logs = Emails.list_logs(%{status: "sent", page: 1})

# Get a specific log
log = Emails.get_log!(log_uuid)
```

### Analytics

```elixir
# Get system statistics
stats = Emails.get_system_stats(:last_30_days)
# => %{total_sent: 5000, delivered: 4850, bounce_rate: 2.5, open_rate: 23.4}

# Get campaign performance
campaign_stats = Emails.get_campaign_stats("newsletter_2024")
# => %{total_sent: 1000, delivery_rate: 98.5, open_rate: 25.2, click_rate: 4.8}

# Get engagement metrics
metrics = Emails.get_engagement_metrics(:last_7_days)

# Get provider performance comparison
performance = Emails.get_provider_performance(:last_30_days)
```

### Webhook processing

```elixir
# Process an incoming webhook from AWS SES
{:ok, event} = Emails.process_webhook_event(webhook_data)

# List events for a specific log
events = Emails.list_events_for_log(log_uuid)
```

### Maintenance

```elixir
# Clean up old logs (by retention days)
{deleted_count, _} = Emails.cleanup_old_logs(90)

# Compress old email bodies to save storage
Emails.compress_old_bodies(30)

# Archive old data to S3
Emails.archive_to_s3(180)
```

## Settings

Settings are managed through the PhoenixKit Settings API and can be configured via the admin UI at `/admin/settings/email-sending`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `email_enabled` | boolean | `false` | Enable/disable the email system |
| `email_save_body` | boolean | `false` | Save full email body (vs preview only) |
| `email_save_headers` | boolean | `false` | Save email headers |
| `email_ses_events` | boolean | `false` | Manage AWS SES delivery events |
| `email_retention_days` | integer | `90` | Days to keep email logs |
| `aws_ses_configuration_set` | string | — | AWS SES configuration set name |
| `email_compress_body` | integer | — | Compress body after N days |
| `email_archive_to_s3` | boolean | `false` | Enable S3 archival |
| `email_sampling_rate` | integer | — | Percentage of emails to fully log |
| `email_create_placeholder_logs` | boolean | `false` | Create placeholder logs for orphaned events |

## Permissions

The module declares permissions via `permission_metadata/0`:

- `"emails"` — access to email admin dashboard and all sub-pages

Use `Scope.has_module_access?/2` to check permissions in your application.

## Architecture

```
lib/
  mix/tasks/
    phoenix_kit_emails.install.ex        # Install mix task
  phoenix_kit/modules/emails/
    emails.ex                            # Context + PhoenixKit.Module behaviour
    application_integration.ex           # Application-level integration
    archiver.ex                          # S3 archival logic
    email_log_data.ex                    # Email log data struct
    event.ex                             # Delivery/bounce/complaint event schema
    interceptor.ex                       # Email interceptor for logging
    log.ex                               # Email log schema
    metrics.ex                           # Analytics and metrics queries
    paths.ex                             # Centralized URL path helpers
    provider.ex                          # Provider behaviour
    rate_limiter.ex                      # Rate limiting via Hammer
    sqs_polling_job.ex                   # Oban job for SQS polling
    sqs_polling_manager.ex               # SQS polling lifecycle management
    sqs_processor.ex                     # SQS message processing
    supervisor.ex                        # OTP Supervisor
    table_columns.ex                     # Admin table column definitions
    template.ex                          # Email template schema
    templates.ex                         # Template management context
    utils.ex                             # Shared utilities
    web/
      blocklist.ex                       # Blocklist admin LiveView
      details.ex                         # Email log detail LiveView
      emails.ex                          # Email logs admin LiveView
      email_tracking.ex                  # Open/click tracking
      export_controller.ex               # CSV export controller
      metrics.ex                         # Metrics dashboard LiveView
      queue.ex                           # Queue management LiveView
      routes.ex                          # Route definitions
      settings.ex                        # Settings admin LiveView
      template_editor.ex                 # Template editor LiveView
      templates.ex                       # Templates admin LiveView
      webhook_controller.ex              # Webhook endpoint controller
```

### Database Tables

| Table | Description |
|-------|-------------|
| `phoenix_kit_email_logs` | Email log records (UUIDv7 PK) |
| `phoenix_kit_email_events` | Delivery/bounce/complaint/open/click events |
| `phoenix_kit_email_templates` | Reusable email templates |

## Development

```bash
mix deps.get       # Install dependencies
mix test           # Run tests
mix format         # Format code
mix credo --strict # Static analysis (strict mode)
mix dialyzer       # Type checking
mix docs           # Generate documentation
mix precommit      # Compile + format + credo + dialyzer
mix quality        # Format + credo + dialyzer
```

## Troubleshooting

### Emails not appearing in admin
- Verify `email_enabled` is `true` in settings
- Ensure the module is listed as a dependency in the parent app's `mix.exs`

### SES events not processing
- Verify `email_ses_events` is enabled in settings
- Check that `aws_ses_configuration_set` is configured
- Ensure SQS queue permissions allow the application to poll
- Review Oban dashboard for failed SQS polling jobs

### Metrics showing zero data
- Confirm emails are being logged (check `/admin/emails`)
- Verify the date range filter matches when emails were sent

## License

MIT — see [LICENSE](LICENSE.md) for details.

## Links

- [GitHub](https://github.com/BeamLabEU/phoenix_kit_emails)
- [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit)
