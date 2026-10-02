defmodule Mutare.CoverageAttributionTest do
  use ExUnit.Case, async: true

  alias Mutare.CoverageAttribution
  alias Mutare.Coverage.Recorder

  def attach_attribution(opts) do
    send(self(), {:attached, opts})
    :ok
  end

  describe "attribute_to/1" do
    test "declares the owner under the key the written helper reads, and withdraws it" do
      # The written `:mutare_cov` helper reads the harness descriptor's key; the runner test
      # "a coverage-attribution extension's declarations narrow selection…" drives that reader.
      key = Recorder.runtime(:harness).anchor_key
      owner = spawn(fn -> :ok end)

      assert CoverageAttribution.attribute_to(owner) == :ok
      assert Process.get(key) == owner
      assert CoverageAttribution.attribute_to(nil) == :ok
      refute Map.has_key?(Map.new(Process.get()), key)
    end
  end

  describe "Recorder.attribution_ast/1" do
    test "renders nothing without an attributing extension" do
      assert Recorder.attribution_ast([]) == nil
    end

    test "calls each extension in order with its options, under the probe-mode gate" do
      rendered =
        [{First, [header: "x-test", nested: %{depth: {1, 2.5}}]}, {Second, []}]
        |> Recorder.attribution_ast()
        |> Macro.to_string()

      mode_key = inspect(Recorder.runtime(:harness).mode_key)
      assert rendered =~ "if :persistent_term.get(#{mode_key}, false) do"

      assert rendered =~
               ~s[:ok = Elixir.First.attach_attribution(header: "x-test", nested: %{depth: {1, 2.5}})]

      assert rendered =~ "\n  :ok = Elixir.Second.attach_attribution([])"
      assert :binary.match(rendered, "First.") < :binary.match(rendered, "Second.")
    end

    test "rendered callbacks and nested option atoms retain their values under helper aliases" do
      opts = [
        module: Repo,
        nested: %{Repo => {Repo.Nested, [Repo, :"Elixir.not-an-alias", :erlang, nil]}},
        text: "Repo"
      ]

      # Exercise the calls without changing the VM-wide harness probe flag.
      {:if, _, [_gate, [do: calls]]} = Recorder.attribution_ast([{__MODULE__, opts}])

      source = """
      alias MyApp.Repo, warn: false
      alias MyApp.Mutare, warn: false
      #{Macro.to_string(calls)}
      """

      assert {:ok, _} = Code.eval_string(source)
      assert_received {:attached, ^opts}
    end
  end
end
