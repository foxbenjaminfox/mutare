defmodule Mutare.Test.ControllerUsing do
  @moduledoc """
  A `use MyAppWeb, :controller`-style bundle: a `__using__` macro that injects an `import` and
  an `alias`. Real and loadable in the `:test` env, so `Mutare.Transform.Uses` can expand it
  in-process and harvest the directives — the unit-test vehicle for `use`-expansion (the
  `examples/*` projects have no deps and are external to Mutare, so they can't exercise it).
  """
  defmacro __using__(_opts) do
    quote do
      import Enum, only: [reject: 2]
      alias String, as: S
    end
  end
end

defmodule Mutare.Test.SchemaUsing do
  @moduledoc """
  The Ecto analog: a `__using__` that injects `import Mutare.Test.SchemaDSL`, bringing the
  `schema/1` DSL macro into scope as a *bare* call. Lets a `use Mutare.Test.SchemaUsing` stand
  in for `use Ecto.Schema` so a registered `{Mutare.Test.SchemaDSL, :schema, 1, :skip}` routing
  fires only once the injected import is surfaced.
  """
  defmacro __using__(_opts) do
    quote do: import(Mutare.Test.SchemaDSL)
  end
end

defmodule Mutare.Test.NestedUsing do
  @moduledoc """
  A `__using__` that itself `use`s another module — exercises nested re-expansion (the
  harvested directives come transitively from `ControllerUsing`).
  """
  defmacro __using__(_opts) do
    quote do: use(Mutare.Test.ControllerUsing)
  end
end

defmodule Mutare.Test.RaisingUsing do
  @moduledoc "A `__using__` that raises at expansion — must degrade to no directives, never crash."
  defmacro __using__(_opts), do: raise("boom from __using__")
end

defmodule Mutare.Test.CyclicUsingA do
  @moduledoc "Half of a `use`-cycle (A uses B, B uses A) — expansion must terminate via the seen-set."
  defmacro __using__(_opts), do: quote(do: use(Mutare.Test.CyclicUsingB))
end

defmodule Mutare.Test.CyclicUsingB do
  @moduledoc "Half of a `use`-cycle (A uses B, B uses A) — expansion must terminate via the seen-set."
  defmacro __using__(_opts), do: quote(do: use(Mutare.Test.CyclicUsingA))
end
