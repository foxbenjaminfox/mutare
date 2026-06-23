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
      modules implementing `Mutare.Mutator`, `{module, opts}` configured entries,
      and/or the `:builtins` group token) into `Mutare.Mutator.Spec` structs,
      validating each. Both the CLI/`.mutare.exs` path (`Mutare.Config`) and the
      direct API (`Mutare.Options`, hence `Mutare.run/2`) route through it, so a
      family atom resolves, a configured entry carries its options, and a
      non-mutator module is rejected the same way wherever mutators are supplied.

  A `:mutators` list is read as sugar over one canonical shape — a list of
  mutators, each with its config. A bare module/family means "default config"; the
  `:builtins` token (synonym `:all`) expands to every built-in family at its
  position, so including it *extends* the defaults (`[:builtins, MyMutator]`) and
  omitting it *replaces* them (`[A, B]`). `{:builtins, except: [families]}` drops
  named built-ins; reconfigure one by excluding then re-adding it configured.
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
    strict_equality: Mutare.Mutators.StrictEquality,
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

  # The reserved list tokens that stand for "the whole built-in set" — expanded
  # in place (and `except:`-filtered) before any per-entry resolution, since one
  # token yields many entries. `:all` is an accepted synonym of `:builtins`.
  @group_tokens [:builtins, :all]

  @doc """
  Resolve a list of mutator entries into `Mutare.Mutator.Spec` structs, preserving
  order. Each entry is one of:

    * a registered **family atom** (`:arithmetic`) — that built-in, default config;
    * a **module** implementing the behaviour (a custom mutator);
    * a `{family_atom | module, opts}` **configured pair**;
    * the **group token** `:builtins` (or its synonym `:all`) — every built-in
      family, in registry order — optionally as `{:builtins, except: [families]}`
      to take every built-in *but* the named ones;
    * an already-resolved `%Spec{}` (idempotent).

  The group token desugars to the built-in families at its position, so a list is
  read as "these entries, in order": `[:builtins, MyMutator]` is every built-in
  **plus** a custom one, while `[A, B]` (no token) is **only** A and B. To
  reconfigure a built-in, exclude it then re-add it configured —
  `[{:builtins, except: [:convention]}, {:convention, pairs: [...]}]`.

  Raises `ArgumentError` on an unknown family (in the list or in an `:except`),
  an unknown `:builtins` option, or a module that does not implement
  `Mutare.Mutator`.

      iex> specs = Mutare.Mutators.resolve([:arithmetic, {:literal, as: :literals}])
      iex> Enum.map(specs, &{&1.name, &1.module, &1.opts})
      [{:arithmetic, Mutare.Mutators.Arithmetic, []}, {:literals, Mutare.Mutators.Literal, []}]

      iex> Mutare.Mutators.resolve([:builtins]) == Mutare.Mutators.resolve(Mutare.Mutators.all())
      true

      iex> Mutare.Mutators.resolve([{:builtins, except: [:arithmetic]}]) |> Enum.map(& &1.name) |> Enum.member?(:arithmetic)
      false
  """
  @spec resolve([atom() | module() | {atom() | module(), term()} | Spec.t()]) :: [Spec.t()]
  def resolve(mutators) when is_list(mutators) do
    mutators
    |> Enum.flat_map(&expand_group/1)
    |> Enum.map(&resolve!/1)
  end

  # Expand the `:builtins`/`:all` group token (bare or `{token, except: ...}`) into
  # its family atoms before per-entry resolution; everything else passes through as
  # a single entry. Placed first so a `{:builtins, ...}` tuple never reaches the
  # generic `{entry, opts}` configured-pair clause below.
  defp expand_group(token) when token in @group_tokens, do: families()
  defp expand_group({token, opts}) when token in @group_tokens, do: builtins_except(opts)
  defp expand_group(entry), do: [entry]

  # Every built-in family minus an `:except` list of family atoms. Validates that
  # the only option is `:except` and that each excluded name is a real family, so a
  # typo (`{:builtins, exclude: ...}` / `except: [:arithmitic]`) fails loudly rather
  # than silently keeping the family it meant to drop.
  defp builtins_except(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            ":builtins options must be a keyword list with an :except family list, got: " <>
              inspect(opts)
    end

    case Keyword.keys(opts) -- [:except] do
      [] -> :ok
      bad -> raise ArgumentError, unknown_builtins_option_message(bad)
    end

    except = opts |> Keyword.get(:except, []) |> List.wrap()
    Enum.each(except, &validate_family!/1)
    families() -- except
  end

  defp validate_family!(name) do
    unless is_atom(name) and Keyword.has_key?(registry(), name) do
      raise ArgumentError,
            "unknown mutator family #{inspect(name)} in :builtins :except — " <>
              "expected one of: #{known_families()}"
    end
  end

  defp unknown_builtins_option_message(keys) do
    "unknown :builtins option#{if length(keys) > 1, do: "s"} " <>
      "#{Enum.map_join(keys, ", ", &inspect/1)}: the only supported option is :except"
  end

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
