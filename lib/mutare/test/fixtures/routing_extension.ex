defmodule Mutare.Test.Fixtures.RoutingExtension do
  @moduledoc """
  A shipped routing-only extension for testing composition with foreign macro routing.

  Registering routes for its macros is how a library ships the knowledge its DSL
  relies on (`Mutare.MacroRouting`). Testing that your mutator honours routing from
  an *independent* module therefore needs a routed macro that module owns — this
  fixture is that module, so a plugin suite doesn't have to author a no-op routing
  provider of its own. It defines two inert pass-through macros and registers their
  argument routing:

  | Macro | Route | Pins |
  | --- | --- | --- |
  | `opaque/1` | `:skip` | the whole call is opaque — nothing inside it is mutated |
  | `tagged/2` | `[:expression, :skip]` | per-argument routing — the expression mutates, the label never does |

  Both expand to their (first) argument, so fixtures using them still compile and
  run (`Mutare.Test.assert_metamutant_compiles/3`, `Mutare.Test.compile_metamutant/3`).
  Enable the routes by
  threading the module through the `Mutare.Test` helpers' `opts` — routing applies
  only when the extension is enabled, so the same source doubles as the unrouted
  contrast:

      import Mutare.Test
      alias Mutare.Test.Fixtures.RoutingExtension

      source = \"\"\"
      defmodule M do
        import Mutare.Test.Fixtures.RoutingExtension
        def f(x), do: opaque(x + 1)
      end
      \"\"\"

      # Unrouted, the argument mutates; routed, the foreign :skip suppresses it.
      assert {:arithmetic, "x + 1", "x - 1"} in diffs(source, [:arithmetic])
      assert diffs(source, [:arithmetic], extensions: [RoutingExtension]) == []

  This is an **extension** — no `name/0`, no mutations — so it goes under
  `:extensions` (or a declarative `:macro_routes` entry naming its macros, to test
  the config channel). It deliberately covers only the end-user treatments: the
  adapter-grade ones (`:interpolated`, `{:keyword, …}`, `:hosted`) assert facts
  about a real DSL's semantics that no generic fixture can stand in for — model
  those on the `Mutare.MacroRouting` and `Mutare.Mutator.MacroHost` contracts
  against the library you're describing.
  """

  @behaviour Mutare.MacroRouting

  @doc "Passes `expr` through unchanged. Routed fully `:skip` — the call is opaque."
  defmacro opaque(expr), do: expr

  @doc "Passes `expr` through, discarding `label`. Routed `[:expression, :skip]`."
  defmacro tagged(expr, _label), do: expr

  @impl Mutare.MacroRouting
  def macro_routes do
    [
      {__MODULE__, :opaque, 1, :skip},
      {__MODULE__, :tagged, 2, [:expression, :skip]}
    ]
  end
end
