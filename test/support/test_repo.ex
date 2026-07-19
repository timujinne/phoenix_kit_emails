defmodule PhoenixKitEmails.Test.Repo do
  use Ecto.Repo,
    otp_app: :phoenix_kit_emails,
    adapter: Ecto.Adapters.Postgres
end
