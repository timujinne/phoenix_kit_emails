defmodule PhoenixKitEmails.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_emails"

  def project do
    [
      app: :phoenix_kit_emails,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: "Email tracking, analytics, and AWS SES integration for PhoenixKit"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Core
      {:phoenix_kit, "~> 1.7", path: "/app"},
      {:phoenix_live_view, "~> 1.1"},
      {:oban, "~> 2.20"},
      {:uuidv7, "~> 1.0"},

      # AWS
      {:ex_aws, "~> 2.4"},
      {:ex_aws_sqs, "~> 3.4"},
      {:ex_aws_sns, "~> 2.3"},
      {:ex_aws_sts, "~> 2.3"},
      {:ex_aws_s3, "~> 2.4"},
      {:sweet_xml, "~> 0.7"},
      {:finch, "~> 0.18"},
      {:saxy, "~> 1.5"},

      # Utils
      {:jason, "~> 1.4"},
      {:hammer, "~> 7.1"},
      {:nimble_csv, "~> 1.2"},

      # Dev/test
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md)
    ]
  end
end
