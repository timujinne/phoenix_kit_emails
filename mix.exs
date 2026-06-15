defmodule PhoenixKitEmails.MixProject do
  use Mix.Project

  @version "0.1.6"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_emails"

  def project do
    [
      app: :phoenix_kit_emails,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      description: "Email tracking, analytics, and AWS SES integration for PhoenixKit",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [plt_add_apps: [:phoenix_kit, :mix]],
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :gettext]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  defp deps do
    [
      # Core
      {:phoenix_kit, "~> 1.7.106"},
      {:gettext, "~> 1.0"},
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
      files: ~w(lib priv mix.exs README.md LICENSE.md CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE.md"]
    ]
  end
end
