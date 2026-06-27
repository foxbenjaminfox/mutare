defmodule Mutare.OptionsTest do
  use ExUnit.Case, async: true

  alias Mutare.Options

  doctest Mutare.Options

  describe "new/1 defaults" do
    test "an empty keyword list resolves to documented defaults" do
      options = Options.new([])

      assert options.paths == ["lib"]
      assert options.exclude == []
      assert options.mutators == nil
      assert options.plugins == []
      assert options.only_files == nil
      assert options.test_selection == :coverage
      assert options.timeout == nil
      assert options.timeout_multiplier == 3.0
      assert options.harness_retries == 2
      assert options.max_harness_error_rate == 0.5
      assert options.sandbox == nil
      assert options.min_score == nil
      assert options.reporter == nil
    end

    test ":workers defaults to the scheduler count (a concrete positive integer)" do
      assert Options.new([]).workers == System.schedulers_online()
    end
  end

  describe "new/1 on an existing struct" do
    test "a valid existing struct normalizes to the same value" do
      options = Options.new(workers: 4, timeout: 1_000)
      assert Options.new(options) == options
    end

    test "revalidates and fills computed defaults instead of trusting a raw struct" do
      assert Options.new(%Options{}).workers == System.schedulers_online()

      assert_raise ArgumentError, ~r/:workers must be a positive integer/, fn ->
        Options.new(%Options{workers: 0})
      end
    end
  end

  describe "new/1 unknown keys" do
    test "rejects an unknown option" do
      error = assert_raise ArgumentError, fn -> Options.new(worker: 4) end
      assert Exception.message(error) =~ "unknown option(s) [:worker]"
    end
  end

  describe ":paths" do
    test "accepts a non-empty list of strings" do
      assert Options.new(paths: ["lib", "src"]).paths == ["lib", "src"]
    end

    test "rejects an empty list" do
      assert_raise ArgumentError, ~r/:paths must be a non-empty list/, fn ->
        Options.new(paths: [])
      end
    end

    test "rejects a non-list and non-string elements" do
      assert_raise ArgumentError, fn -> Options.new(paths: "lib") end
      assert_raise ArgumentError, fn -> Options.new(paths: [:lib]) end
    end
  end

  describe ":exclude" do
    test "accepts a list of strings" do
      assert Options.new(exclude: ["lib/gen/**"]).exclude == ["lib/gen/**"]
    end

    test "rejects non-string elements" do
      assert_raise ArgumentError, ~r/:exclude must be a list of strings/, fn ->
        Options.new(exclude: [~r/x/])
      end
    end
  end

  describe ":test_selection" do
    test "accepts :coverage and :full" do
      assert Options.new(test_selection: :coverage).test_selection == :coverage
      assert Options.new(test_selection: :full).test_selection == :full
    end

    test "rejects any other mode" do
      assert_raise ArgumentError, ~r/:test_selection must be :coverage or :full/, fn ->
        Options.new(test_selection: :partial)
      end
    end
  end

  describe ":keep_sandbox" do
    test "defaults to false" do
      assert Options.new([]).keep_sandbox == false
    end

    test "accepts true and false" do
      assert Options.new(keep_sandbox: true).keep_sandbox == true
      assert Options.new(keep_sandbox: false).keep_sandbox == false
    end

    test "rejects a non-boolean" do
      assert_raise ArgumentError, ~r/:keep_sandbox must be true or false/, fn ->
        Options.new(keep_sandbox: "yes")
      end
    end
  end

  describe ":seed_app_build" do
    test "defaults to true" do
      assert Options.new([]).seed_app_build == true
    end

    test "accepts true and false" do
      assert Options.new(seed_app_build: true).seed_app_build == true
      assert Options.new(seed_app_build: false).seed_app_build == false
    end

    test "rejects a non-boolean" do
      assert_raise ArgumentError, ~r/:seed_app_build must be true or false/, fn ->
        Options.new(seed_app_build: "no")
      end
    end
  end

  describe ":strict_ignores" do
    test "defaults to false" do
      assert Options.new([]).strict_ignores == false
    end

    test "accepts true and false" do
      assert Options.new(strict_ignores: true).strict_ignores == true
      assert Options.new(strict_ignores: false).strict_ignores == false
    end

    test "rejects a non-boolean" do
      assert_raise ArgumentError, ~r/:strict_ignores must be true or false/, fn ->
        Options.new(strict_ignores: "yes")
      end
    end
  end

  describe ":quiet" do
    test "defaults to false" do
      assert Options.new([]).quiet == false
    end

    test "accepts true and false" do
      assert Options.new(quiet: true).quiet == true
      assert Options.new(quiet: false).quiet == false
    end

    test "rejects a non-boolean" do
      assert_raise ArgumentError, ~r/:quiet must be true or false/, fn ->
        Options.new(quiet: "yes")
      end
    end
  end

  describe ":workers" do
    test "accepts a positive integer" do
      assert Options.new(workers: 8).workers == 8
    end

    test "rejects zero, negatives, and non-integers" do
      for bad <- [0, -1, 2.5, "4"] do
        assert_raise ArgumentError, ~r/:workers must be a positive integer/, fn ->
          Options.new(workers: bad)
        end
      end
    end

    test "an explicit nil falls back to the scheduler-count default" do
      assert Options.new(workers: nil).workers == System.schedulers_online()
    end
  end

  describe ":partition_env" do
    test "defaults to nil (off)" do
      assert Options.new([]).partition_env == nil
    end

    test "accepts a non-empty string (the env var name)" do
      assert Options.new(partition_env: "MIX_TEST_PARTITION").partition_env ==
               "MIX_TEST_PARTITION"
    end

    test "rejects an empty string and non-strings" do
      for bad <- ["", 1, :mix_test_partition, true] do
        assert_raise ArgumentError, ~r/:partition_env must be a non-empty string/, fn ->
          Options.new(partition_env: bad)
        end
      end
    end

    test "rejects a name Mutare itself reserves (would clobber the sandbox env)" do
      for reserved <- Mutare.Sandbox.Command.Invocation.reserved_env_names() do
        assert_raise ArgumentError,
                     ~r/:partition_env must not name a variable Mutare reserves/,
                     fn ->
                       Options.new(partition_env: reserved)
                     end
      end
    end
  end

  describe ":timeout" do
    test "accepts nil or a positive integer (ms)" do
      assert Options.new(timeout: nil).timeout == nil
      assert Options.new(timeout: 2_000).timeout == 2_000
    end

    test "rejects zero, negatives, and non-integers" do
      for bad <- [0, -5, 1.5, "2000"] do
        assert_raise ArgumentError, ~r/:timeout must be a positive integer/, fn ->
          Options.new(timeout: bad)
        end
      end
    end
  end

  describe ":timeout_multiplier" do
    test "accepts a positive number" do
      assert Options.new(timeout_multiplier: 2).timeout_multiplier == 2
      assert Options.new(timeout_multiplier: 1.5).timeout_multiplier == 1.5
    end

    test "rejects zero, negatives, and non-numbers" do
      for bad <- [0, -1.0, "3"] do
        assert_raise ArgumentError, ~r/:timeout_multiplier must be a positive number/, fn ->
          Options.new(timeout_multiplier: bad)
        end
      end
    end
  end

  describe ":harness_retries" do
    test "accepts a non-negative integer" do
      assert Options.new(harness_retries: 0).harness_retries == 0
      assert Options.new(harness_retries: 3).harness_retries == 3
    end

    test "rejects negatives and non-integers" do
      for bad <- [-1, 1.5, "2"] do
        assert_raise ArgumentError, ~r/:harness_retries must be a non-negative integer/, fn ->
          Options.new(harness_retries: bad)
        end
      end
    end
  end

  describe ":baseline_runs" do
    test "defaults to 1 and accepts a positive integer" do
      assert Options.new([]).baseline_runs == 1
      assert Options.new(baseline_runs: 1).baseline_runs == 1
      assert Options.new(baseline_runs: 3).baseline_runs == 3
    end

    test "rejects zero, negatives, and non-integers" do
      for bad <- [0, -1, 1.5, "2"] do
        assert_raise ArgumentError, ~r/:baseline_runs must be a positive integer/, fn ->
          Options.new(baseline_runs: bad)
        end
      end
    end
  end

  describe ":max_harness_error_rate" do
    test "accepts nil (disabled) or a number in 0.0..1.0" do
      assert Options.new(max_harness_error_rate: nil).max_harness_error_rate == nil
      assert Options.new(max_harness_error_rate: 0).max_harness_error_rate == 0
      assert Options.new(max_harness_error_rate: 0.3).max_harness_error_rate == 0.3
      assert Options.new(max_harness_error_rate: 1.0).max_harness_error_rate == 1.0
    end

    test "rejects out-of-range and non-numbers" do
      for bad <- [-0.1, 1.5, "0.5"] do
        assert_raise ArgumentError, ~r/:max_harness_error_rate must be a number/, fn ->
          Options.new(max_harness_error_rate: bad)
        end
      end
    end
  end

  describe ":sandbox" do
    test "accepts nil or a non-empty path string" do
      assert Options.new(sandbox: nil).sandbox == nil
      assert Options.new(sandbox: "/tmp/sb").sandbox == "/tmp/sb"
    end

    test "rejects an empty string or a non-string" do
      assert_raise ArgumentError, ~r/:sandbox must be a non-empty path string/, fn ->
        Options.new(sandbox: "")
      end

      assert_raise ArgumentError, fn -> Options.new(sandbox: :tmp) end
    end
  end

  describe ":max_mutants" do
    test "defaults to nil (no cap) and accepts a positive integer" do
      assert Options.new([]).max_mutants == nil
      assert Options.new(max_mutants: nil).max_mutants == nil
      assert Options.new(max_mutants: 50).max_mutants == 50
    end

    test "rejects zero, negatives, and non-integers" do
      for bad <- [0, -1, 1.5, "10"] do
        assert_raise ArgumentError, ~r/:max_mutants must be a positive integer or nil/, fn ->
          Options.new(max_mutants: bad)
        end
      end
    end
  end

  describe ":max_survivors" do
    test "defaults to nil (no cap) and accepts a positive integer" do
      assert Options.new([]).max_survivors == nil
      assert Options.new(max_survivors: nil).max_survivors == nil
      assert Options.new(max_survivors: 5).max_survivors == 5
    end

    test "rejects zero, negatives, and non-integers" do
      for bad <- [0, -1, 1.5, "10"] do
        assert_raise ArgumentError, ~r/:max_survivors must be a positive integer or nil/, fn ->
          Options.new(max_survivors: bad)
        end
      end
    end
  end

  describe ":min_score" do
    test "accepts nil or a number in 0..100" do
      assert Options.new(min_score: nil).min_score == nil
      assert Options.new(min_score: 0).min_score == 0
      assert Options.new(min_score: 70.0).min_score == 70.0
      assert Options.new(min_score: 100).min_score == 100
    end

    test "rejects out-of-range and non-numbers" do
      for bad <- [-1, 101, "70"] do
        assert_raise ArgumentError, ~r/:min_score must be a number between 0 and 100/, fn ->
          Options.new(min_score: bad)
        end
      end
    end
  end

  describe ":only_files" do
    test "accepts nil, a MapSet, or a list (normalised to a MapSet)" do
      assert Options.new(only_files: nil).only_files == nil

      set = MapSet.new(["lib/a.ex"])
      assert Options.new(only_files: set).only_files == set
      assert Options.new(only_files: ["lib/a.ex"]).only_files == set
    end

    test "rejects other shapes" do
      assert_raise ArgumentError, ~r/:only_files/, fn -> Options.new(only_files: "lib/a.ex") end
    end
  end

  describe ":only_lines" do
    test "accepts nil, a MapSet, or a list of {file, line} (normalised to a MapSet)" do
      assert Options.new(only_lines: nil).only_lines == nil

      set = MapSet.new([{"lib/a.ex", 42}])
      assert Options.new(only_lines: set).only_lines == set
      assert Options.new(only_lines: [{"lib/a.ex", 42}]).only_lines == set
    end

    test "rejects a non-list/non-MapSet shape" do
      assert_raise ArgumentError, ~r/:only_lines must be a MapSet/, fn ->
        Options.new(only_lines: "lib/a.ex:42")
      end
    end

    test "rejects entries that are not {path, positive integer}" do
      for bad <- [{"lib/a.ex", 0}, {"lib/a.ex", -1}, {"lib/a.ex", "42"}, {42, 1}, {"", 1}, :nope] do
        assert_raise ArgumentError, ~r/:only_lines entries must be/, fn ->
          Options.new(only_lines: [bad])
        end
      end
    end
  end

  describe ":mutators" do
    test "accepts nil (default set) or a list of modules, resolved to specs" do
      assert Options.new(mutators: nil).mutators == nil
      mods = [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]
      assert Options.new(mutators: mods).mutators |> Enum.map(& &1.module) == mods
    end

    test "resolves built-in family atoms via the catalog (direct API parity with the CLI)" do
      assert Options.new(mutators: [:relational, :arithmetic]).mutators |> Enum.map(& &1.module) ==
               [Mutare.Mutators.Relational, Mutare.Mutators.Arithmetic]
    end

    test "normalizes the bare default-set tokens to nil" do
      assert Options.new(mutators: :all).mutators == nil
      assert Options.new(mutators: :builtins).mutators == nil
    end

    test "accepts {module, opts} configured entries, carrying opts onto the spec" do
      assert Options.new(mutators: [{Mutare.Test.BooleanMutator, as: :strict, k: 1}]).mutators ==
               [
                 %Mutare.Mutator.Spec{
                   module: Mutare.Test.BooleanMutator,
                   name: :strict,
                   opts: [k: 1]
                 }
               ]
    end

    test "validates that supplied modules implement the behaviour" do
      assert_raise ArgumentError, ~r/implementing Mutare.Mutator/, fn ->
        Options.new(mutators: [Enum])
      end
    end

    test "rejects an unknown family atom" do
      assert_raise ArgumentError, ~r/unknown mutator :bogus/, fn ->
        Options.new(mutators: [:bogus])
      end
    end

    test "rejects a non-list or non-atom elements" do
      assert_raise ArgumentError, ~r/:mutators must be :all, :builtins, nil, or a list/, fn ->
        Options.new(mutators: :arithmetic)
      end

      assert_raise ArgumentError, fn -> Options.new(mutators: ["Arithmetic"]) end
    end
  end

  describe ":macros" do
    test "defaults to an empty list" do
      assert Options.new([]).macros == []
    end

    test "resolves declarative entries to Macro.Specs (no reflection on the module)" do
      assert Options.new(macros: [{Ecto.Query, :from, :any, :skip}]).macros ==
               [
                 %Mutare.Macro.Spec{
                   module: [:Ecto, :Query],
                   name: :from,
                   arity: :any,
                   args: :skip
                 }
               ]
    end

    test "rejects a non-list" do
      assert_raise ArgumentError, ~r/:macros must be a list/, fn ->
        Options.new(macros: :nope)
      end
    end

    test "rejects a malformed entry" do
      assert_raise ArgumentError, fn -> Options.new(macros: [{Kernel, :match?}]) end
    end
  end

  describe ":reporters" do
    test "defaults to the human reporter on stdout" do
      assert Options.new([]).reporters == [{:human, nil}]
    end

    test "accepts a list of {format, path | nil} tuples" do
      reporters = [{:human, nil}, {:json, "out.json"}, {:sarif, nil}]
      assert Options.new(reporters: reporters).reporters == reporters
    end

    test "normalizes bare format atoms to stdout entries" do
      assert Options.new(reporters: [:human, :json]).reporters == [
               {:human, nil},
               {:json, nil}
             ]
    end

    test "rejects an unknown format" do
      assert_raise ArgumentError, ~r/format in/, fn ->
        Options.new(reporters: [{:xml, "out.xml"}])
      end
    end

    test "rejects malformed entries" do
      # an unknown bare format
      assert_raise ArgumentError, fn -> Options.new(reporters: [:xml]) end
      # an empty path string
      assert_raise ArgumentError, fn -> Options.new(reporters: [{:json, ""}]) end
      # not a list at all
      assert_raise ArgumentError, ~r/:reporters must be a list/, fn ->
        Options.new(reporters: "json")
      end
    end
  end

  describe ":reporter" do
    test "accepts nil or a 1-arity function" do
      assert Options.new(reporter: nil).reporter == nil
      fun = fn _result -> :ok end
      assert Options.new(reporter: fun).reporter == fun
    end

    test "rejects a non-function or a wrong arity" do
      assert_raise ArgumentError, ~r/:reporter must be a 1-arity function/, fn ->
        Options.new(reporter: fn -> :ok end)
      end

      assert_raise ArgumentError, fn -> Options.new(reporter: :nope) end
    end
  end

  describe ":on_phase / :on_start" do
    test "default to nil" do
      options = Options.new([])
      assert options.on_phase == nil
      assert options.on_start == nil
    end

    test "accept nil or a 1-arity function" do
      phase = fn _phase -> :ok end
      start = fn _site -> :ok end
      options = Options.new(on_phase: phase, on_start: start)
      assert options.on_phase == phase
      assert options.on_start == start
      assert Options.new(on_phase: nil, on_start: nil).on_phase == nil
    end

    test "reject a non-function or a wrong arity" do
      assert_raise ArgumentError, ~r/:on_phase must be a 1-arity function/, fn ->
        Options.new(on_phase: fn -> :ok end)
      end

      assert_raise ArgumentError, ~r/:on_start must be a 1-arity function/, fn ->
        Options.new(on_start: :nope)
      end
    end
  end

  describe ":plugins" do
    test "defaults to an empty list and resolves plugin modules to specs" do
      assert Options.new([]).plugins == []

      assert Options.new(plugins: [Mutare.Test.GettextLikePlugin]).plugins ==
               [%Mutare.Plugin.Spec{module: Mutare.Test.GettextLikePlugin, opts: []}]
    end

    test "accepts a {module, opts} entry, carrying the opts onto the spec" do
      assert Options.new(plugins: [{Mutare.Test.GettextLikePlugin, [domain: "errors"]}]).plugins ==
               [
                 %Mutare.Plugin.Spec{
                   module: Mutare.Test.GettextLikePlugin,
                   opts: [domain: "errors"]
                 }
               ]
    end

    test "rejects a module that does not implement Mutare.Plugin" do
      assert_raise ArgumentError, ~r/:plugins entries must be loaded modules/, fn ->
        Options.new(plugins: [Enum])
      end
    end

    test "rejects a malformed entry (bad opts shape)" do
      # The entry-shape dispatch is single-homed in `Mutare.Plugin.Spec.new/1`, so a non-keyword
      # opts surfaces its message.
      assert_raise ArgumentError,
                   ~r/invalid plugin entry: expected a module or a \{module, opts\} pair/,
                   fn -> Options.new(plugins: [{Mutare.Test.GettextLikePlugin, :not_kw}]) end
    end

    test "rejects a hand-built spec with non-keyword opts (opts re-checked at the boundary)" do
      assert_raise ArgumentError, ~r/:plugins entry opts must be a keyword list/, fn ->
        Options.new(
          plugins: [%Mutare.Plugin.Spec{module: Mutare.Test.GettextLikePlugin, opts: :garbage}]
        )
      end
    end

    test "rejects a {module, opts} entry whose opts is a non-keyword list" do
      # `is_list/1` would accept `[:a, :b]` and silently treat it as empty opts; `Keyword.keyword?`
      # rejects it loudly with the keyword-list message.
      assert_raise ArgumentError, ~r/:plugins entry opts must be a keyword list/, fn ->
        Options.new(plugins: [{Mutare.Test.GettextLikePlugin, [:a, :b]}])
      end
    end

    test "rejects a mutator listed under :plugins, even one exporting macros/0" do
      # A macro-aware mutator exports `macros/0`, but it is a `Mutare.Mutator`, not a plugin —
      # listing it here would merge its routing yet never run its mutations, so it fails loudly.
      assert_raise ArgumentError, ~r/:plugins entries must be loaded modules/, fn ->
        Options.new(plugins: [Mutare.Test.QueryMutator])
      end
    end

    test "coerces an explicit nil to an empty list (like :macros)" do
      assert Options.new(plugins: nil).plugins == []
    end

    test "rejects a non-list" do
      assert_raise ArgumentError, ~r/:plugins must be a list/, fn ->
        Options.new(plugins: Mutare.Test.GettextLikePlugin)
      end
    end
  end
end
