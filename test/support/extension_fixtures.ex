defmodule Mutare.Test.GettextLikeMacros do
  @moduledoc """
  A Gettext-like macro module: `translate/1,2` and `ntranslate/3`. The msgid
  positions are compile-time literals (a mutation selector spliced there would poison
  the single build), but the bindings/count positions are ordinary runtime values. A
  real, loadable macro module so a whole `import Mutare.Test.GettextLikeMacros`
  resolves by reflection — the vehicle for the extension per-position routing test.
  """
  defmacro translate(msgid), do: quote(do: unquote(msgid))
  defmacro translate(msgid, bindings), do: quote(do: {unquote(msgid), unquote(bindings)})

  defmacro ntranslate(singular, plural, count),
    do: quote(do: {unquote(singular), unquote(plural), unquote(count)})
end

defmodule Mutare.Test.GettextLike do
  @moduledoc """
  A `use Gettext`-style module whose `__using__` registers state by **mutating the
  caller** (`Module.put_attribute` on `__CALLER__.module`), which raises against the
  already-compiled caller `Mutare.Transform.Uses` expands under — so in-process
  expansion harvests nothing, exactly like real Gettext. Only a `Mutare.UseExpansion`
  override can surface the `import Mutare.Test.GettextLikeMacros` it would inject.
  """
  defmacro __using__(_opts) do
    Module.put_attribute(__CALLER__.module, :mutare_gettext_like_probe, true)
    quote do: import(Mutare.Test.GettextLikeMacros)
  end
end

defmodule Mutare.Test.GettextLikeExtension do
  @moduledoc """
  The reference `Mutare.UseExpansion` (the `mutare_gettext` pattern): it overrides
  `use Mutare.Test.GettextLike` to inject the `import Mutare.Test.GettextLikeMacros`
  its raising `__using__` can't, *and* routes each macro's msgid positions `:skip`
  while leaving the bindings/count positions `:expression`. So the bare calls resolve,
  the literal msgids are never mutated (no poison), and the runtime arguments are.
  """
  @behaviour Mutare.UseExpansion
  @behaviour Mutare.MacroRouting

  @impl Mutare.UseExpansion
  def expand_use(Mutare.Test.GettextLike, _args, _context),
    do: Mutare.UseExpansion.expand([quote(do: import(Mutare.Test.GettextLikeMacros))])

  def expand_use(_used, _args, _context), do: :decline

  @impl Mutare.MacroRouting
  def macro_routes do
    [
      {Mutare.Test.GettextLikeMacros, :translate, 1, [:skip]},
      {Mutare.Test.GettextLikeMacros, :translate, 2, [:skip, :expression]},
      {Mutare.Test.GettextLikeMacros, :ntranslate, 3, [:skip, :skip, :expression]}
    ]
  end
end

defmodule Mutare.Test.BlockDirectiveExtension do
  @moduledoc """
  An extension whose `expand_use/3` returns an `Expansion` whose directives are a *single quoted
  block* of two `import`s rather than a list of individual nodes — both satisfy the
  `[Macro.t()]` contract. Exercises `Harvest.from_extension`'s block-descent, which must surface
  *both* imports (a `__block__` folded as one directive would silently register neither).
  """
  @behaviour Mutare.UseExpansion

  @impl Mutare.UseExpansion
  def expand_use(Mutare.Test.GettextLike, _args, _context) do
    Mutare.UseExpansion.expand([
      quote do
        import Mutare.Test.GettextLikeMacros
        import Enum, only: [reverse: 1]
      end
    ])
  end

  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.BehaviourExtension do
  @moduledoc """
  An extension whose `expand_use/3` returns an `Expansion` with both directives and behaviours —
  injecting an `import` and the `@behaviour`s the `use` would. The behaviours list is a deliberate
  mix exercising **both** drop branches of `Harvest.normalize_behaviours/1`: two concrete module
  atoms (kept, order preserved), a non-atom (`"not a module"`, dropped by the `is_atom` guard) and a
  degenerate atom (`nil`, dropped by the `not in [nil, true, false]` guard). The filter keeps
  **concrete atoms** per the `Mutare.UseExpansion.Expansion` `behaviours: [module()]` contract — it does
  *not* verify behaviour-ness (so `GettextLikeMacros`, not actually a behaviour, is kept) — so a
  extension passing module literals lands its behaviours in the set (`Uses.injected_behaviours/1`).
  """
  @behaviour Mutare.UseExpansion

  @impl Mutare.UseExpansion
  def expand_use(Mutare.Test.GettextLike, _args, _context) do
    Mutare.UseExpansion.expand(
      [quote(do: import(Mutare.Test.GettextLikeMacros))],
      [GenServer, Mutare.Test.GettextLikeMacros, "not a module", nil]
    )
  end

  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.NestedGettextUsing do
  @moduledoc """
  A `use`-able module whose `__using__` injects a **nested** `use Mutare.Test.GettextLike` — the
  idiomatic Phoenix arrangement, where `use MyAppWeb, :html` expands to a body that itself does
  `use Gettext, …`. Proves an extension `use`-expansion override is consulted for a *nested* `use`
  (inside an expanded `__using__` body), not only a directly-written top-level one.
  """
  defmacro __using__(_opts) do
    quote do
      use Mutare.Test.GettextLike
    end
  end
end

defmodule Mutare.Test.EmptyExpansionExtension do
  @moduledoc """
  An extension that *handles* the `use` but injects nothing (`Mutare.UseExpansion.expand([])`). Proves an
  empty `Expansion` still **wins** dispatch (first-non-`:decline`-wins) — suppressing both later
  extensions and in-process expansion. An extension that wants to fall through must return `:decline`.
  """
  @behaviour Mutare.UseExpansion

  @impl Mutare.UseExpansion
  def expand_use(Mutare.Test.GettextLike, _args, _context), do: Mutare.UseExpansion.expand([])
  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.MalformedExtension do
  @moduledoc """
  An extension whose `expand_use/3` returns a value that is neither a `Mutare.UseExpansion.Expansion` nor
  `:decline` — a *contract* violation that must surface loudly (`Mutare.UseExpansion.ContractError`),
  not be silently coerced to `:decline` like a runtime failure.
  """
  @behaviour Mutare.UseExpansion

  @impl Mutare.UseExpansion
  def expand_use(Mutare.Test.GettextLike, _args, _context), do: [:not, :an, :expansion]
  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.HostingExtension do
  @moduledoc """
  An extension whose `macro_routes/0` illegally declares a `:hosted` treatment. An extension produces no
  mutations, so it cannot host one — `Mutare.MacroRouting.Registry.from_extensions/1` must reject it with a
  extension-specific message rather than aborting with a generic "hosting mutator" error.
  """
  @behaviour Mutare.MacroRouting

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.SomeDSL, :frag, 2, [:expression, :hosted]}]
end

defmodule Mutare.Test.StaticRoutingExtension do
  @moduledoc "A macro-routing-only extension, with no `use` expansion capability."
  @behaviour Mutare.MacroRouting

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.SomeDSL, :frag, 2, [:expression, :skip]}]
end

defmodule Mutare.Test.ConflictingQueryRoutingExtension do
  @moduledoc "A conflicting code-provided route used to verify deterministic conflict errors."
  @behaviour Mutare.MacroRouting

  @impl Mutare.MacroRouting
  def macro_routes,
    do: [{Mutare.Test.QueryDSL, :query, 1, :expression}]
end

defmodule Mutare.Test.IdenticalQueryRoutingExtension do
  @moduledoc "An identical code-provided route used to verify declaration coalescing."
  @behaviour Mutare.MacroRouting

  @impl Mutare.MacroRouting
  def macro_routes,
    do: [{Mutare.Test.QueryDSL, :query, 1, :skip}]
end

defmodule Mutare.Test.DynamicRoutingExtension do
  @moduledoc "A non-mutating extension that classifies a macro's routing per concrete call."
  @behaviour Mutare.MacroRouting

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.SomeDSL, :dynamic_frag, :any, :routing}]

  @impl Mutare.MacroRouting
  def route_arguments(%Mutare.MacroRouting.Call{arguments: args} = call, _context) do
    Mutare.MacroRouting.ArgumentRoutes.from_visible(
      call,
      Enum.map(args, fn _arg -> :skip end)
    )
  end
end

defmodule Mutare.Test.HostedRoutingExtension do
  @moduledoc """
  A non-mutating extension whose shape-aware classifier routes a position `:hosted`, with no
  enabled host mutator subscribing to the macro. Resolution raises at the concrete call rather
  than silently dropping the mutation.
  """
  @behaviour Mutare.MacroRouting

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.SomeDSL, :spoofed_frag, :any, :routing}]

  @impl Mutare.MacroRouting
  def route_arguments(%Mutare.MacroRouting.Call{arguments: args} = call, _context) do
    Mutare.MacroRouting.ArgumentRoutes.from_visible(
      call,
      Enum.map(args, fn _arg -> :hosted end)
    )
  end

  # An extension's host/2 is never consulted — it cannot become a selector host.
  def host(_node, _context), do: []
end

defmodule Mutare.Test.ContextExtension do
  @moduledoc """
  An extension that *reads* its `context` — proving `expand_use/3` receives the caller `:module`
  and the extension's per-instance `:opts` (from a `{module, opts}` entry). When `opts[:probe]` is
  a pid it sends `{:expand_use_context, module, opts}` so a test can assert both, and it injects
  an `import` of the module named in `opts[:import]` (defaulting to `GettextLikeMacros`).
  """
  @behaviour Mutare.UseExpansion

  @impl Mutare.UseExpansion
  def expand_use(Mutare.Test.GettextLike, _args, %{module: module, opts: opts}) do
    if probe = opts[:probe], do: send(probe, {:expand_use_context, module, opts})

    Mutare.UseExpansion.expand([
      quote(do: import(unquote(opts[:import] || Mutare.Test.GettextLikeMacros)))
    ])
  end

  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.DecliningExtension do
  @moduledoc "An extension that declines every `use` — to prove dispatch falls through to the next."
  @behaviour Mutare.UseExpansion

  @impl Mutare.UseExpansion
  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.RaisingExtension do
  @moduledoc """
  An extension whose `expand_use/3` raises — an extension *crash* is a misconfiguration, so it must surface
  **loudly** (wrapped in `Mutare.UseExpansion.ContractError`), not be swallowed to `:decline` the way a
  target's un-expandable `use` is.
  """
  @behaviour Mutare.UseExpansion

  @impl Mutare.UseExpansion
  def expand_use(_used, _args, _context), do: raise("boom from extension")
end

defmodule Mutare.Test.ThrowingExtension do
  @moduledoc """
  An extension whose `expand_use/3` **throws** (a non-local return, not an exception). It is caught by
  `safe_expand/4`'s `catch :throw, value` clause and wrapped in `Mutare.UseExpansion.ContractError` —
  exercising the `:throw` arm of `thrown_message/3`, distinct from a raise (which `rescue` handles).
  """
  @behaviour Mutare.UseExpansion

  @impl Mutare.UseExpansion
  def expand_use(_used, _args, _context), do: throw(:thrown_from_extension)
end

defmodule Mutare.Test.ExitingExtension do
  @moduledoc """
  An extension whose `expand_use/3` **exits**. Caught by `safe_expand/4`'s `catch kind, value` clause
  with `kind == :exit`, wrapped in `Mutare.UseExpansion.ContractError` — exercising the non-`:throw`
  (`signalled <kind>`) arm of `thrown_message/3`.
  """
  @behaviour Mutare.UseExpansion

  @impl Mutare.UseExpansion
  def expand_use(_used, _args, _context), do: exit(:exited_from_extension)
end
