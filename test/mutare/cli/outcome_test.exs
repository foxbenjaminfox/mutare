defmodule Mutare.CLI.OutcomeTest do
  use ExUnit.Case, async: true

  alias Mutare.CLI.Outcome
  alias Mutare.Options

  describe "scope/2" do
    test "is nil for a run over the whole project" do
      assert Outcome.scope([min_score: 80], Options.new([])) == nil
    end

    test "names each scoping flag as written, in a fixed order" do
      flags = [line: "lib/a.ex:3", only: "lib/a", since: "main", exclude: "lib/a/gen_*.ex"]

      assert Outcome.scope(flags, Options.new(max_mutants: 50)) ==
               "--since main --only lib/a --exclude lib/a/gen_*.ex --line lib/a.ex:3 " <>
                 "--max-mutants 50"
    end

    test "counts a repeatable flag's values past the third" do
      flags = for line <- 1..5, do: {:line, "lib/a.ex:#{line}"}

      assert Outcome.scope(flags, Options.new([])) ==
               "--line lib/a.ex:1 --line lib/a.ex:2 --line lib/a.ex:3 (+2 more --line)"
    end
  end
end
