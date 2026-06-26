defmodule Mutare.Test.GettextLikeMacros do
  @moduledoc """
  A Gettext-like macro module: `translate/1,2` and `ntranslate/3`. The msgid
  positions are compile-time literals (a mutation selector spliced there would poison
  the single build), but the bindings/count positions are ordinary runtime values. A
  real, loadable macro module so a whole `import Mutare.Test.GettextLikeMacros`
  resolves by reflection — the vehicle for the plugin per-position routing test.
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
  expansion harvests nothing, exactly like real Gettext. Only a `Mutare.Plugin`
  override can surface the `import Mutare.Test.GettextLikeMacros` it would inject.
  """
  defmacro __using__(_opts) do
    Module.put_attribute(__CALLER__.module, :mutare_gettext_like_probe, true)
    quote do: import(Mutare.Test.GettextLikeMacros)
  end
end

defmodule Mutare.Test.GettextLikePlugin do
  @moduledoc """
  The reference `Mutare.Plugin` (the `mutare_gettext` pattern): it overrides
  `use Mutare.Test.GettextLike` to inject the `import Mutare.Test.GettextLikeMacros`
  its raising `__using__` can't, *and* routes each macro's msgid positions `:skip`
  while leaving the bindings/count positions `:expression`. So the bare calls resolve,
  the literal msgids are never mutated (no poison), and the runtime arguments are.
  """
  @behaviour Mutare.Plugin

  @impl Mutare.Plugin
  def expand_use(Mutare.Test.GettextLike, _args, _context),
    do: Mutare.Plugin.expand([quote(do: import(Mutare.Test.GettextLikeMacros))])

  def expand_use(_used, _args, _context), do: :decline

  @impl Mutare.Plugin
  def macros do
    [
      {Mutare.Test.GettextLikeMacros, :translate, 1, [:skip]},
      {Mutare.Test.GettextLikeMacros, :translate, 2, [:skip, :expression]},
      {Mutare.Test.GettextLikeMacros, :ntranslate, 3, [:skip, :skip, :expression]}
    ]
  end
end

defmodule Mutare.Test.BlockDirectivePlugin do
  @moduledoc """
  A plugin whose `expand_use/3` returns an `Expansion` whose directives are a *single quoted
  block* of two `import`s rather than a list of individual nodes — both satisfy the
  `[Macro.t()]` contract. Exercises `Harvest.from_plugin`'s block-descent, which must surface
  *both* imports (a `__block__` folded as one directive would silently register neither).
  """
  @behaviour Mutare.Plugin

  @impl Mutare.Plugin
  def expand_use(Mutare.Test.GettextLike, _args, _context) do
    Mutare.Plugin.expand([
      quote do
        import Mutare.Test.GettextLikeMacros
        import Enum, only: [reverse: 1]
      end
    ])
  end

  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.BehaviourPlugin do
  @moduledoc """
  A plugin whose `expand_use/3` returns an `Expansion` with both directives and behaviours —
  injecting an `import` and the `@behaviour`s the `use` would. The behaviours list is a deliberate
  mix exercising **both** drop branches of `Harvest.normalize_behaviours/1`: two concrete module
  atoms (kept, order preserved), a non-atom (`"not a module"`, dropped by the `is_atom` guard) and a
  degenerate atom (`nil`, dropped by the `not in [nil, true, false]` guard). The filter keeps
  **concrete atoms** per the `Mutare.Plugin.Expansion` `behaviours: [module()]` contract — it does
  *not* verify behaviour-ness (so `GettextLikeMacros`, not actually a behaviour, is kept) — so a
  plugin passing module literals lands its behaviours in the set (`Uses.injected_behaviours/1`).
  """
  @behaviour Mutare.Plugin

  @impl Mutare.Plugin
  def expand_use(Mutare.Test.GettextLike, _args, _context) do
    Mutare.Plugin.expand(
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
  `use Gettext, …`. Proves a plugin `use`-expansion override is consulted for a *nested* `use`
  (inside an expanded `__using__` body), not only a directly-written top-level one.
  """
  defmacro __using__(_opts) do
    quote do
      use Mutare.Test.GettextLike
    end
  end
end

defmodule Mutare.Test.EmptyExpansionPlugin do
  @moduledoc """
  A plugin that *handles* the `use` but injects nothing (`Mutare.Plugin.expand([])`). Proves an
  empty `Expansion` still **wins** dispatch (first-non-`:decline`-wins) — suppressing both later
  plugins and in-process expansion. A plugin that wants to fall through must return `:decline`.
  """
  @behaviour Mutare.Plugin

  @impl Mutare.Plugin
  def expand_use(Mutare.Test.GettextLike, _args, _context), do: Mutare.Plugin.expand([])
  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.MalformedPlugin do
  @moduledoc """
  A plugin whose `expand_use/3` returns a value that is neither a `Mutare.Plugin.Expansion` nor
  `:decline` — a *contract* violation that must surface loudly (`Mutare.Plugin.ContractError`),
  not be silently coerced to `:decline` like a runtime failure.
  """
  @behaviour Mutare.Plugin

  @impl Mutare.Plugin
  def expand_use(Mutare.Test.GettextLike, _args, _context), do: [:not, :an, :expansion]
  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.HostingPlugin do
  @moduledoc """
  A plugin whose `macros/0` illegally declares a `:hosted` treatment. A plugin produces no
  mutations, so it cannot host one — `Mutare.Macros.from_plugins/1` must reject it with a
  plugin-specific message rather than aborting with a generic "hosting mutator" error.
  """
  @behaviour Mutare.Plugin

  @impl Mutare.Plugin
  def macros, do: [{Mutare.Test.SomeDSL, :frag, 2, [:expression, :hosted]}]
end

defmodule Mutare.Test.ContextPlugin do
  @moduledoc """
  A plugin that *reads* its `context` — proving `expand_use/3` receives the caller `:module`
  and the plugin's per-instance `:opts` (from a `{module, opts}` entry). When `opts[:probe]` is
  a pid it sends `{:expand_use_context, module, opts}` so a test can assert both, and it injects
  an `import` of the module named in `opts[:import]` (defaulting to `GettextLikeMacros`).
  """
  @behaviour Mutare.Plugin

  @impl Mutare.Plugin
  def expand_use(Mutare.Test.GettextLike, _args, %{module: module, opts: opts}) do
    if probe = opts[:probe], do: send(probe, {:expand_use_context, module, opts})

    Mutare.Plugin.expand([
      quote(do: import(unquote(opts[:import] || Mutare.Test.GettextLikeMacros)))
    ])
  end

  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.DecliningPlugin do
  @moduledoc "A plugin that declines every `use` — to prove dispatch falls through to the next."
  @behaviour Mutare.Plugin

  @impl Mutare.Plugin
  def expand_use(_used, _args, _context), do: :decline
end

defmodule Mutare.Test.RaisingPlugin do
  @moduledoc """
  A plugin whose `expand_use/3` raises — a plugin *crash* is a misconfiguration, so it must surface
  **loudly** (wrapped in `Mutare.Plugin.ContractError`), not be swallowed to `:decline` the way a
  target's un-expandable `use` is.
  """
  @behaviour Mutare.Plugin

  @impl Mutare.Plugin
  def expand_use(_used, _args, _context), do: raise("boom from plugin")
end
