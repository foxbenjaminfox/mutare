defmodule Mutare.Macro.Spec do
  @moduledoc """
  A validated macro-argument routing entry.

  Macro arguments may be runtime expressions, patterns, or compile-time DSL fragments. A spec
  tells Mutare how to handle each argument instead of treating every argument as runtime code.

  Entries are written as `{module, name, arity, treatment}`, or `{module, name, treatment}` to
  match any arity. A treatment atom applies to every argument; a list assigns treatments by
  position and is padded with `:expression`.

  The treatments are:

    * `:expression` — mutate ordinary runtime code;
    * `:pattern` — descend as a match pattern without mutating the pattern itself;
    * `:binding_pattern` — a pattern whose bindings escape into the enclosing scope; in a
      value-discarded position it is also eligible for structural pattern mutations;
    * `:skip` — leave an opaque argument untouched;
    * `:hosted` — leave the argument raw for core and delegate its mutations to a
      `Mutare.Mutator.MacroHost`.

  ## Wildcards

  `:*` in the name position matches every macro in a module. In the module position it matches a
  macro name regardless of module, as a fallback when module resolution is unavailable. Specific
  entries take precedence over wildcards; a whole-module entry takes precedence over a name-only
  entry. Wildcarding both module and name is invalid.

  ## Shape-aware routing (the `:routing` classifier)

  A module implementing `Mutare.MacroRouting` may register `:routing` and classify each call with
  `c:Mutare.MacroRouting.macro_routing/1`. Declarative `:macro_routes` configuration is static and
  therefore cannot use `:routing` or `:hosted`.
  """

  @typedoc """
  A resolved module key: an Elixir-module atom path, an Erlang-module atom, or the
  wildcard `:*` (a name-only entry, matching any module).
  """
  # Structurally the same shape as `Mutare.Transform.Aliases.module_key/0` (the resolution
  # layer's canonical type), but kept local on purpose: `Mutare.Macro.Spec` is consumed *by* the
  # transform and stays free of any dependency on it, so it can't reference that type without
  # inverting the layering. The `:*` wildcard is this registry's own addition (an `atom()`).
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
          router: module() | nil,
          host: module() | nil
        }

  @enforce_keys [:module, :name, :arity, :args]
  defstruct [:module, :name, :arity, :args, router: nil, host: nil]

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

  @doc """
  The valid argument treatments.

      iex> Mutare.Macro.Spec.treatments()
      [:expression, :pattern, :binding_pattern, :skip, :hosted]
  """
  @spec treatments() :: [treatment()]
  def treatments, do: @treatments

  @doc """
  Returns whether the spec uses shape-aware `:routing`.

      iex> Mutare.Macro.Spec.new(Kernel, :match?, 2, :pattern)
      ...> |> Mutare.Macro.Spec.classifier?()
      false
  """
  @spec classifier?(t()) :: boolean()
  def classifier?(%__MODULE__{args: :routing}), do: true
  def classifier?(%__MODULE__{}), do: false

  @doc """
  Returns whether a static route contains a `:hosted` argument.

  Shape-aware routes are classified per call and therefore return `false` here.
  """
  @spec host_required?(t()) :: boolean()
  def host_required?(%__MODULE__{args: :hosted}), do: true

  def host_required?(%__MODULE__{args: args}) when is_list(args),
    do: Enum.any?(args, &(&1 == :hosted))

  def host_required?(%__MODULE__{}), do: false

  @doc "Returns `spec` with its shape-aware router module set."
  @spec put_router(t(), module()) :: t()
  def put_router(%__MODULE__{} = spec, router) when is_atom(router),
    do: %{spec | router: router}

  @doc "Returns `spec` with its selector-hosting mutator module set."
  @spec put_host(t(), module()) :: t()
  def put_host(%__MODULE__{} = spec, host) when is_atom(host), do: %{spec | host: host}

  @doc """
  Builds and validates a macro route spec.

  `module` is normalized to its lookup key. `name`, `arity`, and `args` are
  validated without loading or reflecting on the target module.

      iex> Mutare.Macro.Spec.new(Kernel, :match?, 2, [:pattern])
      %Mutare.Macro.Spec{module: [:Kernel], name: :match?, arity: 2, args: [:pattern]}

      iex> Mutare.Macro.Spec.new(Ecto.Query, :from, :any, :skip)
      %Mutare.Macro.Spec{module: [:Ecto, :Query], name: :from, arity: :any, args: :skip}

      iex> Mutare.Macro.Spec.new(:binary, :match, 2, :expression).module
      :binary

      iex> Mutare.Macro.Spec.new(Ecto.Query, :*, :any, :skip)
      %Mutare.Macro.Spec{module: [:Ecto, :Query], name: :*, arity: :any, args: :skip}
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
  The lookup key `{module_key, name, arity}` — what `Mutare.MacroRouting.Registry` keys its
  registry map on.

      iex> Mutare.Macro.Spec.new(Kernel, :match?, 2, [:pattern]) |> Mutare.Macro.Spec.key()
      {[:Kernel], :match?, 2}
  """
  @spec key(t()) :: {module_key(), atom(), non_neg_integer() | :any}
  def key(%__MODULE__{module: module, name: name, arity: arity}), do: {module, name, arity}

  @doc """
  Returns the treatment for each of `count` visible arguments.

  A single treatment is repeated. A treatment list is padded with `:expression`
  or truncated to the requested length.

      iex> Mutare.Macro.Spec.new(Ecto.Query, :from, :any, :skip)
      ...> |> Mutare.Macro.Spec.routing(2)
      [:skip, :skip]

      iex> Mutare.Macro.Spec.new(Kernel, :match?, 2, [:pattern])
      ...> |> Mutare.Macro.Spec.routing(3)
      [:pattern, :expression, :expression]
  """
  @spec routing(t(), non_neg_integer()) :: [treatment()]
  def routing(%__MODULE__{args: :routing}, _count) do
    raise ArgumentError,
          "a :routing macro spec is resolved per call node by its router's macro_routing/1 " <>
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
  Normalizes a module reference for route lookup.

    * Elixir module atoms become alias-path lists
    * Erlang module atoms remain atoms
    * normalized non-empty atom lists pass through unchanged
    * the `:*` wildcard remains `:*`

      iex> Mutare.Macro.Spec.normalize_module(Ecto.Query)
      [:Ecto, :Query]
      iex> Mutare.Macro.Spec.normalize_module(:binary)
      :binary
      iex> Mutare.Macro.Spec.normalize_module([:Ecto, :Query])
      [:Ecto, :Query]
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
