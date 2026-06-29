defmodule Shop.MixProject do
  use Mix.Project

  # The "kitchen sink" demo — a small multi-module shop with no dependencies,
  # written to exercise *every* built-in Mutare mutator family across several
  # files, and shipped with a `.mutare.exs` that shows the config surface
  # (mutator selection, `# mutare:ignore`, and `macro_routes:` skips).
  #
  # Run it from the repo root:
  #
  #     mix mutare examples/shop
  def project do
    [
      app: :shop,
      version: "0.1.0",
      elixir: "~> 1.18"
    ]
  end

  def application, do: []
end
