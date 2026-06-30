defmodule Mutare.ConfigTest do
  use ExUnit.Case, async: true

  alias Mutare.Config
  doctest Mutare.Config

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

  describe "cli_switches/0" do
    test "exposes only the combined report flag" do
      switches = Config.cli_switches()

      assert switches[:report] == [:string, :keep]
      refute Keyword.has_key?(switches, :format)
      refute Keyword.has_key?(switches, :output)
    end
  end

  describe "merge/2" do
    test "no file config and no flags resolves to empty (mutators key omitted)" do
      assert Config.merge([], []) == []
    end

    test "--only becomes :paths" do
      assert Config.merge([], only: "lib/billing")[:paths] == ["lib/billing"]
    end

    test "--only accepts a single file, not just a directory" do
      assert Config.merge([], only: "lib/billing/invoice.ex")[:paths] ==
               ["lib/billing/invoice.ex"]
    end

    test "repeated --only flags accumulate into :paths, preserving order" do
      assert Config.merge([], only: "lib/billing", only: "lib/web")[:paths] ==
               ["lib/billing", "lib/web"]
    end

    test "--only is unset when absent (file config / default stands)" do
      refute Keyword.has_key?(Config.merge([], []), :paths)
      # a single --only flag replaces (does not append to) the file's list
      assert Config.merge([paths: ["lib"]], only: "lib/only")[:paths] == ["lib/only"]
    end

    test "--line FILE:LINE becomes :only_lines; repeatable; absent leaves it unset" do
      assert Config.merge([], line: "lib/billing/invoice.ex:42")[:only_lines] ==
               [{"lib/billing/invoice.ex", 42}]

      assert Config.merge([], line: "lib/a.ex:1", line: "lib/b.ex:9")[:only_lines] ==
               [{"lib/a.ex", 1}, {"lib/b.ex", 9}]

      refute Keyword.has_key?(Config.merge([], []), :only_lines)
    end

    test "--line splits on the last colon, so a path may contain one" do
      assert Config.merge([], line: "weird:name.ex:9")[:only_lines] == [{"weird:name.ex", 9}]
    end

    test "--line rejects a missing or non-integer line number" do
      for bad <- ["lib/a.ex", "lib/a.ex:", "lib/a.ex:abc", "lib/a.ex:1.5", ":42", "lib/a.ex:0"] do
        assert_raise ArgumentError, ~r/--line expects FILE:LINE/, fn ->
          Config.merge([], line: bad)
        end
      end
    end

    test "repeated --exclude flags accumulate into a list of globs, preserving order" do
      assert Config.merge([], exclude: "lib/generated/**", exclude: "lib/legacy")[:exclude] ==
               ["lib/generated/**", "lib/legacy"]
    end

    test "--exclude passes through; any flag wins over file; absent leaves it to default" do
      assert Config.merge([], exclude: "lib/a")[:exclude] == ["lib/a"]
      refute Keyword.has_key?(Config.merge([], []), :exclude)
      # a single --exclude flag replaces (does not append to) the file's list
      assert Config.merge([exclude: ["lib/file"]], exclude: "lib/flag")[:exclude] == ["lib/flag"]
    end

    test "--timeout-multiplier passes through; flag wins over file; absent leaves it to default" do
      assert Config.merge([], timeout_multiplier: 5.0)[:timeout_multiplier] == 5.0
      refute Keyword.has_key?(Config.merge([], []), :timeout_multiplier)

      assert Config.merge([timeout_multiplier: 2.0], timeout_multiplier: 4.0)[:timeout_multiplier] ==
               4.0
    end

    test "--mutators translates a CSV to names, preserving order" do
      assert Config.merge([], mutators: "relational,arithmetic")[:mutators] ==
               [:relational, :arithmetic]
    end

    test "--mutators translates a custom module name to the real module atom" do
      # Regression: `String.to_atom/1` produced `:"Mutare.Test.BooleanMutator"`,
      # which is *not* the module `Mutare.Test.BooleanMutator` (≡ the `:"Elixir.…"`
      # atom), so the documented `--mutators MyApp.MyMutator` example failed to resolve.
      assert Config.merge([], mutators: "Mutare.Test.BooleanMutator")[:mutators] ==
               [Mutare.Test.BooleanMutator]
    end

    test "--mutators mixes built-in families and custom modules" do
      assert Config.merge([], mutators: "relational,Mutare.Test.BooleanMutator")[:mutators] ==
               [:relational, Mutare.Test.BooleanMutator]
    end

    test "--mutators folds a leading Elixir. on a module name" do
      assert Config.merge([], mutators: "Elixir.Mutare.Test.BooleanMutator")[:mutators] ==
               [Mutare.Test.BooleanMutator]
    end

    test "--mutators reports an unknown family with the descriptive resolver error" do
      # Config only translates names; Options resolves them through the catalog, so the
      # descriptive error surfaces there.
      assert_raise ArgumentError, ~r/unknown mutator "relationul"/, fn ->
        Config.merge([], mutators: "relationul") |> Mutare.Options.new()
      end
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

    test "--no-full restores coverage selection and overrides file config" do
      assert Config.merge([], full: false)[:test_selection] == :coverage
      assert Config.merge([test_selection: :full], full: false)[:test_selection] == :coverage
    end

    test "--keep-sandbox passes through; otherwise it's left to default" do
      assert Config.merge([], keep_sandbox: true)[:keep_sandbox] == true
      refute Keyword.has_key?(Config.merge([], []), :keep_sandbox)
      # file config still flows through
      assert Config.merge([keep_sandbox: true], [])[:keep_sandbox] == true
    end

    test "--no-seed-app-build passes through as false; otherwise left to default" do
      # OptionParser turns `--no-seed-app-build` into `seed_app_build: false`.
      assert Config.merge([], seed_app_build: false)[:seed_app_build] == false
      refute Keyword.has_key?(Config.merge([], []), :seed_app_build)
      # `.mutare.exs` config still flows through
      assert Config.merge([seed_app_build: false], [])[:seed_app_build] == false
    end

    test "--strict-ignores passes through; otherwise it's left to default" do
      assert Config.merge([], strict_ignores: true)[:strict_ignores] == true
      refute Keyword.has_key?(Config.merge([], []), :strict_ignores)
      # file config still flows through
      assert Config.merge([strict_ignores: true], [])[:strict_ignores] == true
    end

    test "--quiet passes through; otherwise it's left to default" do
      assert Config.merge([], quiet: true)[:quiet] == true
      refute Keyword.has_key?(Config.merge([], []), :quiet)
      # file config still flows through
      assert Config.merge([quiet: true], [])[:quiet] == true
    end

    test "--harness-retries and --max-harness-error-rate pass through; flags win over file" do
      merged = Config.merge([], harness_retries: 2, max_harness_error_rate: 0.3)
      assert merged[:harness_retries] == 2
      assert merged[:max_harness_error_rate] == 0.3

      # absent flags leave the keys to their defaults (omitted here)
      refute Keyword.has_key?(Config.merge([], []), :harness_retries)
      refute Keyword.has_key?(Config.merge([], []), :max_harness_error_rate)

      # CLI flag overrides file config
      assert Config.merge([harness_retries: 0], harness_retries: 5)[:harness_retries] == 5
    end

    test "--baseline-runs passes through; flag wins over file; absent leaves it to default" do
      assert Config.merge([], baseline_runs: 2)[:baseline_runs] == 2
      refute Keyword.has_key?(Config.merge([], []), :baseline_runs)
      assert Config.merge([baseline_runs: 1], baseline_runs: 3)[:baseline_runs] == 3
    end

    test "--max-mutants passes through; flag wins over file; absent leaves it to default" do
      assert Config.merge([], max_mutants: 50)[:max_mutants] == 50
      refute Keyword.has_key?(Config.merge([], []), :max_mutants)
      assert Config.merge([max_mutants: 10], max_mutants: 25)[:max_mutants] == 25
    end

    test "--max-survivors passes through; flag wins over file; absent leaves it to default" do
      assert Config.merge([], max_survivors: 5)[:max_survivors] == 5
      refute Keyword.has_key?(Config.merge([], []), :max_survivors)
      assert Config.merge([max_survivors: 3], max_survivors: 8)[:max_survivors] == 8
    end

    test "--workers passes through; flag wins over file; absent leaves it to default" do
      assert Config.merge([], workers: 4)[:workers] == 4
      refute Keyword.has_key?(Config.merge([], []), :workers)
      assert Config.merge([workers: 2], workers: 8)[:workers] == 8
    end

    test "--timeout passes through; flag wins over file; absent leaves it to default" do
      assert Config.merge([], timeout: 30_000)[:timeout] == 30_000
      refute Keyword.has_key?(Config.merge([], []), :timeout)
      assert Config.merge([timeout: 5_000], timeout: 60_000)[:timeout] == 60_000
    end

    test "--partition-db enables the MIX_TEST_PARTITION default" do
      assert Config.merge([], partition_db: true)[:partition_env] == "MIX_TEST_PARTITION"
    end

    test "--partition-env sets a custom var name and wins over --partition-db" do
      assert Config.merge([], partition_env: "MY_DB_SLOT")[:partition_env] == "MY_DB_SLOT"

      assert Config.merge([], partition_db: true, partition_env: "MY_DB_SLOT")[:partition_env] ==
               "MY_DB_SLOT"
    end

    test "no partition flag leaves it to the file config / default" do
      refute Keyword.has_key?(Config.merge([], []), :partition_env)
      assert Config.merge([partition_env: "FromFile"], [])[:partition_env] == "FromFile"
    end

    test "--no-partition-db disables partitioning and overrides file config" do
      assert Keyword.has_key?(Config.merge([], partition_db: false), :partition_env)
      assert Config.merge([], partition_db: false)[:partition_env] == nil
      assert Config.merge([partition_env: "FromFile"], partition_db: false)[:partition_env] == nil
    end

    test "file config mutator lists pass through unchanged" do
      assert Config.merge([mutators: [:relational]], [])[:mutators] == [:relational]
    end

    test "the :builtins token in a list passes through for Options to expand" do
      assert Config.merge([mutators: [:builtins]], [])[:mutators] == [:builtins]
    end

    test "--mutators builtins translates the group token for Options" do
      assert Config.merge([], mutators: "builtins")[:mutators] == [:builtins]
    end

    test "--mutators all is not a group token" do
      assert Config.merge([], mutators: "all")[:mutators] == ["all"]
    end

    test "CLI flags win over file config" do
      assert Config.merge([paths: ["lib"]], only: "lib/only")[:paths] == ["lib/only"]
      assert Config.merge([min_score: 50], min_score: 90.0)[:min_score] == 90.0
    end

    test "--report FORMAT:PATH writes a file reporter alongside the console report" do
      assert Config.merge([], report: "json:out.json")[:reporters] ==
               [{:human, nil}, {:json, "out.json"}]
    end

    test "--report FORMAT sends the machine format to stdout and drops the human report" do
      assert Config.merge([], report: "sarif")[:reporters] == [{:sarif, nil}]
    end

    test "repeated file --report flags accumulate and keep the human report" do
      merged =
        Config.merge([],
          report: "json:out.json",
          report: "sarif:out.sarif"
        )

      assert merged[:reporters] == [{:human, nil}, {:json, "out.json"}, {:sarif, "out.sarif"}]
    end

    test "a stdout --report among file reports drops the human report" do
      merged = Config.merge([], report: "json:out.json", report: "sarif")
      assert merged[:reporters] == [{:json, "out.json"}, {:sarif, nil}]
    end

    test "repeated stdout --report flags send every machine format to stdout" do
      assert Config.merge([], report: "json", report: "sarif")[:reporters] ==
               [{:json, nil}, {:sarif, nil}]
    end

    test "without --report, .mutare.exs reporters pass through for Options to normalize" do
      refute Keyword.has_key?(Config.merge([], []), :reporters)

      assert Config.merge([reporters: [:human, {:json, "r.json"}]], [])[:reporters] ==
               [:human, {:json, "r.json"}]
    end

    test "--report wins over .mutare.exs reporters" do
      merged = Config.merge([reporters: [:sarif]], report: "json:o.json")
      assert merged[:reporters] == [{:human, nil}, {:json, "o.json"}]
    end

    test "a non-list reporters value passes through untouched (for Options to reject)" do
      # A malformed reporters value (here a bare atom, not a list) is passed
      # through unchanged so Mutare.Options can reject it with a clear message —
      # not silently dropped/rewritten.
      assert Config.merge([reporters: :json], [])[:reporters] == :json
    end

    test "Options owns runtime normalization after Config translation" do
      options =
        [mutators: [:builtins], reporters: [:human, {:json, "r.json"}]]
        |> Config.merge([])
        |> Mutare.Options.new()

      assert Enum.map(options.mutators, & &1.name) == Mutare.Mutators.families()
      assert options.reporters == [{:human, nil}, {:json, "r.json"}]
    end
  end
end
