defmodule FzVpn.MixProject do
  use Mix.Project

  def version do
    # Use dummy version for dev and test
    System.get_env("VERSION", "0.0.0+git.0.deadbeef")
  end

  def project do
    [
      app: :fz_vpn,
      version: version(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {FzVpn.Application, []},
      registered: [:fz_vpn_server]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fz_http, in_umbrella: true},
      {:wireguardex, "~> 0.4.0"},
      # Build-time only: with WIREGUARDNIF_BUILD=1 (see kube/image/Dockerfile)
      # wireguardex compiles its NIF from source via rustler_precompiled, which
      # requires rustler to be loadable (its exact recipe, per its own error
      # message). Pinned 0.30 to match the rustler crate in wireguardex's
      # native Cargo.toml.
      {:rustler, "~> 0.30.0", runtime: false}
    ]
  end
end
