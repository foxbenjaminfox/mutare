defmodule Mutare.Mutators do
  @moduledoc """
  The catalog of built-in mutator families — the single source of truth.

  Owns the *ordered* registry mapping a built-in family atom to its module; every
  consumer derives from it, so there is no second list to keep in sync:

    * `all/0` is the default mutator set — every built-in module, in order — what
      an unset `:mutators` (or `:all`) means to `Mutare.Transform`. All built-in
      families are on by default; a user narrows the set by listing a subset
      under `:mutators`.
    * `families/0` is every registered family atom; `resolve/1` accepts any of
      them by name.
    * `resolve/1` turns a user-supplied list (built-in family atoms, custom
      modules implementing `Mutare.Mutator`, and/or `{module, opts}` configured
      entries) into `Mutare.Mutator.Spec` structs, validating each. Both the
      CLI/`.mutare.exs` path (`Mutare.Config`) and the direct API
      (`Mutare.Options`, hence `Mutare.run/2`) route through it, so a family atom
      resolves, a configured entry carries its options, and a non-mutator module
      is rejected the same way wherever mutators are supplied.

  The registry is an ordered keyword list (not a map) so `all/0` is deterministic
  and a new family slots into a defined position.
  """

  alias Mutare.Mutator.Spec

  # Ordered on purpose: this is the order mutants are offered in, and the order
  # `all/0` returns. Register a new built-in family by adding it here — that is
  # the only edit; `all/0`, `families/0`, and `resolve/1` all follow. Everything
  # registered is on by default.
  @registry [
    arithmetic: Mutare.Mutators.Arithmetic,
    operand_swap: Mutare.Mutators.OperandSwap,
    bitwise: Mutare.Mutators.Bitwise,
    relational: Mutare.Mutators.Relational,
    logical: Mutare.Mutators.Logical,
    literal: Mutare.Mutators.Literal,
    conditional: Mutare.Mutators.Conditional,
    if_condition: Mutare.Mutators.IfCondition,
    list: Mutare.Mutators.List,
    collection: Mutare.Mutators.Collection,
    collection_arity: Mutare.Mutators.CollectionArity,
    string_call: Mutare.Mutators.StringCall,
    string_byte: Mutare.Mutators.StringByte,
    map_keyword: Mutare.Mutators.MapKeyword,
    map_set: Mutare.Mutators.MapSet,
    call_removal: Mutare.Mutators.CallRemoval,
    default_drop: Mutare.Mutators.DefaultDrop,
    mode_swap: Mutare.Mutators.ModeSwap,
    numeric: Mutare.Mutators.Numeric,
    math: Mutare.Mutators.Math,
    integer: Mutare.Mutators.Integer,
    convention: Mutare.Mutators.ConventionAtom,
    string: Mutare.Mutators.StringLiteral,
    float: Mutare.Mutators.FloatLiteral,
    atom: Mutare.Mutators.AtomLiteral,
    charlist: Mutare.Mutators.CharlistLiteral,
    word_list: Mutare.Mutators.WordListLiteral,
    map: Mutare.Mutators.MapLiteral,
    tuple: Mutare.Mutators.TupleLiteral,
    bitstring: Mutare.Mutators.BitstringLiteral,
    regex: Mutare.Mutators.RegexLiteral,
    datetime: Mutare.Mutators.DateTimeLiteral,
    alias: Mutare.Mutators.AliasLiteral,
    return_value: Mutare.Mutators.ReturnValue,
    pattern_swap: Mutare.Mutators.PatternSwap,
    pattern_wildcard: Mutare.Mutators.PatternWildcard,
    rescue_type: Mutare.Mutators.RescueType,
    guard_drop: Mutare.Mutators.GuardDrop,
    genserver: Mutare.Mutators.GenServer
  ]

  @doc "The ordered `family => module` registry of every built-in mutator."
  @spec registry() :: [{atom(), module()}]
  def registry, do: @registry

  @doc """
  The default mutator set: every built-in module, in registry order.

      iex> Mutare.Mutators.all() |> List.first()
      Mutare.Mutators.Arithmetic
  """
  @spec all() :: [module()]
  def all, do: Keyword.values(@registry)

  @doc """
  Every known built-in family atom, in registry order.

      iex> :arithmetic in Mutare.Mutators.families()
      true
  """
  @spec families() :: [atom()]
  def families, do: Keyword.keys(@registry)

  @doc """
  Resolve a list of mutator entries into `Mutare.Mutator.Spec` structs, preserving
  order. Each entry is a registered family atom, a module implementing the
  behaviour, a `{family_atom | module, opts}` configured pair, or an
  already-resolved `%Spec{}` (idempotent). Raises `ArgumentError` on an unknown
  family or a module that does not implement `Mutare.Mutator`.

      iex> specs = Mutare.Mutators.resolve([:arithmetic, {:literal, as: :literals}])
      iex> Enum.map(specs, &{&1.name, &1.module, &1.opts})
      [{:arithmetic, Mutare.Mutators.Arithmetic, []}, {:literals, Mutare.Mutators.Literal, []}]
  """
  @spec resolve([atom() | module() | {atom() | module(), term()} | Spec.t()]) :: [Spec.t()]
  def resolve(mutators) when is_list(mutators), do: Enum.map(mutators, &resolve!/1)

  defp resolve!(%Spec{} = spec), do: spec
  defp resolve!({entry, opts}), do: Spec.configured(to_module!(entry), opts)
  defp resolve!(entry), do: Spec.for_module(to_module!(entry))

  # An entry's module: a registered family atom maps via the registry, any other
  # term must be a module implementing the behaviour.
  defp to_module!(name) do
    cond do
      is_atom(name) and Keyword.has_key?(registry(), name) ->
        Keyword.fetch!(registry(), name)

      Mutare.Mutator.implemented_by?(name) ->
        name

      true ->
        raise ArgumentError, unknown_mutator_message(name)
    end
  end

  defp unknown_mutator_message(name) do
    base =
      "unknown mutator #{inspect(name)}: expected a built-in family " <>
        "(#{known_families()}) or a module implementing Mutare.Mutator"

    # A loaded module that just isn't a mutator gets a more specific nudge.
    if is_atom(name) and Code.ensure_loaded?(name) do
      base <> " (#{inspect(name)} is missing mutate/1 or name/0)"
    else
      base
    end
  end

  defp known_families, do: Enum.map_join(families(), ", ", &to_string/1)
end
