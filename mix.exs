defmodule PhoenixKitEmails.MixProject do
  use Mix.Project

  @version "0.5.0"
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
      dialyzer: [
        plt_add_apps: [:phoenix_kit, :mix],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ],
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
      {:hackney, "~> 4.0"},
      # 1.7.231 is the floor: that release ships `PhoenixKitWeb.Live.UrlState`,
      # which one LiveView here (web/blocklist.ex) `use`s. Anything below it
      # resolves a core with no such module, and `use` of a missing module is a
      # compile error — one that surfaces in the *consumer's* build, never here,
      # since this repo's own lockfile is always well above the floor. That is
      # what makes a stale floor invisible; do not lower this pin.
      #
      # Superseded requirements, kept so a future raise knows what it covers:
      # 1.7.217 for the optional `maybe_enqueue/2` provider callback the send
      # queue hangs off (Emails.Queue / Emails.SendJob) — below it the callback
      # is not in the behaviour, so `@impl` on the implementation warns and this
      # package's `--warnings-as-errors` precommit fails. 1.7.190 before that,
      # for email_settings_sections/0.
      #
      # All of the above floors are now historical: this module requires core
      # 2.x, which is well above every one of them. They are kept because they
      # record *which* core API each dependency rests on, which is what a future
      # raise needs to know.
      #
      # Keep this a TWO-segment `~> 2.0`. A three-segment `~> 2.0.x` expands to
      # `< 2.1.0` and would block resolution the moment core ships 2.1 —
      # stranding every host on old core until this module cuts a coordinated
      # release. That is the same failure the old `~> 1.7.231` pin had against
      # core 2.0.0, which is what PR #29 was opened to fix.
      # Floor raised to 2.21.3: that release renamed the website-wide
      # Integrations page from `/admin/settings/integrations/website` to
      # `/admin/settings/integrations`, which the Amazon SES section links to.
      # Below it the link is wrong rather than merely missing — 2.19.0 moved
      # the PERSONAL integrations page off `/admin/settings/integrations` to
      # `/profile/settings/integrations`, so on core < 2.19.0 that path opens
      # the per-user page instead, and on 2.19.0–2.21.2 it is unrouted.
      # Spelled as an explicit range, not `~> 2.21.3`: a three-segment `~>`
      # expands to `< 2.22.0` and would strand hosts the moment core ships
      # 2.22, which is the upper-bound trap the note above warns about.
      {:phoenix_kit, ">= 2.21.3 and < 3.0.0"},
      {:gettext, "~> 1.0"},
      {:phoenix_live_view, "~> 1.1"},
      {:oban, "~> 2.20"},
      {:uuidv7, "~> 1.0"},

      # AWS
      {:aws_regions, "~> 0.1.0"},
      {:ex_aws, "~> 2.4"},
      # Fork of the archived ex_aws_sqs, published as beamlab_ex_aws_sqs —
      # same public API (ExAws.SQS), switched to the SQS JSON protocol.
      # ex_aws_sqs (last released Jan 2023) pins `hackney ~> 1.9`, which
      # blocks the hackney 4.x upgrade needed to clear its CVE batch and
      # made `mix hex.audit` fail; this fork declares no hackney dependency
      # at all. Response shapes changed: raw JSON maps like
      # `%{"Messages" => [...]}` with string keys (e.g. "ReceiptHandle"),
      # not the old `%{body: %{messages: [...]}}` with atom keys. Matches
      # the switch already made in core (phoenix_kit).
      # v5.0.0 renamed the compiled OTP app back to `:ex_aws_sqs` (only the
      # Hex package name is `beamlab_ex_aws_sqs`) — depend on it via the
      # `hex:` override so it stays a drop-in for anything expecting
      # `:ex_aws_sqs` directly.
      {:ex_aws_sqs, "~> 5.0", hex: :beamlab_ex_aws_sqs},
      {:ex_aws_s3, "~> 2.4"},
      # Transitive requirement of ex_aws_s3 (parses S3's XML responses) — not
      # called directly here, declared explicitly since we do call
      # ExAws.S3.put_object (archiver.ex).
      {:sweet_xml, "~> 0.7"},

      # Utils
      # Our own code uses the built-in JSON module (Elixir 1.18+) directly —
      # kept as a direct dep because ex_aws hardcodes Jason as its default
      # :json_codec (ex_aws/lib/ex_aws/config/defaults.ex), so every S3/SQS
      # request still goes through it under the hood.
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
      # Tags in this repo are bare version numbers, not v-prefixed — a "v" ref
      # points at a tag that does not exist and 404s every HexDocs source link.
      source_ref: @version,
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE.md"]
    ]
  end
end
