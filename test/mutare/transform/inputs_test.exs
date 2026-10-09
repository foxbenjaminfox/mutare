defmodule Mutare.Transform.InputsTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform
  alias Mutare.Transform.{Diagnostics, Inputs}

  defmodule Initialized do
    @behaviour Mutare.Mutator

    @impl true
    def name, do: :initialized

    @impl true
    def init(opts) do
      send(self(), {:initialized, opts})
      Diagnostics.warn(fn -> "initializing mutator" end, :log)
      opts
    end

    @impl true
    def mutate(_), do: :skip
  end

  setup do
    Mutare.Test.isolate_selector()
    :ok
  end

  test "verification requires diff text even when rendering was deferred" do
    result =
      Transform.transform_string("defmodule Probe do\n def f(x), do: x + 2\nend",
        file: "lib/probe.ex",
        start_id: 37,
        runtime_namespace: "lib/probe.ex",
        mutators: [:arithmetic],
        render_site_code: false,
        verify_invariants: true
      )

    assert result.next_id == 38
    assert [site] = result.mutants
    assert site.id == 37
    assert site.file == "lib/probe.ex"
    assert site.original_code == "x + 2"
    assert site.mutated_code == "x - 2"
  end

  test "a raw mutator initializes on every pass, including verification and hydration" do
    opts = [mutators: [{Initialized, value: 3}], warnings: false]
    source = "defmodule Probe do\n def f(x), do: x\nend"

    assert Transform.count_report(source, opts).mutants == 0
    assert_receive {:initialized, [value: 3]}
    refute_receive {:initialized, _}

    Transform.transform_string(source, Keyword.put(opts, :verify_invariants, true))
    assert_receive {:initialized, [value: 3]}
    assert_receive {:initialized, [value: 3]}
    refute_receive {:initialized, _}

    assert Transform.render_sites(source, opts) == []
    assert_receive {:initialized, [value: 3]}
    refute_receive {:initialized, _}
  end

  test "resolved mutator specs retain their initialized configuration" do
    specs = Mutare.Mutators.resolve([{Initialized, value: 3}])
    assert_receive {:initialized, [value: 3]}
    assert Inputs.new(mutators: specs).config.mutators == specs
    refute_receive {:initialized, _}
  end

  test "initialization follows warning policy and restores the caller's scope" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Inputs.new(mutators: [Initialized], warnings: false)

        Diagnostics.with_warnings(false, fn ->
          Inputs.new(mutators: [Initialized], warnings: true)
        end)
      end)

    refute log =~ "initializing mutator"

    assert ExUnit.CaptureLog.capture_log(fn ->
             Inputs.new(mutators: [Initialized], warnings: true)
           end) =~ "initializing mutator"
  end

  test "malformed source is rejected before invoking mutator initialization" do
    assert_raise TokenMissingError, fn ->
      Transform.transform_string("defmodule Probe do", mutators: [Initialized])
    end

    refute_receive {:initialized, _}
  end
end
