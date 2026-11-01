defmodule FirezoneUmbrella.MixProject do
  @moduledoc """
  Welcome to the Firezone Elixir Umbrella Project
  """

  use Mix.Project

  def version do
    # Use dummy version for dev and test
    System.get_env("VERSION", "0.0.0+git.0.deadbeef")
  end

  def project do
    [
      name: :firezone,
      apps_path: "apps",
      version: version(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      docs: [
        logo: "apps/fz_http/assets/static/images/logo.svg",
        extras: ["README.md", "SECURITY.md", "CONTRIBUTING.md"]
      ],
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      aliases: aliases(),
      default_release: :firezone,
      releases: [
        firezone: [
          include_executables_for: [:unix],
          validate_compile_env: false,
          applications: [
            fz_http: :permanent,
            fz_wall: :permanent,
            fz_vpn: :permanent
          ],
          cookie: System.get_env("ERL_COOKIE")
        ]
      ]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      # Shared deps
      {:jason, "~> 1.2"},

      # Shared test deps
      {:excoveralls, "~> 0.14", only: :test},
      {:credo, "~> 1.6.0", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:junit_formatter, "~> 3.3", only: [:test]},

      # Formatter doesn't track dependencies of children applications
      {:phoenix, "~> 1.7.0"},
      {:phoenix_live_view, "~> 0.18.8"},

      # jose >= 1.11.11 requires OTP >= 26: jose_json_otp.erl specs use the
      # dynamic/0 type (OTP 26+); verified: 1.11.11 fails to compile on OTP 25
      # ("type dynamic() undefined"). 1.11.10 is the newest OTP-25-compatible
      # release (also has the CVE-2023-50966 fix).
      {:jose, "== 1.11.10"},
      # ecto >= 3.10 adds Ecto.Changeset.changed?/2, which clashes with
      # FzHttp.Validator.changed?/2 (ambiguous import in fz_http); keep
      # ecto_sql in the matching 3.9 line.
      {:ecto, ">= 3.9.2 and < 3.10.0"},
      {:ecto_sql, ">= 3.9.2 and < 3.10.0"},
      # phoenix_ecto > 4.4 makes parallel sandbox tests deadlock on
      # postgres (reproduced locally on 4.7 with db_connection 2.5 and 2.10).
      {:phoenix_ecto, "~> 4.4.0"},
      # finch >= 0.22 wraps transport errors in Finch.TransportError, which
      # breaks FzHttp.ConnectivityChecksTest on unchanged code.
      {:finch, "~> 0.21.0"},
      # swoosh >= 1.13 renamed "HTML body preview:" in the local mailbox
      # viewer, which apps/fz_http acceptance tests assert verbatim.
      {:swoosh, ">= 1.9.1 and < 1.13.0"}
    ]
  end

  defp aliases do
    [
      "ecto.seed": ["ecto.create", "ecto.migrate", "run apps/fz_http/priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"],
      start: ["compile --no-validate-compile-env", "phx.server", "run --no-halt"]
    ]
  end
end
