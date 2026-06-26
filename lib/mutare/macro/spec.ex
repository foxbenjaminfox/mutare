defmodule Mutare.Macro.Spec do
  @moduledoc """
  A resolved **known-macro** entry: a macro the transform should route the
  arguments of by a declared treatment, instead of the default all-runtime
  descent.

  Mutare classifies each position's context *positionally* — `:runtime` (mutate
  in place), `:pattern` (descend but don't mutate), and so on. Ordinary calls are
  routed by the lexical resolution pre-pass, but a *macro* whose argument is a
  pattern or an opaque DSL body looks like an ordinary call, so its args would be
  mutated as runtime values (a literal in `match?`'s pattern arg is a pattern, not
  a value — splicing a selector there is illegal and poisons the single build). A
  `Spec` teaches the transform how to treat each argument.

  ## Identity

  You write `module` the natural way — `Kernel`, `Ecto.Query`, `:binary` — and it
  is normalised to the key the transform uses internally. `arity` is a
  non-negative integer or `:any` (matches a call of any arity).

  ## Wildcards

  The glob atom `:*` (`wildcard/0`) means "match anything" in the **module**, **name**, or
  **arity** slot (in the arity slot `:*` is a synonym for `:any`, the canonical arity
  wildcard). Two compound forms fall out of it:

    * a **whole-module** entry — `:*` in the *name* slot (`{Ecto.Query, :*, :skip}`) — routes
      *every* macro in the module, at every arity. (It is therefore all-arities; pinning an
      arity alongside a name wildcard is rejected.)
    * a **name-only** escape hatch — `:*` in the *module* slot (`{:*, :sigil_X, :skip}`) — routes
      a macro of that name *regardless of which module exports it*. This is the fallback for when
      the module-resolution machinery can't see the macro's module (a `use`-injected import Mutare
      can't expand, an alias it can't follow); it is **not** the standard way to register a macro.

  `:*` is a *practically* collision-free sentinel — not a strictly impossible name. `*` *can*
  name a macro, function, or module: it is the multiplication operator `Kernel.*/2`, `defmodule :*`
  compiles, and a metaprogrammed `def unquote(:*)` works. But nobody registers the `*` operator as
  a known macro (operator handling is out of scope here), so in practice `:*` never collides —
  unlike `:any`, which is an ordinary, idiomatic identifier. Wildcarding *both* module and name
  (`{:*, :*, …}`) is rejected — that would route every macro everywhere.

  Lookup is **most-specific-wins** (see `Mutare.Macros.lookup/4`), so a specific
  `{Module, name, arity}` entry overrides a whole-module one, which overrides a name-only one;
  the name-only hatch is the last resort and never shadows a module-matched treatment (including
  the built-in `Kernel.match?`/`destructure`).

  ## Argument treatments

  `args` is either a single treatment atom (applied uniformly to every argument),
  a per-position list (padded with `:expression`), or the **classifier sentinel**
  `:routing` (see "Shape-aware routing" below). The treatments:

    * `:expression` (default) — an ordinary value: mutate it normally.
    * `:pattern` — a match context (`match?`'s first argument): descend so nested
      runtime expressions are still reached, but never mutate the pattern itself.
      Its bindings are local to the macro's expansion.
    * `:binding_pattern` — a `:pattern` whose bindings **escape into the enclosing
      scope** (`destructure([x, y], v)` binds `x`/`y` for the rest of the block).
      Routed like `:pattern`, but **additionally** earns structural swap/wildcard
      mutants when the call sits in a value-discarded position. The registrant
      vouches that the macro binds every variable named in the pattern and accepts
      pattern-legal swap/wildcard rewrites (`destructure` does).
    * `:skip` — leave the argument **raw**: no descent, no mutation. The opaque DSL
      case (`Ecto.Query.from`'s body). The whole macro node is still offered to
      every mutator, so a registering library's own mutator can still fire on it.
    * `:hosted` — like `:skip`, raw for core, but its mutations are delivered
      through the hosting mutator's `c:Mutare.Mutator.host/2` callback. The deep-DSL
      case (mutating *inside* `Ecto`'s `from`/`where`, where the fragment has SQL
      semantics, not Elixir's). Only valid when the spec carries a `host`.

  ## Shape-aware routing (the `:routing` classifier)

  A static per-position list can't express a treatment that depends on the *call shape*:
  `where(q, category: "Foo")` is plain data (mutate the value, `:expression`) while
  `where(q, [u], u.x == u.y)` is a `:hosted` DSL fragment. The sentinel `args: :routing`
  defers the per-position routing to the hosting mutator's `c:Mutare.Mutator.macro_routing/1`.
  Like `:hosted`, `:routing` is only valid with a `host`.

  The classifier may also return, for a **keyword-list argument**, the tuple
  `{:keyword, value_treatments}` — finer than the per-argument treatments here: core routes each
  pair's *value* by its own treatment and leaves the *keys* raw (a DSL keyword key is a field
  name, not a value), nesting for a keyword list of keyword lists. This is classifier-only — a
  static `args` entry cannot carry it. See `c:Mutare.Mutator.macro_routing/1`.

  ## Host

  `host` is the mutator module that delivers a `:hosted` argument's mutations and answers
  the `:routing` classifier — `nil` for an ordinary spec. It is **not** written on the
  entry: a mutator that registers a `:hosted`/`:routing` macro via
  `c:Mutare.Mutator.macros/0` is stamped as its own host automatically. A *declarative*
  `:macros` entry (no mutator) therefore can't use `:hosted`/`:routing`.
  """

  @typedoc """
  A resolved module key: an Elixir-module atom path, an Erlang-module atom, or the
  wildcard `:*` (a name-only entry, matching any module).
  """
  @type module_key :: [atom()] | atom()

  @typedoc "How one argument is routed."
  @type treatment :: :expression | :pattern | :binding_pattern | :skip | :hosted

  @typedoc "An `args` value: a uniform treatment, a per-position list, or the `:routing` classifier sentinel."
  @type args :: treatment() | [treatment()] | :routing

  @type t :: %__MODULE__{
          module: module_key(),
          name: atom(),
          arity: non_neg_integer() | :any,
          args: args(),
          host: module() | nil
        }

  @enforce_keys [:module, :name, :arity, :args]
  defstruct [:module, :name, :arity, :args, host: nil]

  @treatments [:expression, :pattern, :binding_pattern, :skip, :hosted]

  # The glob wildcard atom. Means "match anything" in the module, name, or arity slot.
  # Chosen as a sentinel because `*` is a vanishingly unlikely identifier to register — it *can*
  # name a macro/function/module (`Kernel.*/2`, `defmodule :*`, a metaprogrammed `def unquote(:*)`
  # all compile), but nothing registers the `*` operator as a known macro, so it never collides
  # in practice (unlike `:any`, an ordinary name).
  @wildcard :*

  @doc """
  The wildcard atom `:*` — "match anything" in a macro entry's module, name, or arity slot.

      iex> Mutare.Macro.Spec.wildcard()
      :*
  """
  @spec wildcard() :: :*
  def wildcard, do: @wildcard

  # The arg modes that require a `host` (a mutator implementing the delivery/classifier
  # callbacks): the `:hosted` treatment (delivered through `c:Mutare.Mutator.host/2`) and
  # the `:routing` classifier sentinel (resolved through `c:Mutare.Mutator.macro_routing/1`).
  @host_required [:hosted, :routing]

  @doc """
  The valid argument treatments — the single source of truth for validation.

      iex> Mutare.Macro.Spec.treatments()
      [:expression, :pattern, :binding_pattern, :skip, :hosted]
  """
  @spec treatments() :: [treatment()]
  def treatments, do: @treatments

  @doc """
  Whether `spec`'s `args` is the `:routing` classifier sentinel (resolved per call node by
  the hosting mutator's `c:Mutare.Mutator.macro_routing/1`), rather than a static treatment.

      iex> Mutare.Macro.Spec.new(Kernel, :match?, 2, :pattern) |> Mutare.Macro.Spec.classifier?()
      false
  """
  @spec classifier?(t()) :: boolean()
  def classifier?(%__MODULE__{args: :routing}), do: true
  def classifier?(%__MODULE__{}), do: false

  @doc """
  Whether `spec`'s static `args` mention a treatment that needs a `host` — a `:hosted`
  position, or the `:routing` classifier sentinel. Used by `Mutare.Macros.build/2` to
  reject a declarative `:macros` entry that asks for hosting it cannot deliver.
  """
  @spec host_required?(t()) :: boolean()
  def host_required?(%__MODULE__{args: args}) when args in @host_required, do: true

  def host_required?(%__MODULE__{args: args}) when is_list(args),
    do: Enum.any?(args, &(&1 in @host_required))

  def host_required?(%__MODULE__{}), do: false

  @doc "Stamp the hosting mutator module onto `spec` (`Mutare.Macros.from_mutators/1`)."
  @spec put_host(t(), module()) :: t()
  def put_host(%__MODULE__{} = spec, host) when is_atom(host), do: %{spec | host: host}

  @doc """
  Build a validated spec from a user-written `{module, name, arity, args}`.

  Normalizes `module` to its key and validates `name`/`arity`/`args`, raising
  `ArgumentError` on a malformed entry. Purely syntactic — never reflects on the
  module — so a spec for a module that is not a dependency of the Mutare process
  (e.g. `Ecto.Query`) resolves without `Ecto` loaded.

      iex> Mutare.Macro.Spec.new(Kernel, :match?, 2, [:pattern])
      %Mutare.Macro.Spec{module: [:Kernel], name: :match?, arity: 2, args: [:pattern]}

      iex> # a 3-tuple-style entry uses arity :any; `:skip` leaves every arg raw
      iex> Mutare.Macro.Spec.new(Ecto.Query, :from, :any, :skip)
      %Mutare.Macro.Spec{module: [:Ecto, :Query], name: :from, arity: :any, args: :skip}

      iex> # an Erlang-module atom is kept verbatim as the key
      iex> Mutare.Macro.Spec.new(:binary, :match, 2, :expression).module
      :binary

      iex> Mutare.Macro.Spec.new(Kernel, :match?, 2, :bogus)
      ** (ArgumentError) macro arg treatment must be one of [:expression, :pattern, :binding_pattern, :skip, :hosted] (a list of them, or :routing), got: :bogus

      iex> # a whole-module entry — `:*` in the name slot, any arity
      iex> Mutare.Macro.Spec.new(Ecto.Query, :*, :any, :skip)
      %Mutare.Macro.Spec{module: [:Ecto, :Query], name: :*, arity: :any, args: :skip}

      iex> # a name-only escape hatch — `:*` in the module slot
      iex> Mutare.Macro.Spec.new(:*, :sigil_X, :any, :skip)
      %Mutare.Macro.Spec{module: :*, name: :sigil_X, arity: :any, args: :skip}
  """
  @spec new(term(), term(), term(), term()) :: t()
  def new(module, name, arity, args) do
    module = normalize_module(module)
    name = validate_name(name)
    arity = validate_arity(arity)
    validate_wildcards!(module, name, arity)

    %__MODULE__{module: module, name: name, arity: arity, args: validate_args(args)}
  end

  # Reject the two nonsensical wildcard combinations, leaving the meaningful ones (whole module
  # `{Mod, :*, :any}` and name-only `{:*, name, arity|:any}`):
  #   * both module *and* name wildcarded — that would route every macro everywhere;
  #   * a name wildcard pinned to a specific arity — a whole-module entry matches at every arity
  #     (the lookup cascade only consults `{module, :*, :any}`), so an arity there is dead config.
  defp validate_wildcards!(@wildcard, @wildcard, _arity) do
    raise ArgumentError,
          "a macro entry cannot wildcard both the module and the name (#{inspect(@wildcard)} for " <>
            "both) — that would route every macro everywhere. Wildcard the module (a name-only " <>
            "escape hatch) or the name (a whole module), not both."
  end

  defp validate_wildcards!(_module, @wildcard, arity) when arity != :any do
    raise ArgumentError,
          "a whole-module macro entry ({module, #{inspect(@wildcard)}, …}) matches every macro at " <>
            "every arity, so it cannot also pin arity #{inspect(arity)}. Drop the arity (use the " <>
            "3-tuple form), or name a specific macro to pin its arity."
  end

  defp validate_wildcards!(_module, _name, _arity), do: :ok

  @doc """
  The lookup key `{module_key, name, arity}` — what `Mutare.Macros` keys its
  registry map on.

      iex> Mutare.Macro.Spec.new(Kernel, :match?, 2, [:pattern]) |> Mutare.Macro.Spec.key()
      {[:Kernel], :match?, 2}
  """
  @spec key(t()) :: {module_key(), atom(), non_neg_integer() | :any}
  def key(%__MODULE__{module: module, name: name, arity: arity}), do: {module, name, arity}

  @doc """
  The per-position treatment list for a call of `count` visible arguments. A
  uniform-atom `args` repeats; a list `args` is padded with `:expression` (and
  truncated to `count`).

      iex> # a uniform-atom treatment repeats for every argument
      iex> Mutare.Macro.Spec.new(Ecto.Query, :from, :any, :skip) |> Mutare.Macro.Spec.routing(2)
      [:skip, :skip]

      iex> # a per-position list is padded with :expression for the trailing args
      iex> Mutare.Macro.Spec.new(Kernel, :match?, 2, [:pattern]) |> Mutare.Macro.Spec.routing(3)
      [:pattern, :expression, :expression]
  """
  @spec routing(t(), non_neg_integer()) :: [treatment()]
  def routing(%__MODULE__{args: :routing}, _count) do
    raise ArgumentError,
          "a :routing macro spec is resolved per call node by its host's macro_routing/1 " <>
            "(Mutare.Transform.Resolve), not by Mutare.Macro.Spec.routing/2"
  end

  def routing(%__MODULE__{args: args}, count), do: expand_args(args, count)

  defp expand_args(treatment, count) when is_atom(treatment), do: List.duplicate(treatment, count)

  # Take the first `count` per-position treatments, padding any shortfall with the `:expression`
  # default (a position the list doesn't name is an ordinary mutatable argument).
  defp expand_args(list, count) when is_list(list) do
    taken = Enum.take(list, count)
    taken ++ List.duplicate(:expression, count - length(taken))
  end

  @doc """
  Normalize a user-written module reference to a key.

    * an Elixir-module alias atom (`Ecto.Query`, `Kernel`) → its `Module.split/1`
      path as atoms (`[:Ecto, :Query]`, `[:Kernel]`);
    * an Erlang-module atom (`:binary`) → itself;
    * an already-normalized atom list (`[:Ecto, :Query]`) → itself.

      iex> Mutare.Macro.Spec.normalize_module(Ecto.Query)
      [:Ecto, :Query]
      iex> Mutare.Macro.Spec.normalize_module(:binary)
      :binary
      iex> Mutare.Macro.Spec.normalize_module([:Ecto, :Query])
      [:Ecto, :Query]

      iex> # the module wildcard is kept as-is (a name-only escape hatch)
      iex> Mutare.Macro.Spec.normalize_module(:*)
      :*
  """
  @spec normalize_module(term()) :: module_key()
  def normalize_module(@wildcard), do: @wildcard

  def normalize_module(module) when is_atom(module) do
    case Macro.classify_atom(module) do
      :alias -> module |> Module.split() |> Enum.map(&String.to_atom/1)
      _ -> module
    end
  end

  def normalize_module(list) when is_list(list) and list != [] do
    if Enum.all?(list, &is_atom/1) do
      list
    else
      raise ArgumentError, "macro module path must be a list of atoms, got: #{inspect(list)}"
    end
  end

  def normalize_module(other) do
    raise ArgumentError,
          "macro module must be a module (Kernel, Ecto.Query), an Erlang atom " <>
            "(:binary), or an atom path ([:Ecto, :Query]), got: #{inspect(other)}"
  end

  defp validate_name(name) when is_atom(name), do: name

  defp validate_name(other),
    do: raise(ArgumentError, "macro name must be an atom, got: #{inspect(other)}")

  defp validate_arity(:any), do: :any
  # `:*` is the universal wildcard; in the arity slot it is a synonym for the canonical `:any`.
  defp validate_arity(@wildcard), do: :any
  defp validate_arity(arity) when is_integer(arity) and arity >= 0, do: arity

  defp validate_arity(other) do
    raise ArgumentError,
          "macro arity must be a non-negative integer or :any, got: #{inspect(other)}"
  end

  defp validate_args(:routing), do: :routing
  defp validate_args(treatment) when treatment in @treatments, do: treatment

  defp validate_args(list) when is_list(list) do
    Enum.each(list, fn
      t when t in @treatments -> :ok
      other -> raise ArgumentError, bad_treatment_message(other)
    end)

    list
  end

  defp validate_args(other), do: raise(ArgumentError, bad_treatment_message(other))

  defp bad_treatment_message(other) do
    "macro arg treatment must be one of #{inspect(@treatments)} " <>
      "(a list of them, or :routing), got: #{inspect(other)}"
  end
end
