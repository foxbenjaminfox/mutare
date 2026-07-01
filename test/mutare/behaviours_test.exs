defmodule Mutare.BehavioursTest do
  use ExUnit.Case, async: true

  alias Mutare.Mutator.Dispatch
  alias Mutare.Mutator.Spec
  alias Mutare.Transform
  alias Mutare.Transform.{Behaviours, Uses}

  # The `@behaviour` set `Mutare.Transform.Behaviours` stamps on the module named `module`
  # (its written alias path, e.g. `"Inner"`), as a sorted list — run through the full
  # `Uses → Behaviours` pre-pass so `use`-injected behaviours are visible. `expand_uses?`
  # toggles the `Uses` pass (off mimics `--no-expand-uses`).
  defp behaviours_of(source, module, expand_uses? \\ true) do
    parsed = Sourceror.parse_string!(source)
    expanded = if expand_uses?, do: Uses.annotate(parsed), else: parsed

    {_ast, found} =
      expanded
      |> Behaviours.annotate()
      |> Macro.prewalk(nil, fn
        {:defmodule, meta, [name, _]} = node, acc ->
          if Macro.to_string(name) == module, do: {node, meta}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found |> Behaviours.behaviours() |> Enum.sort()
  end

  # The mutator family names recorded by transforming `source` with the behaviour-aware
  # fixture mutator (and, by default, the full built-in set is *not* used — only the fixture,
  # to isolate its sites).
  defp behaviour_sites(source, opts \\ []) do
    {_source, sites, _next} =
      Transform.transform_string(source, [mutators: [Mutare.Test.BehaviourMutator]] ++ opts)

    Enum.map(sites, & &1.mutator)
  end

  describe "gathering — Behaviours.annotate" do
    test "a directly-written @behaviour is gathered" do
      source = """
      defmodule A do
        @behaviour GenServer
        @behaviour Enumerable
      end
      """

      assert behaviours_of(source, "A") == [Enumerable, GenServer]
    end

    test "an aliased direct @behaviour resolves to the real module" do
      source = """
      defmodule B do
        alias MyApp.Custom, as: CB
        @behaviour CB
      end
      """

      assert behaviours_of(source, "B") == [MyApp.Custom]
    end

    test "an @behaviour named through a `require X, as: B` alias resolves" do
      source = """
      defmodule R do
        require MyApp.Custom, as: CB
        @behaviour CB
      end
      """

      assert behaviours_of(source, "R") == [MyApp.Custom]
    end

    test "a top-level alias declared above the module resolves its @behaviour" do
      source = """
      alias MyApp.Thing, as: T

      defmodule D do
        @behaviour T
      end
      """

      assert behaviours_of(source, "D") == [MyApp.Thing]
    end

    test "an Erlang behaviour atom is gathered as-is" do
      source = """
      defmodule E do
        @behaviour :gen_statem
      end
      """

      assert behaviours_of(source, "E") == [:gen_statem]
    end

    test "a fully-qualified @behaviour whose real first segment is Elixir is preserved" do
      # `Elixir.Elixir.Server` names the module `:"Elixir.Elixir.Server"` (a real leading
      # `Elixir` segment under the canonical prefix). `resolve_path/2` keeps the doubled prefix
      # whole so `Module.concat` folds just the one canonical prefix — without that, the path
      # would silently degrade to the wrong module `Server`.
      source = """
      defmodule Q do
        @behaviour Elixir.Elixir.Server
      end
      """

      assert behaviours_of(source, "Q") == [:"Elixir.Elixir.Server"]
      refute behaviours_of(source, "Q") == [Server]
    end

    test "an @behaviour through an alias of the root namespace folds to the bare module" do
      # The collision the doubled-prefix preservation avoids: `alias Elixir, as: E` makes
      # `E.GenServer` the real `GenServer`, even though it resolves to the same `[:Elixir, …]`
      # path shape as a literal `Elixir.Elixir.GenServer`. It must *not* gain a doubled prefix.
      source = """
      defmodule Q2 do
        alias Elixir, as: E
        @behaviour E.GenServer
      end
      """

      assert behaviours_of(source, "Q2") == [GenServer]
    end

    test "a module with no @behaviour gets the empty set" do
      assert behaviours_of("defmodule N do\n  def f, do: 1\nend\n", "N") == []
    end
  end

  describe "gathering — through `use` expansion" do
    test "`use GenServer` injects @behaviour GenServer" do
      assert behaviours_of("defmodule C do\n  use GenServer\nend\n", "C") == [GenServer]
    end

    test "a custom `use` injecting @behaviour is harvested alongside its imports" do
      source = """
      defmodule S do
        use Mutare.Test.SampleUsing
      end
      """

      assert behaviours_of(source, "S") == [Mutare.Test.SampleBehaviour]
    end

    test "a @behaviour injected transitively through a nested `use` is harvested" do
      source = """
      defmodule S do
        use Mutare.Test.NestedSampleUsing
      end
      """

      assert behaviours_of(source, "S") == [Mutare.Test.SampleBehaviour]
    end

    test "direct and use-injected behaviours union" do
      source = """
      defmodule M do
        use GenServer
        @behaviour Enumerable
      end
      """

      assert behaviours_of(source, "M") == [Enumerable, GenServer]
    end

    test "with expand_uses off, use-injected behaviours are absent but direct ones remain" do
      source = """
      defmodule M do
        use GenServer
        @behaviour Enumerable
      end
      """

      assert behaviours_of(source, "M", false) == [Enumerable]
    end
  end

  describe "gathering — scope" do
    test "behaviours do not inherit into nested modules" do
      source = """
      defmodule Outer do
        @behaviour GenServer

        defmodule Inner do
          @behaviour Enumerable
        end
      end
      """

      assert behaviours_of(source, "Outer") == [GenServer]
      assert behaviours_of(source, "Inner") == [Enumerable]
    end
  end

  describe "delivery — a behaviour-aware mutator via transform_string" do
    test "mutate/2 and return_replacements/2 fire inside a GenServer module" do
      source = """
      defmodule MyServer do
        use GenServer

        def handle_call(:get, _from, state) do
          {:reply, state, state}
        end
      end
      """

      {out, sites, _next} =
        Transform.transform_string(source, mutators: [Mutare.Test.BehaviourMutator])

      # both the tuple swap (mutate/2) and the return-tail (return_replacements/2) recorded
      assert Enum.map(sites, & &1.mutator) == [:behaviour_aware, :behaviour_aware]
      assert out =~ "{:noreply, state}"
      assert out =~ ":behaviour_marker"
    end

    test "fires on a directly-declared @behaviour too" do
      source = """
      defmodule MyServer do
        @behaviour GenServer

        def handle_call(:get, _from, state) do
          {:reply, state, state}
        end
      end
      """

      assert behaviour_sites(source) == [:behaviour_aware, :behaviour_aware]
    end

    test "fires under a custom use-injected behaviour" do
      source = """
      defmodule Sampled do
        use Mutare.Test.SampleUsing

        def handle(state) do
          {:reply, state, state}
        end
      end
      """

      assert behaviour_sites(source) == [:behaviour_aware, :behaviour_aware]
    end

    test "does NOT fire in a module implementing none of the target behaviours" do
      source = """
      defmodule Plain do
        def handle_call(:get, _from, state) do
          {:reply, state, state}
        end
      end
      """

      assert behaviour_sites(source) == []
    end

    test "with expand_uses off, a use-only GenServer module no longer fires" do
      source = """
      defmodule MyServer do
        use GenServer

        def handle_call(:get, _from, state) do
          {:reply, state, state}
        end
      end
      """

      assert behaviour_sites(source, expand_uses: false) == []
    end
  end

  describe "the Spec carrier" do
    test "a base spec has the empty behaviour set" do
      assert Spec.for_module(Mutare.Mutators.Arithmetic).behaviours == MapSet.new()
    end

    test "mutations/3 injects the spec's behaviours into the mutate/2 context" do
      spec = %{
        Spec.for_module(Mutare.Test.BehaviourMutator)
        | behaviours: MapSet.new([GenServer])
      }

      node = {:{}, [], [{:__block__, [], [:reply]}, {:r, [], nil}, {:s, [], nil}]}

      assert [{^spec, {:{}, _, [{:__block__, _, [:noreply]}, {:s, _, nil}]}, nil, nil}] =
               Dispatch.mutations(node, [spec])
    end

    test "structural callbacks receive the spec's opts in their context" do
      spec =
        Mutare.Test.ConfigurableReturnMutator
        |> Spec.configured(replacement: :from_opts)

      assert Dispatch.return_replacements(spec, {:tail, [], nil}) ==
               [Mutare.AST.literal(:from_opts)]
    end

    test "with empty behaviours the same mutator does not fire" do
      spec = Spec.for_module(Mutare.Test.BehaviourMutator)
      node = {:{}, [], [{:__block__, [], [:reply]}, {:r, [], nil}, {:s, [], nil}]}

      assert Dispatch.mutations(node, [spec]) == []
    end
  end
end
