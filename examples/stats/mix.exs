defmodule Stats.MixProject do
  use Mix.Project

  # A standalone demo project. Run Mutare against it from the repo root:
  #
  #     mix mutare examples/stats
  #
  # It computes summary statistics over a list of numbers — code dense with
  # Enum/List calls, so it exercises the collection-shaped mutators (Collection,
  # CollectionArity, CallRemoval) and the empty/single-element boundaries they
  # love to expose.
  def project do
    [
      app: :stats,
      version: "0.1.0",
      elixir: "~> 1.15"
    ]
  end

  def application, do: []
end
