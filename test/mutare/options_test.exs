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
      assert options.extensions == []
      assert options.only_files == nil
      assert options.test_selection == :tests
      assert options.timeout == nil
      assert options.timeout_multiplier == 3.0
      assert options.baseline_retries == 0
      assert options.harness_retries == 2
      assert options.max_harness_error_rate == 0.5
      assert options.sandbox == nil
      assert options.min_score == nil
      assert options.max_no_coverage == nil
      assert options.fail_on_poisoned == false
      assert options.fail_on_harness_error == false
    end

    test ":workers defaults to half the scheduler count clamped to 1..4 (a concrete positive integer)" do
      assert Options.new([]).workers ==
               System.schedulers_online() |> div(2) |> min(4) |> max(1)
    end
  end

  describe "new/1 on an existing struct" do
    test "a valid existing struct normalizes to the same value" do
      options = Options.new(workers: 4, timeout: 1_000)
      assert Options.new(options) == options
    end

    test "revalidates and fills computed defaults instead of trusting a raw struct" do
      assert Options.new(%Options{}).workers ==
               System.schedulers_online() |> div(2) |> min(4) |> max(1)

      assert_raise ArgumentError, ~r/:workers must be a positive integer/, fn ->
        Options.new(%Options{workers: 0})
      end
    end
  end

  describe "new/1 input shape" do
    test "rejects non-list, non-Options input at the public boundary" do
      error = assert_raise FunctionClauseError, fn -> Options.new(:not_options) end
      assert Exception.message(error) =~ "Mutare.Options."
    end
  end

  describe "new/1 unknown keys" do
    test "rejects an unknown option" do
      error = assert_raise ArgumentError, fn -> Options.new(worker: 4) end
      assert Exception.message(error) =~ "unknown option(s) [:worker]"
    end

    test "deduplicates unknown options before rendering the error" do
      error = assert_raise ArgumentError, fn -> Options.new(worker: 4, worker: 8) end
      assert Exception.message(error) =~ "unknown option(s) [:worker];"
    end
  end

  describe "formats" do
    test "maps every valid output format to its renderer module" do
      assert Enum.map(Options.formats(), &{&1, Options.renderer(&1)}) == [
               human: Mutare.Report,
               json: Mutare.Report.Json,
               html: Mutare.Report.Html,
               sarif: Mutare.Report.Sarif
             ]
    end

    test "raises for an unknown renderer format" do
      assert_raise KeyError, fn -> Options.renderer(:xml) end
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

    test "rejects a mixed list even when at least one entry is a valid path string" do
      assert_raise ArgumentError, ~r/:paths must be a non-empty list of path strings/, fn ->
        Options.new(paths: ["lib", :src])
      end
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
    test "accepts :tests, :coverage, and :full" do
      assert Options.new(test_selection: :tests).test_selection == :tests
      assert Options.new(test_selection: :coverage).test_selection == :coverage
      assert Options.new(test_selection: :full).test_selection == :full
    end

    test "rejects any other mode" do
      assert_raise ArgumentError, ~r/:test_selection must be :tests, :coverage, or :full/, fn ->
        Options.new(test_selection: :partial)
      end
    end
  end

  describe ":expand_uses" do
    test "accepts true and false" do
      assert Options.new(expand_uses: true).expand_uses == true
      assert Options.new(expand_uses: false).expand_uses == false
    end

    test "rejects a non-boolean with the option name in the message" do
      assert_raise ArgumentError, ":expand_uses must be true or false, got: :yes", fn ->
        Options.new(expand_uses: :yes)
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

  describe ":verbose" do
    test "defaults to false" do
      assert Options.new([]).verbose == false
    end

    test "accepts true and false" do
      assert Options.new(verbose: true).verbose == true
      assert Options.new(verbose: false).verbose == false
    end

    test "rejects a non-boolean" do
      assert_raise ArgumentError, ~r/:verbose must be true or false/, fn ->
        Options.new(verbose: "loud")
      end
    end
  end

  describe ":workers" do
    test "accepts one worker" do
      assert Options.new(workers: 1).workers == 1
    end

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

    test "an explicit nil falls back to the clamped half-the-schedulers default" do
      assert Options.new(workers: nil).workers ==
               System.schedulers_online() |> div(2) |> min(4) |> max(1)
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

    test "rejects a name that is not valid env var syntax" do
      # `=` and NUL make `System.cmd(env: ...)` raise; the rest are unreadable by any
      # shell or `System.get_env`. All must fail at option construction, not mid-run.
      for bad <- ["A=B", "A\0B", "MY SLOT", "1SLOT", "MY-SLOT", "MY.SLOT", "SLÖT"] do
        assert_raise ArgumentError,
                     ~r/:partition_env must be a valid environment variable name/,
                     fn -> Options.new(partition_env: bad) end
      end
    end

    test "accepts underscored and digit-suffixed names" do
      for good <- ["_SLOT", "MY_SLOT_2", "s"] do
        assert Options.new(partition_env: good).partition_env == good
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

    test "reserved-name errors list every reserved env var with comma separators" do
      reserved = List.first(Mutare.Sandbox.Command.Invocation.reserved_env_names())

      message =
        ":partition_env must not name a variable Mutare reserves " <>
          "(#{Enum.join(Mutare.Sandbox.Command.Invocation.reserved_env_names(), ", ")}), " <>
          "got: #{inspect(reserved)}"

      assert_raise ArgumentError, message, fn ->
        Options.new(partition_env: reserved)
      end
    end
  end

  describe ":timeout" do
    test "accepts nil or a positive integer (ms)" do
      assert Options.new(timeout: nil).timeout == nil
      assert Options.new(timeout: 1).timeout == 1
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

  describe ":compile_timeout" do
    test "defaults to 30 minutes and accepts nil (uncapped) or a positive integer (ms)" do
      assert Options.new([]).compile_timeout == 1_800_000
      assert Options.new(compile_timeout: nil).compile_timeout == nil
      assert Options.new(compile_timeout: 60_000).compile_timeout == 60_000
    end

    test "rejects zero, negatives, and non-integers" do
      for bad <- [0, -5, 1.5, "60000"] do
        assert_raise ArgumentError, ~r/:compile_timeout must be a positive integer/, fn ->
          Options.new(compile_timeout: bad)
        end
      end
    end
  end

  describe ":probe_timeout" do
    test "defaults to nil (derived from the per-mutant cap) and accepts a positive integer (ms)" do
      assert Options.new([]).probe_timeout == nil
      assert Options.new(probe_timeout: 600_000).probe_timeout == 600_000
      assert Options.new(probe_timeout: nil).probe_timeout == nil
    end

    test "rejects zero, negatives, and non-integers" do
      for bad <- [0, -5, 1.5, "600000"] do
        assert_raise ArgumentError, ~r/:probe_timeout must be a positive integer/, fn ->
          Options.new(probe_timeout: bad)
        end
      end
    end
  end

  describe ":max_heap_mb" do
    test "defaults to nil (no memory cap) and accepts a positive integer (MB)" do
      assert Options.new([]).max_heap_mb == nil
      assert Options.new(max_heap_mb: 4096).max_heap_mb == 4096
      assert Options.new(max_heap_mb: nil).max_heap_mb == nil
    end

    test "rejects zero, negatives, and non-integers" do
      for bad <- [0, -5, 1.5, "4096"] do
        assert_raise ArgumentError, ~r/:max_heap_mb must be a positive integer/, fn ->
          Options.new(max_heap_mb: bad)
        end
      end
    end
  end

  describe ":timeout_multiplier" do
    test "accepts a positive number" do
      assert Options.new(timeout_multiplier: 0.5).timeout_multiplier == 0.5
      assert Options.new(timeout_multiplier: 1).timeout_multiplier == 1
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

  describe ":baseline_retries" do
    test "defaults to 0 and accepts a non-negative integer" do
      assert Options.new([]).baseline_retries == 0
      assert Options.new(baseline_retries: 0).baseline_retries == 0
      assert Options.new(baseline_retries: 3).baseline_retries == 3
    end

    test "rejects negatives and non-integers" do
      for bad <- [-1, 1.5, "2"] do
        assert_raise ArgumentError, ~r/:baseline_retries must be a non-negative integer/, fn ->
          Options.new(baseline_retries: bad)
        end
      end
    end
  end

  describe ":kill_runs" do
    test "defaults to 1 and accepts a positive integer" do
      assert Options.new([]).kill_runs == 1
      assert Options.new(kill_runs: 1).kill_runs == 1
      assert Options.new(kill_runs: 3).kill_runs == 3
    end

    test "rejects zero, negatives, and non-integers" do
      for bad <- [0, -1, 1.5, "2"] do
        assert_raise ArgumentError, ~r/:kill_runs must be a positive integer/, fn ->
          Options.new(kill_runs: bad)
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
      assert Options.new(max_mutants: 1).max_mutants == 1
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
      assert Options.new(max_survivors: 1).max_survivors == 1
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

  describe ":time_budget" do
    test "defaults to nil (no budget) and accepts a duration string, stored verbatim" do
      assert Options.new([]).time_budget == nil
      assert Options.new(time_budget: nil).time_budget == nil
      assert Options.new(time_budget: "10m").time_budget == "10m"
      assert Options.new(time_budget: "1h30m").time_budget == "1h30m"
    end

    test "re-validating an existing struct is idempotent (the stored string re-parses)" do
      opts = Options.new(time_budget: "90s")
      assert Options.new(opts) == opts
    end

    test "rejects a bare number (string or integer) — the unit is ambiguous" do
      assert_raise ArgumentError, ~r/:time_budget/, fn -> Options.new(time_budget: "600") end
      assert_raise ArgumentError, ~r/:time_budget/, fn -> Options.new(time_budget: 600) end
    end

    test "rejects malformed duration strings" do
      for bad <- ["", "30s10m", "10d", "10M", " 10m", "10m\n", "0s"] do
        assert_raise ArgumentError, ~r/:time_budget/, fn ->
          Options.new(time_budget: bad)
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

  describe ":max_no_coverage" do
    test "accepts nil or a non-negative integer" do
      assert Options.new(max_no_coverage: nil).max_no_coverage == nil
      assert Options.new(max_no_coverage: 0).max_no_coverage == 0
      assert Options.new(max_no_coverage: 3).max_no_coverage == 3
    end

    test "rejects negatives and non-integers" do
      for bad <- [-1, 1.5, "0"] do
        assert_raise ArgumentError,
                     ~r/:max_no_coverage must be a non-negative integer or nil/,
                     fn ->
                       Options.new(max_no_coverage: bad)
                     end
      end
    end
  end

  describe "non-score CI gate booleans" do
    test "accept true and false" do
      assert Options.new(fail_on_poisoned: true).fail_on_poisoned == true
      assert Options.new(fail_on_poisoned: false).fail_on_poisoned == false
      assert Options.new(fail_on_harness_error: true).fail_on_harness_error == true
      assert Options.new(fail_on_harness_error: false).fail_on_harness_error == false
    end

    test "reject non-booleans" do
      assert_raise ArgumentError, ~r/:fail_on_poisoned must be true or false/, fn ->
        Options.new(fail_on_poisoned: "yes")
      end

      assert_raise ArgumentError, ~r/:fail_on_harness_error must be true or false/, fn ->
        Options.new(fail_on_harness_error: "yes")
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

    test "entry errors state both path and line requirements in order" do
      assert_raise ArgumentError,
                   ":only_lines entries must be {file, line} with a non-empty path string and a " <>
                     "positive integer line, got: {\"lib/a.ex\", 0}",
                   fn ->
                     Options.new(only_lines: [{"lib/a.ex", 0}])
                   end
    end
  end

  describe ":mutators" do
    test "uses the default set when :mutators is omitted, or resolves a list of modules to specs" do
      assert Options.new([]).mutators == nil
      mods = [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]
      assert Options.new(mutators: mods).mutators |> Enum.map(& &1.module) == mods
    end

    test "resolves built-in family atoms via the catalog (direct API parity with the CLI)" do
      assert Options.new(mutators: [:relational, :arithmetic]).mutators |> Enum.map(& &1.module) ==
               [Mutare.Mutators.Relational, Mutare.Mutators.Arithmetic]
    end

    test "rejects bare default-set tokens" do
      assert_raise ArgumentError, ~r/:mutators must be omitted or set to a list/, fn ->
        Options.new(mutators: :builtins)
      end

      assert_raise ArgumentError, ~r/:mutators must be omitted or set to a list/, fn ->
        Options.new(mutators: :all)
      end
    end

    test "rejects explicit nil; omitting the key is the default-set sentinel" do
      assert_raise ArgumentError,
                   ":mutators must be omitted or set to a list of mutators, got: nil",
                   fn ->
                     Options.new(mutators: nil)
                   end
    end

    test "revalidates malformed mutators on an existing struct through the registry validator" do
      assert_raise ArgumentError,
                   ":mutators must be omitted or set to a list of mutators, got: :builtins",
                   fn ->
                     Options.new(%Options{mutators: :builtins})
                   end
    end

    test "accepts {module, opts} configured entries, carrying opts onto the spec" do
      assert Options.new(mutators: [{Mutare.Test.AndOrMutator, as: :strict, k: 1}]).mutators ==
               [
                 %Mutare.Mutator.Spec{
                   module: Mutare.Test.AndOrMutator,
                   name: :strict,
                   opts: [k: 1],
                   config: [k: 1]
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
      assert_raise ArgumentError, ~r/:mutators must be omitted or set to a list/, fn ->
        Options.new(mutators: :arithmetic)
      end

      assert_raise ArgumentError, fn -> Options.new(mutators: ["Arithmetic"]) end
    end
  end

  describe ":call_routes" do
    test "defaults to an empty list" do
      assert Options.new([]).call_routes == []
    end

    test "coerces an explicit nil to an empty route list" do
      assert Options.new(call_routes: nil).call_routes == []
    end

    test "resolves declarative entries to Macro.Specs (no reflection on the module)" do
      assert Options.new(call_routes: [{Ecto.Query, :from, :any, :raw}]).call_routes ==
               [
                 %Mutare.CallRouting.Spec{
                   module: [:Ecto, :Query],
                   name: :from,
                   arity: :any,
                   args: :raw
                 }
               ]
    end

    test "rejects a non-list" do
      assert_raise ArgumentError,
                   ":call_routes must be a list of route entries, got: :nope",
                   fn ->
                     Options.new(call_routes: :nope)
                   end
    end

    test "rejects a malformed entry" do
      assert_raise ArgumentError, fn -> Options.new(call_routes: [{Kernel, :match?}]) end
    end
  end

  describe ":skip_lifting" do
    test "defaults to an empty MapSet" do
      assert Options.new([]).skip_lifting == MapSet.new()
    end

    test "accepts nil, a MapSet, or a list of {module, function, arity}" do
      expected = MapSet.new([{Mutare.Test.SkipLiftFixture, "new", 4}])

      assert Options.new(skip_lifting: nil).skip_lifting == MapSet.new()
      assert Options.new(skip_lifting: expected).skip_lifting == expected

      assert Options.new(skip_lifting: [{Mutare.Test.SkipLiftFixture, :new, 4}]).skip_lifting ==
               expected

      assert Options.new(skip_lifting: [{Mutare.Test.SkipLiftFixture, "new", 4}]).skip_lifting ==
               expected
    end

    test "rejects malformed entries" do
      for bad <- [
            {"Mutare.Test.SkipLiftFixture", :new, 4},
            {Mutare.Test.SkipLiftFixture, :New, 4},
            {Mutare.Test.SkipLiftFixture, :new, -1},
            {Mutare.Test.SkipLiftFixture, :new, "4"},
            {Mutare.Test.SkipLiftFixture, :new},
            :nope
          ] do
        assert_raise ArgumentError, ~r/:skip_lifting entries must be/, fn ->
          Options.new(skip_lifting: [bad])
        end
      end
    end

    test "rejects a non-list/non-MapSet shape" do
      assert_raise ArgumentError, ~r/:skip_lifting must be a list or MapSet/, fn ->
        Options.new(skip_lifting: "Mutare.Test.SkipLiftFixture.new/4")
      end
    end
  end

  describe ":reporters" do
    test "defaults to the human reporter on stdout" do
      assert Options.new([]).reporters == [{:human, nil}]
    end

    test "accepts a list of {format, path | nil} tuples" do
      reporters = [{:human, nil}, {:json, "out.json"}, {:sarif, "out.sarif"}]
      assert Options.new(reporters: reporters).reporters == reporters
    end

    test "normalizes a bare format atom to a stdout entry" do
      assert Options.new(reporters: [:json]).reporters == [{:json, nil}]
    end

    test "normalizes a bare format atom alongside file entries" do
      assert Options.new(reporters: [:human, {:json, "out.json"}]).reporters == [
               {:human, nil},
               {:json, "out.json"}
             ]
    end

    test "rejects a second reporter on stdout" do
      # Two whole documents concatenated on one stream is neither format — the
      # case behind `--report json --report sarif`.
      assert_raise ArgumentError,
                   ~r/may name each destination only once, but stdout is claimed by json and sarif/,
                   fn -> Options.new(reporters: [{:json, nil}, {:sarif, nil}]) end
    end

    test "rejects the human report sharing stdout with a machine format" do
      assert_raise ArgumentError, ~r/stdout is claimed by human and json/, fn ->
        Options.new(reporters: [:human, :json])
      end
    end

    test "rejects two reporters writing to the same path" do
      assert_raise ArgumentError,
                   ~r/"out.txt" is claimed by json and sarif — only the last one written/,
                   fn -> Options.new(reporters: [{:json, "out.txt"}, {:sarif, "out.txt"}]) end
    end

    test "rejects two reporters whose paths differ only in spelling" do
      # `File.write!` resolves both to one file, so the raw strings differing is no
      # protection — the later report would silently overwrite the earlier one.
      assert_raise ArgumentError,
                   ~r/"out.txt" is claimed by json and sarif — only the last one written/,
                   fn -> Options.new(reporters: [{:json, "out.txt"}, {:sarif, "./out.txt"}]) end

      assert_raise ArgumentError, ~r/claimed by json and sarif/, fn ->
        Options.new(reporters: [{:json, "out.txt"}, {:sarif, "nested/../out.txt"}])
      end
    end

    test "allows file reporters that resolve to distinct paths" do
      reporters = [{:json, "out.txt"}, {:sarif, "nested/out.txt"}]
      assert Options.new(reporters: reporters).reporters == reporters
    end

    test "allows one stdout reporter alongside distinct file reporters" do
      reporters = [{:json, nil}, {:sarif, "out.sarif"}, {:html, "out.html"}]
      assert Options.new(reporters: reporters).reporters == reporters
    end

    test "collision errors name every colliding entry and the remediation" do
      assert_raise ArgumentError,
                   ":reporters may name each destination only once, but stdout is claimed by " <>
                     "human and json and sarif — the concatenated output is valid in none of " <>
                     "them. Give all but one an output path (e.g. `--report json:mutare.json`), " <>
                     "got: [human: nil, json: nil, sarif: nil]",
                   fn -> Options.new(reporters: [:human, :json, :sarif]) end
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

    test "non-list errors include the complete expected shape" do
      assert_raise ArgumentError,
                   ":reporters must be a list of format atoms or {format, path | nil} tuples, " <>
                     "got: \"json\"",
                   fn ->
                     Options.new(reporters: "json")
                   end
    end

    test "bad entry errors include the valid format set before the bad entry" do
      assert_raise ArgumentError,
                   ":reporters entries must be a format atom or {format, path | nil} with format in " <>
                     "[:human, :json, :html, :sarif], got: {:xml, \"out.xml\"}",
                   fn ->
                     Options.new(reporters: [{:xml, "out.xml"}])
                   end
    end
  end

  describe "context keys are not options" do
    test "the runtime-wiring keys are rejected as unknown options (they live on Run.Context)" do
      for key <- [:project, :reporter, :on_phase, :on_start, :on_scan] do
        assert_raise ArgumentError, ~r/unknown option/, fn ->
          Options.new([{key, fn _ -> :ok end}])
        end
      end
    end
  end

  describe ":extensions" do
    test "defaults to an empty list and resolves extension modules to specs" do
      assert Options.new([]).extensions == []

      assert Options.new(extensions: [Mutare.Test.GettextLikeExtension]).extensions ==
               [%Mutare.Extension.Spec{module: Mutare.Test.GettextLikeExtension, opts: []}]
    end

    test "accepts a {module, opts} entry, carrying the opts onto the spec" do
      assert Options.new(extensions: [{Mutare.Test.GettextLikeExtension, [domain: "errors"]}]).extensions ==
               [
                 %Mutare.Extension.Spec{
                   module: Mutare.Test.GettextLikeExtension,
                   opts: [domain: "errors"]
                 }
               ]
    end

    test "rejects a module that implements neither extension capability" do
      assert_raise ArgumentError,
                   ~r/:extensions entries must be loaded non-mutator modules/,
                   fn ->
                     Options.new(extensions: [Enum])
                   end
    end

    test "rejects a malformed entry (bad opts shape)" do
      # The entry-shape dispatch is single-homed in `Mutare.Extension.Spec.new/1`, so a non-keyword
      # opts surfaces its message.
      assert_raise ArgumentError,
                   ~r/invalid extension entry: expected a module or a \{module, opts\} pair/,
                   fn ->
                     Options.new(extensions: [{Mutare.Test.GettextLikeExtension, :not_kw}])
                   end
    end

    test "rejects a hand-built spec with non-keyword opts (opts re-checked at the boundary)" do
      assert_raise ArgumentError, ~r/:extensions entry opts must be a keyword list/, fn ->
        Options.new(
          extensions: [
            %Mutare.Extension.Spec{module: Mutare.Test.GettextLikeExtension, opts: :garbage}
          ]
        )
      end
    end

    test "rejects a {module, opts} entry whose opts is a non-keyword list" do
      # `is_list/1` would accept `[:a, :b]` and silently treat it as empty opts; `Keyword.keyword?`
      # rejects it loudly with the keyword-list message.
      assert_raise ArgumentError, ~r/:extensions entry opts must be a keyword list/, fn ->
        Options.new(extensions: [{Mutare.Test.GettextLikeExtension, [:a, :b]}])
      end
    end

    test "rejects a mutator listed under :extensions, even one exporting call_routes/0" do
      # A macro-aware mutator exports `call_routes/0`, but it is a `Mutare.Mutator`, not an extension —
      # listing it here would merge its routing yet never run its mutations, so it fails loudly.
      assert_raise ArgumentError,
                   ~r/:extensions entries must be loaded non-mutator modules/,
                   fn ->
                     Options.new(extensions: [Mutare.Test.QueryMutator])
                   end
    end

    test "coerces an explicit nil to an empty list (like :call_routes)" do
      assert Options.new(extensions: nil).extensions == []
    end

    test "rejects a non-list" do
      assert_raise ArgumentError, ~r/:extensions must be a list/, fn ->
        Options.new(extensions: Mutare.Test.GettextLikeExtension)
      end
    end
  end
end
