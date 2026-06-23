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

  `module` is the resolved module **key** the way the rest of the transform keys
  modules (`Mutare.Transform.Calls.module_key`): an Elixir-module path as an atom
  list *without* the `Elixir.` prefix (`[:Kernel]`, `[:Ecto, :Query]`), or an
  Erlang-module atom (`:binary`). A user writes the module the natural way
  (`Kernel`, `Ecto.Query`, `:binary`); `normalize_module/1` converts it to the key.
  `arity` is a non-negative integer or `:any` (matches a call of any arity).

  ## Argument treatments

  `args` is either a single treatment atom (applied uniformly to every argument),
  a per-position list (padded with `:expression`), or the **classifier sentinel**
  `:routing` (see "Shape-aware routing" below). The treatments and how the analyzer
  routes each:

    * `:expression` (default) — analyze as `:runtime` (mutate normally).
    * `:pattern` — analyze as `:pattern` (descend so nested runtime escapes are
      still reached, but never mutate the pattern itself). `match?`. The bindings the
      pattern makes are **local** to the macro's expansion (a `case`/`fn`), so they do
      not escape and the structural families have no observable swap to offer here.
    * `:binding_pattern` — a `:pattern` whose bindings **escape into the enclosing
      scope** (`destructure([x, y], v)` binds `x`/`y` for the rest of the block). Routed
      exactly like `:pattern` for the in-place descent, but **additionally** offered to the
      structural pattern families (swap/wildcard) when the macro call sits in a
      *value-discarded* position — a non-final block statement or a `with` clause — where
      the mutant is delivered by re-exporting the escaping bindings through a tuple
      (`Mutare.Transform.emit_macro_pattern_site/3`), the `=`-match analogue. The
      registrant vouches that the macro binds every variable named in the pattern and
      accepts pattern-legal swap/wildcard rewrites (`destructure` does).
    * `:skip` — leave the argument **raw**: no descent, no mutation. The opaque
      DSL case (`Ecto.Query.from`'s body), and the mechanism behind "handled only
      by a custom mutator" — core skips the args, while the whole macro node is
      still offered to every mutator, so a registering library's mutator fires.
    * `:hosted` — like `:skip`, the argument is left **raw** for core (no descent, no
      in-place selector — a `case` spliced into a compile-time DSL fragment would poison
      the single build), but its mutations are instead delivered through the **hosting
      mutator's selector host** (`c:Mutare.Mutator.host/2`): core hands the whole macro
      node to the host, which returns `{logical original, logical mutants}` plus `wrap`/
      `splice` transforms, and core builds the id-gated selector, records the Site from
      the logical pair, and weaves it in. The deep-DSL case (mutating *inside* `Ecto`'s
      `from`/`where`, where the fragment has SQL semantics, not Elixir's). A `:hosted`
      treatment is only valid when the spec carries a `host` — a mutator implementing
      `c:Mutare.Mutator.host/2` — which `Mutare.Macros.from_mutators/1` stamps for the
      registering mutator. See `Mutare.Transform.emit_hosted_site/3`.

  ## Shape-aware routing (the `:routing` classifier)

  A static per-position list can't express a treatment that depends on the *call shape*:
  `where(q, category: "Foo")` is plain data (mutate the value, `:expression`) while
  `where(q, [u], u.x == u.y)` is a `:hosted` DSL fragment. The sentinel `args: :routing`
  defers the per-position routing to the hosting mutator's `c:Mutare.Mutator.macro_routing/1`,
  which `Mutare.Transform.Resolve` consults with the concrete call node. Like `:hosted`,
  `:routing` is only valid with a `host`.

  `routing/2` expands a *static* `args` to a per-position list for a concrete arity; a
  `:routing` spec is resolved by `Mutare.Transform.Resolve` (which has the call node), not
  here.

  ## Host

  `host` is the mutator module that delivers a `:hosted` argument's mutations and answers
  the `:routing` classifier — `nil` for an ordinary spec. It is **not** user-written on the
  entry: `Mutare.Macros.from_mutators/1` stamps it to the mutator whose `c:Mutare.Mutator.macros/0`
  contributed the spec, so a library's `:hosted`/`:routing` registration automatically points
  back at the library's own host/classifier callbacks. A declarative `:macros` entry (no
  mutator) therefore can't use `:hosted`/`:routing` — `Mutare.Macros.build/2` raises if it does.
  """

  @typedoc "A resolved module key: an Elixir-module atom path or an Erlang-module atom."
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
  """
  @spec new(term(), term(), term(), term()) :: t()
  def new(module, name, arity, args) do
    %__MODULE__{
      module: normalize_module(module),
      name: validate_name(name),
      arity: validate_arity(arity),
      args: validate_args(args)
    }
  end

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

  defp expand_args(list, count) when is_list(list),
    do: Enum.map(0..(count - 1)//1, &Enum.at(list, &1, :expression))

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
  """
  @spec normalize_module(term()) :: module_key()
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
