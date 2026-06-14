defmodule Toy.MixProject do
  use Mix.Project

  # A standalone demo project. Run Mutare against it from the repo root:
  #
  #     mix mutare examples/toy
  #
  # It deliberately has partial test coverage, so several mutants survive.
  def project do
    [
      app: :toy,
      version: "0.1.0",
      elixir: "~> 1.15"
    ]
  end

  def application, do: []
end
