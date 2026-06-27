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
    switches = Registry.cli_switches()

    assert Keyword.keyword?(switches)
    assert {:expand_uses, :boolean} in switches
    assert {:workers, :integer} in switches
    assert {:min_score, :float} in switches

    # exceptional/translated flags are owned by Mutare.Config, not the registry
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
end
