defmodule Auth.MixProject do
  use Mix.Project

  # A standalone demo project. Run Mutare against it from the repo root:
  #
  #     mix mutare examples/auth
  #
  # It models sign-in policy (password strength + lockout) — the kind of
  # branch-heavy validation where suites tend to test the happy path and a
  # couple of obvious failures, leaving the boundaries for Mutare to find.
  def project do
    [
      app: :auth,
      version: "0.1.0",
      elixir: "~> 1.15"
    ]
  end

  def application, do: []
end
