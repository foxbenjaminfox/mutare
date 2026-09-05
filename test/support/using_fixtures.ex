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
  in for `use Ecto.Schema` so a registered `{Mutare.Test.SchemaDSL, :schema, 1, :raw}` routing
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

defmodule Mutare.Test.AliasAwareUsing do
  @moduledoc """
  A `__using__` that branches on the caller's lexical aliases: it injects `import Map, only:
  [fetch: 2]` when the caller has aliased *something to* `Enum` (`alias Enum, as: U`, whose entry
  is `{U, Enum}`), else `import Map, only: [get: 2]`. The observation vehicle for
  `__CALLER__.aliases` faithfulness — `Mutare.Transform.Uses` must mirror the source alias env into
  the expansion env, not leave its own (which never aliases `Enum`). The real compiler sees the
  caller's `alias`; the pre-pass must too.
  """
  defmacro __using__(_opts) do
    aliases_enum? = Enum.member?(Keyword.values(__CALLER__.aliases), Enum)

    if aliases_enum?,
      do: quote(do: import(Map, only: [fetch: 2])),
      else: quote(do: import(Map, only: [get: 2]))
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

defmodule Mutare.Test.HeadAlias.Target do
  @moduledoc """
  A `__using__` reachable only through a nested module head's *own* implicit alias. Injects a
  distinctive `import Map, only: [merge: 2]`. In `defmodule Mutare.Test do defmodule HeadAlias.Bar
  do use HeadAlias.Target end end`, the head `HeadAlias.Bar` aliases `HeadAlias =>
  Mutare.Test.HeadAlias` *inside its own body*, so `use HeadAlias.Target` resolves here — the
  observation vehicle for registering the child alias before walking the body.
  """
  defmacro __using__(_opts) do
    quote do: import(Map, only: [merge: 2])
  end
end

defmodule Mutare.Test.UnquoteAliasUsing do
  @moduledoc """
  A `__using__` whose body declares an alias via **`unquote`d** target and then `use`s it. The
  `unquote(target)` splices the module as a *bare atom* (`{:alias, _, [Mutare.Test.BodyAliasTarget,
  [as: T]]}`), the shape `Aliases.register/2` only understands after Sourceror normalization — so
  the sibling `use T` resolves (and surfaces `BodyAliasTarget`'s `import Map, only: [merge: 2]`)
  only when the harvested alias is normalized *before* being folded into the body env.
  """
  defmacro __using__(_opts) do
    target = Mutare.Test.BodyAliasTarget

    quote do
      alias unquote(target), as: T
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

defmodule Mutare.Test.EnvSensitiveUsing do
  @moduledoc """
  A `__using__` that injects *different* directives depending on `Mix.env()` — `import Map, only:
  [fetch: 2]` under `:test`, `[delete: 2]` otherwise. Exercises mirroring the sandbox env (`:test`)
  during expansion: the metamutant compiles/runs under `:test`, so the `:test` branch is what's
  actually in scope, even when the scan runs in `:dev`.
  """
  defmacro __using__(_opts) do
    if Mix.env() == :test,
      do: quote(do: import(Map, only: [fetch: 2])),
      else: quote(do: import(Map, only: [delete: 2]))
  end
end

defmodule Mutare.Test.SlowUsing do
  @moduledoc """
  A `__using__` that sleeps during expansion, widening the window for the concurrency test: with a
  non-serialized env mirror, overlapping swaps would interleave their save/restore and corrupt the
  global `Mix.env()`.
  """
  defmacro __using__(_opts) do
    Process.sleep(15)
    quote do: import(Map, only: [fetch: 2])
  end
end

defmodule Mutare.Test.SlowEnvSensitiveUsing do
  @moduledoc """
  Slow **and** env-sensitive: sleeps (widening the concurrency window) then injects based on
  `Mix.env()` read *after* the sleep. The vehicle for the fast-path soundness hole — a process that
  takes the unlocked fast path on another swapper's transient `:test` reads `:dev` again once that
  swapper restores, harvesting the wrong (`delete`) branch. Under a correct mirror every expansion
  sees `:test` for its whole duration, always injecting `fetch`.
  """
  defmacro __using__(_opts) do
    Process.sleep(4)

    if Mix.env() == :test,
      do: quote(do: import(Map, only: [fetch: 2])),
      else: quote(do: import(Map, only: [delete: 2]))
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

defmodule Mutare.Test.SampleBehaviour do
  @moduledoc """
  A trivial behaviour, the custom analog of `GenServer` for the `@behaviour`-detection tests
  (`Mutare.Transform.Behaviours`): a `use Mutare.Test.SampleUsing` injects `@behaviour
  Mutare.Test.SampleBehaviour`, so the harvest can be exercised without stdlib internals.
  """
  @callback handle(term()) :: term()
end

defmodule Mutare.Test.SampleUsing do
  @moduledoc """
  A `use GenServer`-style bundle: its `__using__` injects `@behaviour Mutare.Test.SampleBehaviour`
  *alongside* an `import` — the unit-test vehicle for `use`-injected behaviour harvesting
  (`Mutare.Transform.Uses` must surface the behaviour and the directive from one expansion).
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Mutare.Test.SampleBehaviour
      import Enum, only: [reject: 2]
    end
  end
end

defmodule Mutare.Test.NestedSampleUsing do
  @moduledoc """
  A `__using__` that itself `use`s `Mutare.Test.SampleUsing` — exercises harvesting a
  `@behaviour` injected *transitively* through a nested `use` re-expansion.
  """
  defmacro __using__(_opts), do: quote(do: use(Mutare.Test.SampleUsing))
end

defmodule Mutare.Test.CallerMutatingUsing do
  @moduledoc """
  A `use Gettext, backend: …`-style raiser: its `__using__` runs a **caller-mutating side effect**
  in the macro body itself (`Module.put_attribute` on `__CALLER__.module`), which raises
  `ArgumentError` against the already-compiled caller our pre-pass expands under. Stands in for
  Gettext, whose `__using__` registers its backend the same way. Used *nested* inside a bundle to
  prove one raising `use` doesn't drop its siblings.
  """
  defmacro __using__(_opts) do
    Module.put_attribute(__CALLER__.module, :mutare_caller_mutating_probe, true)
    quote do: import(Map, only: [take: 2])
  end
end

defmodule Mutare.Test.BundleWithRaisingUsing do
  @moduledoc """
  A `:live_view`-style bundle whose `__using__` body is a block mixing good directives with a
  *nested* raiser: `import Enum, only: [reject: 2]`, then `use CallerMutatingUsing` (raises like
  `use Gettext, backend: …`), then `@behaviour Mutare.Test.SampleBehaviour`. The regression vehicle
  for "a single raising nested `use` must drop only its own contribution, never its siblings."
  """
  defmacro __using__(_opts) do
    quote do
      import Enum, only: [reject: 2]
      use Mutare.Test.CallerMutatingUsing
      @behaviour Mutare.Test.SampleBehaviour
    end
  end
end
