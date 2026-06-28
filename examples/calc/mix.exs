defmodule Calc.MixProject do
  use Mix.Project

  # The smallest possible demo project — one function, one well-known gap.
  # Run Mutare against it from the repo root:
  #
  #     mix mutare examples/calc
  #
  # Start here: the output is short enough to read top to bottom, and every
  # surviving mutant points at the same missing test.
  def project do
    [
      app: :calc,
      version: "0.1.0",
      elixir: "~> 1.18"
    ]
  end

  def application, do: []
end
