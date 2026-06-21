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

defmodule MutareUseAliasDecoy do
  @moduledoc """
  A **same-named decoy** for the aliased-`use`-target test: it lives at the bare top-level segment
  `MutareUseAliasDecoy`, so an `alias Mutare.Test.ControllerUsing, as: MutareUseAliasDecoy; use
  MutareUseAliasDecoy` would expand *this* module if the target weren't alias-resolved. It injects a
  directive (`import Enum, only: [filter: 2]`) distinct from `ControllerUsing`'s, so the test can
  tell which module was actually expanded.
  """
  defmacro __using__(_opts) do
    quote do: import(Enum, only: [filter: 2])
  end
end

defmodule Mutare.Test.CallerProbe do
  @moduledoc """
  A `__using__` that derives its injected `alias` from `__CALLER__.module`, so the harvested
  directive *reveals* the caller module `Mutare.Transform.Uses` passed — the observation vehicle for
  the nested-module naming tests (`Elixir.*` absolute heads, ordinary nesting).
  """
  defmacro __using__(_opts) do
    caller = __CALLER__.module
    quote do: alias(unquote(caller), as: TheCaller)
  end
end

defmodule Mutare.Test.RealTarget do
  @moduledoc """
  The real `use` target an injected alias points at. Injects a distinctive `import Map, only:
  [get: 2]` so a test can confirm a later `use T` (where `T` was aliased to here by an *earlier*
  `use`) was expanded through the injected alias.
  """
  defmacro __using__(_opts) do
    quote do: import(Map, only: [get: 2])
  end
end

defmodule Mutare.Test.AliasInjector do
  @moduledoc """
  A `__using__` that injects an `alias Mutare.Test.RealTarget, as: T` — the setup half of the
  "an earlier `use` injects an alias a later `use` relies on" scenario (`use AliasInjector; use T`).
  """
  defmacro __using__(_opts) do
    quote do: alias(Mutare.Test.RealTarget, as: T)
  end
end

defmodule Mutare.Test.NestedInjectUsing do
  @moduledoc """
  A `__using__` whose body is `use AliasInjector; use T`: the first nested `use` *injects* `alias
  RealTarget, as: T`, which the later sibling `use T` must resolve through. Exercises folding the
  alias env in an expanded `__using__` body with the directives a nested `use` *yields* (not just
  its literal text).
  """
  defmacro __using__(_opts) do
    quote do
      use Mutare.Test.AliasInjector
      use T
    end
  end
end

defmodule Mutare.Test.BodyAliasTarget do
  @moduledoc """
  The real target of an alias declared *inside* another `__using__` body. Injects a distinctive
  `import Map, only: [merge: 2]` so a test can confirm a nested `use T` (where `T` was aliased to
  here by an earlier sibling in the same expanded body) was expanded through that in-body alias.
  """
  defmacro __using__(_opts) do
    quote do: import(Map, only: [merge: 2])
  end
end

defmodule Mutare.Test.BodyAliasUsing do
  @moduledoc """
  A `__using__` whose body declares an alias and then `use`s it (`alias BodyAliasTarget, as: T;
  use T`) — exercises folding the alias env *within* an expanded `__using__` body, the way Elixir
  expands the nested `use` through the sibling alias.
  """
  defmacro __using__(_opts) do
    quote do
      alias Mutare.Test.BodyAliasTarget, as: T
      use T
    end
  end
end

defmodule Mutare.Test.OptionDispatch do
  @moduledoc """
  A `__using__` that re-dispatches to the *same* module with a different static option
  (`use …, :a` ⇒ `use …, :b`), the `:b` clause injecting a distinctive `import Map, only:
  [pop: 2]`. Exercises the cycle guard keying on `{module, options}`, not the module alone — a
  module-only guard would mistake the `:b` re-dispatch for a cycle and drop its directive.
  """
  defmacro __using__(:a), do: quote(do: use(Mutare.Test.OptionDispatch, :b))
  defmacro __using__(:b), do: quote(do: import(Map, only: [pop: 2]))
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
