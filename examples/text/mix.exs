defmodule Text.MixProject do
  use Mix.Project

  # A standalone demo project. Run Mutare against it from the repo root:
  #
  #     mix mutare examples/text
  #
  # Small text-formatting helpers — slugs, word counts, excerpts. Built around
  # String/Regex literals, so it exercises the StringCall, RegexLiteral and
  # StringLiteral mutators alongside the off-by-one boundary in truncation.
  def project do
    [
      app: :text,
      version: "0.1.0",
      elixir: "~> 1.15"
    ]
  end

  def application, do: []
end
