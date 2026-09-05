defmodule Mutare.CallRouting.Spec do
  @moduledoc false

  # Internal normalized representation of a public `Mutare.CallRouting.route/0` tuple.
  # Resolution keys and registry helpers deliberately stay out of the extension contract.
  #
  # A route's `args` is one of:
  #
  #   * the call-level `:skip` — the whole call is an **inert leaf**: the node is never offered to
  #     the mutators and nothing inside its parentheses is descended (a piped receiver is a sibling
  #     of the call, not part of it, so it is analyzed as usual). Bare only — a `:skip` inside a
  #     per-position list is rejected with a message naming `:raw`;
  #   * a uniform argument *treatment*, applied to every position;
  #   * a per-position list of *positions* (padded with `:expression`);
  #   * the `:routing` classifier sentinel (resolved per call by `route_arguments/2`).
  #
  # A *position* is an argument treatment, a `{:keyword, [position]}` per-pair routing (adapter
  # grade), or a **keyed refinement** — written `[leading, key: position, …]` (the leading treatment
  # optional, defaulting to `:expression`) and normalized here to `{:keyed, leading, [{key,
  # position}]}` so downstream code never confuses a refinement with the per-position list it sits
  # in. The refinement means: treat the argument by `leading`, and when it is written as a literal
  # keyword list, route the *value* of each named key by its own position instead (nothing else
  # changes — the key, the sibling pairs, and the list itself follow `leading`). See NOTES "Call
  # routing: `:skip`, `:raw`, `:interior`, keyed refinements".

  @typedoc """
  A resolved module key: an Elixir-module atom path, an Erlang-module atom, or the
  wildcard `:*` (a name-only entry, matching any module).
  """
  # Structurally the same shape as `Mutare.Transform.Aliases.module_key/0` (the resolution
  # layer's canonical type), but kept local on purpose: `Mutare.CallRouting.Spec` is consumed *by* the
  # transform and stays free of any dependency on it, so it can't reference that type without
  # inverting the layering. The `:*` wildcard is this registry's own addition (an `atom()`).
  @type module_key :: [atom()] | atom()

  @typedoc false
  @type treatment :: Mutare.CallRouting.treatment()

  @typedoc "A normalized position: a treatment, a per-pair keyword routing, or a keyed refinement."
  @type position ::
          atom()
          | {:keyword, [position()]}
          | {:keyed, atom(), [{atom(), position()}]}
          | {:hosted, [module()]}

  @typedoc """
  An `args` value: the call-level `:skip`, a uniform treatment, a per-position list, or the
  `:routing` classifier sentinel.
  """
  @type args :: :skip | atom() | [position()] | :routing

  @type t :: %__MODULE__{
          module: module_key(),
          name: atom(),
          arity: non_neg_integer() | :any,
          args: args()
        }

  @enforce_keys [:module, :name, :arity, :args]
  defstruct [:module, :name, :arity, :args]

  # The argument treatments — what a *position* may be. `:skip` is deliberately absent: it is the
  # call-level word, valid only as a route's bare `args`.
  @treatments [:expression, :interior, :raw, :pattern, :binding_pattern, :hosted, :interpolated]
  @call_skip :skip

  # The glob wildcard atom. Means "match anything" in the module, name, or arity slot.
  # Chosen as a sentinel because `*` is a vanishingly unlikely identifier to register — it *can*
  # name a macro/function/module (`Kernel.*/2`, `defmodule :*`, a metaprogrammed `def unquote(:*)`
  # all compile), but nothing registers the `*` operator as a routed call, so it never collides
  # in practice (unlike `:any`, an ordinary name).
  @wildcard :*

  @doc """
  The wildcard atom `:*` — "match anything" in a route entry's module, name, or arity slot.

      iex> Mutare.CallRouting.Spec.wildcard()
      :*
  """
  @spec wildcard() :: :*
  def wildcard, do: @wildcard

  @doc """
  The valid argument treatments — the words a *position* may carry. The call-level `:skip` is not
  among them (see `skip?/1`).

      iex> Mutare.CallRouting.Spec.treatments()
      [:expression, :interior, :raw, :pattern, :binding_pattern, :hosted, :interpolated]
  """
  @spec treatments() :: [treatment()]
  def treatments, do: @treatments

  @doc """
  Whether `spec` skips the whole call (`args: :skip`) — the inert-leaf route: no whole-node offer,
  no descent into the arguments.

      iex> Mutare.CallRouting.Spec.new(Mixpanel, :track, 3, :skip) |> Mutare.CallRouting.Spec.skip?()
      true
      iex> Mutare.CallRouting.Spec.new(Ecto.Query, :from, :any, :raw) |> Mutare.CallRouting.Spec.skip?()
      false
  """
  @spec skip?(t()) :: boolean()
  def skip?(%__MODULE__{args: @call_skip}), do: true
  def skip?(%__MODULE__{}), do: false

  @doc """
  Whether `spec`'s `args` is the `:routing` classifier sentinel (resolved per call node by
  its router's `c:Mutare.CallRouting.route_arguments/2`), rather than a static treatment.

      iex> Mutare.CallRouting.Spec.new(Kernel, :match?, 2, :pattern)
      ...> |> Mutare.CallRouting.Spec.classifier?()
      false
  """
  @spec classifier?(t()) :: boolean()
  def classifier?(%__MODULE__{args: :routing}), do: true
  def classifier?(%__MODULE__{}), do: false

  @doc """
  Returns whether a static route contains a `:hosted` argument (at any depth — inside a
  `{:keyword, …}` per-pair routing or a keyed refinement too).

  Shape-aware routes are classified per call and therefore return `false` here, as does a
  call-level `:skip` (nothing inside a skipped call is offered to anyone).
  """
  @spec host_required?(t()) :: boolean()
  def host_required?(%__MODULE__{args: :routing}), do: false
  def host_required?(%__MODULE__{args: @call_skip}), do: false
  def host_required?(%__MODULE__{args: args}), do: hosted?(args)

  @doc """
  Returns whether a static route uses an adapter-grade treatment — `:interpolated`, `:hosted`, or
  `{:keyword, …}` — the tier reserved for code providers implementing `Mutare.CallRouting`. A keyed
  refinement is graded by its contents (`[:expression, x: :interpolated]` is adapter-grade;
  `[:expression, timeout: :raw]` is not).

  The `:routing` classifier is adapter-grade too, but is rejected on its own terms (it needs a
  `route_arguments/2` callback, which configuration cannot supply), so it returns `false` here.
  """
  @spec adapter_graded?(t()) :: boolean()
  def adapter_graded?(%__MODULE__{args: :routing}), do: false
  def adapter_graded?(%__MODULE__{args: @call_skip}), do: false

  def adapter_graded?(%__MODULE__{args: args}) when is_list(args),
    do: Enum.any?(args, &adapter_treatment?/1)

  def adapter_graded?(%__MODULE__{args: treatment}), do: adapter_treatment?(treatment)

  # `{:keyword, …}` is adapter-grade at its wrapper, so nested values need no recursion here; a
  # keyed refinement is user-tier at its wrapper, so its leading treatment and values are checked.
  defp adapter_treatment?(:hosted), do: true
  defp adapter_treatment?(:interpolated), do: true
  defp adapter_treatment?({:keyword, _treatments}), do: true

  defp adapter_treatment?({:keyed, leading, pairs}),
    do: adapter_treatment?(leading) or Enum.any?(pairs, fn {_k, p} -> adapter_treatment?(p) end)

  defp adapter_treatment?(_treatment), do: false

  @doc """
  Builds and validates a call route spec.

  `module` is normalized to its lookup key. `name`, `arity`, and `args` are
  validated without loading or reflecting on the target module. Per-position lists are
  normalized (a keyed refinement `[leading, key: position, …]` becomes
  `{:keyed, leading, pairs}`).

      iex> Mutare.CallRouting.Spec.new(Kernel, :match?, 2, [:pattern])
      %Mutare.CallRouting.Spec{module: [:Kernel], name: :match?, arity: 2, args: [:pattern]}

      iex> Mutare.CallRouting.Spec.new(Ecto.Query, :from, :any, :raw)
      %Mutare.CallRouting.Spec{module: [:Ecto, :Query], name: :from, arity: :any, args: :raw}

      iex> Mutare.CallRouting.Spec.new(Mixpanel, :track, 3, :skip)
      %Mutare.CallRouting.Spec{module: [:Mixpanel], name: :track, arity: 3, args: :skip}

      iex> Mutare.CallRouting.Spec.new(MyApp.Http, :get, 2, [:expression, [timeout: :raw]]).args
      [:expression, {:keyed, :expression, [timeout: :raw]}]

      iex> Mutare.CallRouting.Spec.new(:binary, :match, 2, :expression).module
      :binary

      iex> Mutare.CallRouting.Spec.new(Ecto.Query, :*, :any, :raw)
      %Mutare.CallRouting.Spec{module: [:Ecto, :Query], name: :*, arity: :any, args: :raw}
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
  #   * both module *and* name wildcarded — that would route every call everywhere;
  #   * a name wildcard pinned to a specific arity — a whole-module entry matches at every arity
  #     (the lookup cascade only consults `{module, :*, :any}`), so an arity there is dead config.
  defp validate_wildcards!(@wildcard, @wildcard, _arity) do
    raise ArgumentError,
          "a call route cannot wildcard both the module and the name (#{inspect(@wildcard)} for " <>
            "both) — that would route every call everywhere. Wildcard the module (a name-only " <>
            "escape hatch) or the name (a whole module), not both."
  end

  defp validate_wildcards!(_module, @wildcard, arity) when arity != :any do
    raise ArgumentError,
          "a whole-module call route ({module, #{inspect(@wildcard)}, …}) matches every call at " <>
            "every arity, so it cannot also pin arity #{inspect(arity)}. Drop the arity (use the " <>
            "3-tuple form), or name a specific function to pin its arity."
  end

  defp validate_wildcards!(_module, _name, _arity), do: :ok

  @doc """
  The lookup key `{module_key, name, arity}` — what `Mutare.CallRouting.Registry` keys its
  registry map on.

      iex> Mutare.CallRouting.Spec.new(Kernel, :match?, 2, [:pattern]) |> Mutare.CallRouting.Spec.key()
      {[:Kernel], :match?, 2}
  """
  @spec key(t()) :: {module_key(), atom(), non_neg_integer() | :any}
  def key(%__MODULE__{module: module, name: name, arity: arity}), do: {module, name, arity}

  @doc """
  Returns the position for each of `count` visible arguments, or the call-level `:skip`.

  A single treatment is repeated. A per-position list is padded with `:expression`
  or truncated to the requested length.

      iex> Mutare.CallRouting.Spec.new(Ecto.Query, :from, :any, :raw)
      ...> |> Mutare.CallRouting.Spec.routing(2)
      [:raw, :raw]

      iex> Mutare.CallRouting.Spec.new(Kernel, :match?, 2, [:pattern])
      ...> |> Mutare.CallRouting.Spec.routing(3)
      [:pattern, :expression, :expression]

      iex> Mutare.CallRouting.Spec.new(Mixpanel, :track, 3, :skip)
      ...> |> Mutare.CallRouting.Spec.routing(3)
      :skip
  """
  @spec routing(t(), non_neg_integer()) :: [position()] | :skip
  def routing(%__MODULE__{args: :routing}, _count) do
    raise ArgumentError,
          "a :routing call route is resolved per call node by its router's route_arguments/2 " <>
            "(Mutare.Transform.Resolve), not by Mutare.CallRouting.Spec.routing/2"
  end

  def routing(%__MODULE__{args: @call_skip}, _count), do: @call_skip
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

      iex> Mutare.CallRouting.Spec.normalize_module(Ecto.Query)
      [:Ecto, :Query]
      iex> Mutare.CallRouting.Spec.normalize_module(:binary)
      :binary
      iex> Mutare.CallRouting.Spec.normalize_module([:Ecto, :Query])
      [:Ecto, :Query]
  """
  @spec normalize_module(term()) :: module_key()
  def normalize_module(@wildcard), do: @wildcard

  # The atom clause mirrors `Mutare.Transform.Aliases.from_module/1` (the encoding's
  # transform-layer home) — duplicated here for the same layering reason as the
  # `module_key` type above.
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
      raise ArgumentError, "call route module path must be a list of atoms, got: #{inspect(list)}"
    end
  end

  def normalize_module(other) do
    raise ArgumentError,
          "call route module must be a module (Kernel, Ecto.Query), an Erlang atom " <>
            "(:binary), or an atom path ([:Ecto, :Query]), got: #{inspect(other)}"
  end

  defp validate_name(name) when is_atom(name), do: name

  defp validate_name(other),
    do: raise(ArgumentError, "call route name must be an atom, got: #{inspect(other)}")

  defp validate_arity(:any), do: :any
  # `:*` is the universal wildcard; in the arity slot it is a synonym for the canonical `:any`.
  defp validate_arity(@wildcard), do: :any
  defp validate_arity(arity) when is_integer(arity) and arity >= 0, do: arity

  defp validate_arity(other) do
    raise ArgumentError,
          "call route arity must be a non-negative integer or :any, got: #{inspect(other)}"
  end

  # --- positions -------------------------------------------------------------

  defp validate_args(:routing), do: :routing
  defp validate_args(@call_skip), do: @call_skip
  defp validate_args(list) when is_list(list), do: Enum.map(list, &normalize_position!/1)
  defp validate_args(treatment), do: normalize_position!(treatment)

  @doc """
  Validate and normalize one author-written *position*: an argument treatment, a
  `{:keyword, [position]}` per-pair routing, or a keyed refinement `[leading, key: position, …]`
  (normalized to `{:keyed, leading, pairs}`). Raises `ArgumentError` with a pointed message on
  anything else — including the call-level `:skip`, which is only valid as a route's bare `args`.

      iex> Mutare.CallRouting.Spec.normalize_position!(:raw)
      :raw
      iex> Mutare.CallRouting.Spec.normalize_position!([timeout: :raw])
      {:keyed, :expression, [timeout: :raw]}
      iex> Mutare.CallRouting.Spec.normalize_position!([:raw, limit: :expression])
      {:keyed, :raw, [limit: :expression]}
      iex> Mutare.CallRouting.Spec.normalize_position!({:keyword, [:interpolated, :raw]})
      {:keyword, [:interpolated, :raw]}
  """
  @spec normalize_position!(term()) :: position()
  def normalize_position!(treatment) when treatment in @treatments, do: treatment

  def normalize_position!(@call_skip) do
    raise ArgumentError,
          ":skip skips a whole call and is only valid as a route's bare treatment " <>
            "({Module, :fun, arity, :skip}); to leave one argument as written, use :raw"
  end

  # Already normalized (a `:hosted` the resolver rewrote to `{:hosted, hosts}`, or a keyed
  # refinement passing through a second validation) — accepted as-is.
  def normalize_position!({:hosted, hosts} = position) when is_list(hosts), do: position

  def normalize_position!({:keyed, leading, pairs} = position)
      when is_atom(leading) and is_list(pairs) do
    normalize_keyed!([leading | pairs])
    position
  end

  def normalize_position!({:keyword, positions}) when is_list(positions),
    do: {:keyword, Enum.map(positions, &normalize_position!/1)}

  def normalize_position!(list) when is_list(list), do: normalize_keyed!(list)
  def normalize_position!(other), do: raise(ArgumentError, bad_treatment_message(other))

  # A keyed refinement: `[leading?, key: position, …]`. The leading treatment defaults to
  # `:expression`; the pairs are non-empty, atom-keyed, unique, and recursively normalized.
  defp normalize_keyed!([]) do
    raise ArgumentError,
          "an empty list is not a position: write a treatment (#{inspect(@treatments)}) or a " <>
            "keyed refinement [treatment, key: treatment, ...]"
  end

  defp normalize_keyed!([leading | pairs]) when is_atom(leading) do
    normalize_keyed!(normalize_position!(leading), pairs)
  end

  defp normalize_keyed!(pairs), do: normalize_keyed!(:expression, pairs)

  defp normalize_keyed!(_leading, []) do
    raise ArgumentError,
          "a keyed refinement names at least one key: [treatment, key: treatment, ...]; a " <>
            "position that refines nothing is just its treatment"
  end

  defp normalize_keyed!(leading, pairs) do
    unless Enum.all?(pairs, &match?({k, _} when is_atom(k), &1)) do
      raise ArgumentError,
            "a keyed refinement is [treatment, key: treatment, ...] — one optional leading " <>
              "treatment, then atom-keyed pairs; got: #{inspect([leading | pairs])}"
    end

    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) != length(keys) do
      raise ArgumentError,
            "a keyed refinement names each key once, got: #{inspect([leading | pairs])}"
    end

    {:keyed, leading,
     Enum.map(pairs, fn {key, position} -> {key, normalize_position!(position)} end)}
  end

  defp bad_treatment_message(other) do
    "call route treatment must be one of #{inspect(@treatments)} (or :skip for the whole " <>
      "call), a keyed refinement [treatment, key: treatment, ...], {:keyword, [treatments]}, " <>
      "a list of positions, or :routing; got: #{inspect(other)}"
  end

  @doc """
  Map a normalized position back to the author-facing vocabulary
  (`t:Mutare.CallRouting.treatment/0`): a `{:hosted, hosts}` stamp reads as `:hosted`, a keyed
  refinement as `[leading, key: position, …]`, recursively.

      iex> Mutare.CallRouting.Spec.author_position({:keyed, :expression, [timeout: :raw]})
      [:expression, timeout: :raw]
      iex> Mutare.CallRouting.Spec.author_position({:keyword, [{:hosted, [SomeHost]}, :raw]})
      {:keyword, [:hosted, :raw]}
  """
  @spec author_position(position()) :: treatment()
  def author_position({:hosted, _hosts}), do: :hosted

  def author_position({:keyword, positions}),
    do: {:keyword, Enum.map(positions, &author_position/1)}

  def author_position({:keyed, leading, pairs}),
    do: [leading | Enum.map(pairs, fn {key, position} -> {key, author_position(position)} end)]

  def author_position(treatment), do: treatment

  defp hosted?(:hosted), do: true
  defp hosted?({:hosted, _hosts}), do: true
  defp hosted?({:keyword, positions}), do: Enum.any?(positions, &hosted?/1)

  defp hosted?({:keyed, leading, pairs}),
    do: hosted?(leading) or Enum.any?(pairs, fn {_k, p} -> hosted?(p) end)

  defp hosted?(positions) when is_list(positions), do: Enum.any?(positions, &hosted?/1)
  defp hosted?(_), do: false
end
