defmodule Mutare.CLITest do
  use ExUnit.Case, async: true

  alias Mutare.CLI

  describe "plural/1" do
    test "is empty for exactly one, else \"s\"" do
      assert CLI.plural(1) == ""
      assert CLI.plural(0) == "s"
      assert CLI.plural(2) == "s"
    end
  end

  describe "truncate/2" do
    test "leaves short strings untouched" do
      assert CLI.truncate("hello", 80) == "hello"
    end

    test "clamps with an ellipsis" do
      assert CLI.truncate("hello world", 5) == "hell…"
    end
  end
end
