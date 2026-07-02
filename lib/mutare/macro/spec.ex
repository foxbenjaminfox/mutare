defmodule Mutare.Macro.Spec do
  @moduledoc false

  # Internal normalized representation of a public `Mutare.MacroRouting.route/0` tuple.
  # Resolution keys and registry helpers deliberately stay out of the extension contract.

  @typedoc """
  A resolved module key: an Elixir-module atom path, an Erlang-module atom, or the
  wildcard `:*` (a name-only entry, matching any module).
  """
  # Structurally the same shape as `Mutare.Transform.Aliases.module_key/0` (the resolution
  # layer's canonical type), but kept local on purpose: `Mutare.Macro.Spec` is consumed *by* the
  # transform and stays free of any dependency on it, so it can't reference that type without
  # inverting the layering. The `:*` wildcard is this registry's own addition (an `atom()`).
  @type module_key :: [atom()] | atom()

  @typedoc false
  @type treatment :: Mutare.MacroRouting.treatment()

  @typedoc "An `args` value: a uniform treatment, a per-position list, or the `:routing` classifier sentinel."
  @type args :: treatment() | [treatment()] | :routing

  @type t :: %__MODULE__{
          module: module_key(),
          name: atom(),
          arity: non_neg_integer() | :any,
          args: args()
        }

  @enforce_keys [:module, :name, :arity, :args]
  defstruct [:module, :name, :arity, :args]

  @treatments [:expression, :pattern, :binding_pattern, :skip, :hosted, :pinned]

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
      [:expression, :pattern, :binding_pattern, :skip, :hosted, :pinned]
  """
  @spec treatments() :: [treatment()]
  def treatments, do: @treatments

  @doc """
  Whether `spec`'s `args` is the `:routing` classifier sentinel (resolved per call node by
  its router's `c:Mutare.MacroRouting.route_arguments/2`), rather than a static treatment.

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
  def host_required?(%__MODULE__{args: :routing}), do: false
  def host_required?(%__MODULE__{args: args}), do: hosted?(args)

  @doc """
  Returns whether a static route uses an adapter-grade treatment — `:pinned`, `:hosted`, or
  `{:keyword, …}` — the tier reserved for code providers implementing `Mutare.MacroRouting`.

  The `:routing` classifier is adapter-grade too, but is rejected on its own terms (it needs a
  `route_arguments/2` callback, which configuration cannot supply), so it returns `false` here.
  """
  @spec adapter_graded?(t()) :: boolean()
  def adapter_graded?(%__MODULE__{args: :routing}), do: false

  def adapter_graded?(%__MODULE__{args: args}) when is_list(args),
    do: Enum.any?(args, &adapter_treatment?/1)

  def adapter_graded?(%__MODULE__{args: treatment}), do: adapter_treatment?(treatment)

  # `{:keyword, …}` is adapter-grade at its wrapper, so nested values need no recursion here.
  defp adapter_treatment?(:hosted), do: true
  defp adapter_treatment?(:pinned), do: true
  defp adapter_treatment?({:keyword, _treatments}), do: true
  defp adapter_treatment?(_treatment), do: false

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
          "a :routing macro spec is resolved per call node by its router's route_arguments/2 " <>
            "(Mutare.Transform.Resolve), not by Mutare.Macro.Spec.routing/2"
  end

  def routing(%__MODULE__{args: args}, count), do: expand_args(args, count)

  defp expand_args(treatment, count) when not is_list(treatment),
    do: List.duplicate(treatment, count)

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

  defp validate_args(list) when is_list(list) do
    Enum.each(list, &validate_treatment!/1)

    list
  end

  defp validate_args(treatment), do: validate_treatment!(treatment)

  defp validate_treatment!(treatment) when treatment in @treatments, do: treatment

  defp validate_treatment!({:keyword, treatments} = treatment) when is_list(treatments) do
    Enum.each(treatments, &validate_treatment!/1)
    treatment
  end

  defp validate_treatment!(other), do: raise(ArgumentError, bad_treatment_message(other))

  defp bad_treatment_message(other) do
    "macro arg treatment must be one of #{inspect(@treatments)}, " <>
      "{:keyword, [treatments]}, a list of treatments, or :routing; got: #{inspect(other)}"
  end

  defp hosted?(:hosted), do: true
  defp hosted?({:keyword, treatments}), do: Enum.any?(treatments, &hosted?/1)
  defp hosted?(treatments) when is_list(treatments), do: Enum.any?(treatments, &hosted?/1)
  defp hosted?(_), do: false
end
