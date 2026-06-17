defmodule Mutare.MixProject do
  use Mix.Project

  def project do
    [
      app: :mutare,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:sourceror, "~> 1.12"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp dialyzer do
    [
      # Keep the PLTs in a stable, cacheable location (e.g. for CI).
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit],
      # High-signal spec-accuracy checks on top of the defaults. `:unmatched_returns`
      # is intentionally left off: it fights idiomatic fire-and-forget side-effect
      # calls (File.rm/1, etc.) with no genuine bugs to show for it here.
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end
end
