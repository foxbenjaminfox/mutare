defmodule Mutare.ConfigTest do
  use ExUnit.Case, async: true

  alias Mutare.Config
  alias Mutare.Mutators.{Arithmetic, Relational}

  describe "load/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "mutare_cfg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "returns [] when there is no .mutare.exs", %{root: root} do
      assert Config.load(root) == []
    end

    test "evaluates the keyword list in .mutare.exs", %{root: root} do
      File.write!(Path.join(root, ".mutare.exs"), ~s([paths: ["lib"], min_score: 70]))
      assert Config.load(root) == [paths: ["lib"], min_score: 70]
    end
  end

  describe "merge/2" do
    test "no file config and no flags resolves to empty (mutators key omitted)" do
      assert Config.merge([], []) == []
    end

    test "--only becomes :paths" do
      assert Config.merge([], only: "lib/billing")[:paths] == ["lib/billing"]
    end

    test "--mutators resolves a CSV to modules, preserving order" do
      assert Config.merge([], mutators: "relational,arithmetic")[:mutators] ==
               [Relational, Arithmetic]
    end

    test "--min-score and --sandbox pass through" do
      merged = Config.merge([], min_score: 70.0, sandbox: "/tmp/sb")
      assert merged[:min_score] == 70.0
      assert merged[:sandbox] == "/tmp/sb"
    end

    test "--full sets test_selection: :full; otherwise it's left to default" do
      assert Config.merge([], full: true)[:test_selection] == :full
      refute Keyword.has_key?(Config.merge([], []), :test_selection)
      # file config still flows through
      assert Config.merge([test_selection: :full], [])[:test_selection] == :full
    end

    test "file config mutators: :all resolves to the default set (key omitted)" do
      refute Keyword.has_key?(Config.merge([mutators: :all], []), :mutators)
    end

    test "file config mutators list resolves to modules" do
      assert Config.merge([mutators: [:relational]], [])[:mutators] == [Relational]
    end

    test "CLI flags win over file config" do
      assert Config.merge([paths: ["lib"]], only: "lib/only")[:paths] == ["lib/only"]
      assert Config.merge([min_score: 50], min_score: 90.0)[:min_score] == 90.0
    end
  end

  describe "mutator_modules/1" do
    test "maps known families to modules" do
      assert Config.mutator_modules([:arithmetic, :relational]) == [Arithmetic, Relational]
    end

    test "accepts a custom module implementing the behaviour, mixed with families" do
      assert Config.mutator_modules([:arithmetic, Mutare.Test.BooleanMutator]) ==
               [Arithmetic, Mutare.Test.BooleanMutator]
    end

    test "raises on an unknown family, listing the known ones" do
      error = assert_raise ArgumentError, fn -> Config.mutator_modules([:bogus_family]) end
      message = Exception.message(error)
      assert message =~ "unknown mutator :bogus_family"
      assert message =~ "arithmetic"
      assert message =~ "relational"
    end

    test "raises on a module that does not implement the behaviour" do
      error = assert_raise ArgumentError, fn -> Config.mutator_modules([Enum]) end
      assert Exception.message(error) =~ "implementing Mutare.Mutator"
      assert Exception.message(error) =~ "missing mutate/1"
    end
  end
end
