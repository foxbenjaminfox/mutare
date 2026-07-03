defmodule Mutare.Options.RegistryTest do
  use ExUnit.Case, async: true

  alias Mutare.Options
  alias Mutare.Options.Registry

  test "defaults/0 drives the Options struct: same keys, identity validators on each default" do
    options = Options.new([])

    # Each validator is identity on its own default, except `:workers` (nil -> scheduler count).
    for {key, default} <- Registry.defaults(), key != :workers do
      assert Map.fetch!(options, key) == default
    end

    assert is_integer(options.workers) and options.workers > 0
  end

  test "the runtime-wiring keys are NOT registry options (they live on Run.Context)" do
    keys = Keyword.keys(Registry.defaults())

    for wiring <- [:project, :reporter, :on_phase, :on_start, :on_scan] do
      refute wiring in keys
    end
  end

  test "cli_switches/0 are the 1:1 passthrough flags, shaped for OptionParser" do
    assert Registry.cli_switches() == [
             expand_uses: :boolean,
             workers: :integer,
             timeout: :integer,
             timeout_multiplier: :float,
             compile_timeout: :integer,
             probe_timeout: :integer,
             baseline_runs: :integer,
             kill_runs: :integer,
             confirm_timeouts: :boolean,
             harness_retries: :integer,
             max_harness_error_rate: :float,
             max_mutants: :integer,
             max_survivors: :integer,
             min_score: :float,
             max_no_coverage: :integer,
             fail_on_poisoned: :boolean,
             fail_on_harness_error: :boolean,
             strict_ignores: :boolean,
             sandbox: :string,
             keep_sandbox: :boolean,
             seed_app_build: :boolean,
             quiet: :boolean,
             verbose: :boolean
           ]

    # exceptional/translated flags are owned by Mutare.Config, not the registry
    switches = Registry.cli_switches()
    refute Keyword.has_key?(switches, :mutators)
    refute Keyword.has_key?(switches, :full)
    refute Keyword.has_key?(switches, :reporters)
  end

  test "passthrough_keys/0 are exactly the cli_switches/0 keys" do
    assert Registry.passthrough_keys() == Keyword.keys(Registry.cli_switches())
  end

  test "display_rows/1 lists every visible option — including the once-silently-omitted ones" do
    labels = Options.new([]) |> Registry.display_rows() |> Enum.map(fn {label, _} -> label end)

    for once_omitted <- ~w(partition_env seed_app_build quiet only_files only_lines) do
      assert once_omitted in labels
    end

    # The verbose UI knob is a visible option too (added as a registry passthrough).
    assert "verbose" in labels
  end

  test "verbose is a 1:1 passthrough boolean flag" do
    assert {:verbose, :boolean} in Registry.cli_switches()
  end

  test "display_rows/1 renders default values with each option's configured formatter" do
    assert Registry.display_rows(Options.new([])) == [
             {"paths", "[\"lib\"]"},
             {"exclude", "[]"},
             {"mutators", "(all built-ins — see --list-mutators)"},
             {"macro_routes", "[]"},
             {"extensions", "(none)"},
             {"expand_uses", "true"},
             {"only_files", "(all discovered files)"},
             {"only_lines", "(all lines)"},
             {"test_selection", "coverage"},
             {"workers", to_string(System.schedulers_online())},
             {"partition_env", "(off)"},
             {"timeout", "derived from baseline run"},
             {"timeout_multiplier", "3.0"},
             {"compile_timeout", "1800000"},
             {"probe_timeout", "derived from the per-mutant cap"},
             {"baseline_runs", "1"},
             {"kill_runs", "1"},
             {"confirm_timeouts", "true"},
             {"harness_retries", "2"},
             {"max_harness_error_rate", "0.5"},
             {"max_mutants", "(no cap)"},
             {"max_survivors", "(no cap)"},
             {"min_score", "(no gate)"},
             {"max_no_coverage", "(no gate)"},
             {"fail_on_poisoned", "false"},
             {"fail_on_harness_error", "false"},
             {"strict_ignores", "false"},
             {"sandbox", "(throwaway temp dir)"},
             {"keep_sandbox", "false"},
             {"seed_app_build", "true"},
             {"quiet", "false"},
             {"verbose", "false"},
             {"reporters", "human (stdout)"}
           ]
  end

  test "display_rows/1 renders custom values through specialised formatters" do
    options =
      Options.new(
        mutators: [:arithmetic, :relational],
        extensions: [
          Mutare.Test.GettextLikeExtension,
          {Mutare.Test.GettextLikeExtension, domain: "errors"}
        ],
        only_files: ["lib/a.ex", "lib/b.ex"],
        only_lines: [{"lib/a.ex", 42}],
        workers: 1,
        partition_env: "MIX_TEST_PARTITION",
        timeout: 1,
        timeout_multiplier: 1,
        max_harness_error_rate: nil,
        max_mutants: 1,
        max_survivors: 1,
        min_score: 1,
        max_no_coverage: 1,
        sandbox: "/tmp/mutare-sandbox",
        reporters: [:human, {:json, "mutare.json"}]
      )

    rows = Map.new(Registry.display_rows(options))

    assert rows["mutators"] == "arithmetic, relational"

    assert rows["extensions"] ==
             "Mutare.Test.GettextLikeExtension, " <>
               "Mutare.Test.GettextLikeExtension [domain: \"errors\"]"

    assert rows["only_files"] == "MapSet.new([\"lib/a.ex\", \"lib/b.ex\"])"
    assert rows["only_lines"] == "MapSet.new([{\"lib/a.ex\", 42}])"
    assert rows["partition_env"] == "MIX_TEST_PARTITION"
    assert rows["timeout"] == "1"
    assert rows["timeout_multiplier"] == "1"
    assert rows["max_harness_error_rate"] == "nil"
    assert rows["max_mutants"] == "1"
    assert rows["max_survivors"] == "1"
    assert rows["min_score"] == "1"
    assert rows["max_no_coverage"] == "1"
    assert rows["sandbox"] == "/tmp/mutare-sandbox"
    assert rows["reporters"] == "human (stdout), json (mutare.json)"
  end

  test "display_rows/1 requires a map-shaped option source" do
    assert_raise FunctionClauseError, fn ->
      Registry.display_rows(:not_options)
    end
  end
end
