defmodule Mutare.Mutators do
  @moduledoc """
  The registry and resolver for Mutare's built-in mutator families.

  All built-in families run by default. Set `:mutators` to a list of family atoms or custom
  mutator modules to choose a different set. A `{mutator, opts}` pair configures one entry.

  Include `:builtins` (or `:all`) to add entries to the default set:

      mutators: [:builtins, MyApp.Mutators.AccessPolicy]

  Without that token, the list replaces the defaults. Use
  `{:builtins, except: [:family]}` to start with all built-ins except selected families. See
  `resolve/1` for every accepted entry form.
  """

  alias Mutare.Ignore.SpecError
  alias Mutare.Mutator
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
    keyword_delete: Mutare.Mutators.KeywordDelete,
    map_set: Mutare.Mutators.MapSet,
    period_boundary: Mutare.Mutators.PeriodBoundary,
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
    string_sigil: Mutare.Mutators.StringSigilLiteral,
    map: Mutare.Mutators.MapLiteral,
    tuple: Mutare.Mutators.TupleLiteral,
    bitstring: Mutare.Mutators.BitstringLiteral,
    bitstring_spec: Mutare.Mutators.BitstringSpec,
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

  # Registered families whose mutation logic lives in `Mutare.Transform`, not in a
  # `Mutare.Mutator` *producing* callback — so `Mutare.Mutator.Dispatch.implemented_by?/1` is false for
  # them and resolution accepts them via this list rather than the producing-callback check.
  # `GuardDrop` because its "inert guard" rule is relative to the whole enabled set (only the
  # transform sees that); `RescueType` because its clause-restructuring doesn't fit a
  # `node -> [mutation]` callback. The transform discovers each by module identity
  # (`Spec.find/2`). Must be a subset of the registry's modules, and disjoint from the
  # `implemented_by?` mutators — both pinned by `mutators_test`.
  @transform_managed [Mutare.Mutators.GuardDrop, Mutare.Mutators.RescueType]

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
  The built-in families whose mutation logic lives in `Mutare.Transform` rather than in a
  `Mutare.Mutator` producing callback (`Mutare.Mutators.GuardDrop`, `Mutare.Mutators.RescueType`).

  They are registered for naming / toggling / `# mutare:ignore`, and are discovered by the
  transform by module identity — but they do **not** implement `Mutare.Mutator` (so
  `Mutare.Mutator.Dispatch.implemented_by?/1` is false for them). Resolution accepts them on this basis.
  """
  @spec transform_managed() :: [module()]
  def transform_managed, do: @transform_managed

  # Characters a `# mutare:ignore` filter token can't carry, so a declared variant label
  # must avoid them: whitespace, the entry separator `,`, the result-set group `()`, the
  # filter terminator `]`, and the quote `"`. The empty string is rejected separately
  # (`wire_safe?/1`): it carries none of these, yet `# mutare:ignore[family:]` parses to the
  # malformed empty-label entry, which `Mutare.Ignore.Directive.match_specificity/3` never matches
  # — so an empty *declared* label would be permanently unsuppressable rather than a filter token.
  @wire_unsafe ~r/[\s,()\]"]/

  @doc false
  # The variant vocabulary for `active_specs`: a map `family_name => :none | MapSet(labels)`, the
  # labels a `# mutare:ignore[family:label]` qualifier may use. Covers every built-in family (from
  # the registry, regardless of whether it is active this run — a directive may legitimately name a
  # `--mutators`-disabled family), the unregistered `clause_drop`, and each active custom/renamed
  # spec (keyed by its downcased recorded `name`; an `:as`-rename that collides with a built-in
  # overrides it). A family that declares no `variants/0` maps to `:none` (bare `[family]` only).
  # Raises `Mutare.Ignore.SpecError` for a wire-unsafe declared label (`:wire_unsafe_label`) or a
  # family name a filter token can't express — a `:` or wire-unsafe char (`:unfilterable_family`).
  @spec vocabulary([Spec.t()]) :: %{String.t() => :none | MapSet.t(String.t())}
  def vocabulary(active_specs) when is_list(active_specs) do
    # Case-fold a family name to its lookup key via the *same* contract a filter's family token is
    # folded with at parse time (`Mutare.Mutator.normalize_label/1`), so the declaring and matching
    # sides can't drift.
    builtins =
      Map.new(@registry, fn {family, module} ->
        {Mutator.normalize_label(family), variants_of(module)}
      end)

    # Only specs *not* already faithfully represented by the builtins map: a bare built-in
    # (`name`→registry module) is skipped (no redundant reflection), while a renamed custom or a
    # foreign custom is added — and, keyed by the same family name, overrides any shadowed builtin.
    # Each custom family name is checked **filterable** (a built-in name is a known-safe constant):
    # a `:`/wire-unsafe name can't be written as a `# mutare:ignore[...]` token, so it would be
    # silently unsuppressable — reject it loudly instead.
    customs =
      for %Spec{module: module, name: name} <- active_specs,
          Keyword.get(@registry, name) != module,
          into: %{},
          do: {check_family!(module, Mutator.normalize_label(name)), variants_of(module)}

    builtins |> Map.put("clause_drop", :none) |> Map.merge(customs)
  end

  @doc false
  # Whether `label` can be written as a `# mutare:ignore` filter token that actually selects a
  # variant — i.e. it is non-empty and carries none of the characters that would break parsing. The
  # single source of truth for the wire-safe rule, shared by `check_wire_safe!/2` and the suite's
  # "every built-in label is wire-safe" test. The empty string is excluded because, while it breaks
  # no parsing, `[family:]` resolves to the malformed empty-label entry that matches nothing — an
  # empty declared label could never be selected.
  @spec wire_safe?(String.t()) :: boolean()
  def wire_safe?(label) when is_binary(label),
    do: label != "" and not Regex.match?(@wire_unsafe, label)

  # A module's declared variant labels as a downcased `MapSet`, or `:none` when it does not
  # opt in. "Opted in" is `Mutare.Mutator.Dispatch.opted_in?/1` — it exports `variants/0` (the
  # vocabulary) — the same predicate `Mutare.Mutator.Dispatch.variant/4` gates recording on, so the
  # validation side here and the recording side can't disagree (a module with no `variants/0` is
  # `:none`, and a qualifier against it is a clean hard error rather than a silently-unmatched
  # label). How a family *assigns* its labels — a production-time `%Mutare.Mutator.Mutation{}` tag or
  # the `variant/2` callback — is orthogonal. Each label is checked wire-safe at harvest time.
  defp variants_of(module) do
    if Mutare.Mutator.Dispatch.opted_in?(module) do
      module.variants()
      |> Enum.map(&Mutator.normalize_label/1)
      |> Enum.map(&check_wire_safe!(module, &1))
      |> MapSet.new()
    else
      :none
    end
  end

  defp check_wire_safe!(module, label) do
    unless wire_safe?(label) do
      raise SpecError,
        reason: :wire_unsafe_label,
        label: label,
        message:
          "mutator #{inspect(module)} declared an unusable # mutare:ignore variant label " <>
            "#{inspect(label)}: a label may not be empty or contain whitespace, ',', '(', ')', " <>
            "']', or '\"'"
    end

    label
  end

  # A family name is usable as a `# mutare:ignore[...]` token iff it is wire-safe *and* colon-free:
  # a `:` is read as the variant-qualifier separator (so `[ecto:query]` would parse as family `ecto`
  # + label `query`, never naming a whole `ecto:query` family). Reject such a name loudly at
  # vocabulary build rather than letting its filter silently match nothing.
  defp check_family!(module, family) do
    if wire_safe?(family) and not String.contains?(family, ":") do
      family
    else
      raise SpecError,
        reason: :unfilterable_family,
        family: family,
        message:
          "mutator #{inspect(module)} has a # mutare:ignore family name #{inspect(family)} that " <>
            "can't be written as a filter token: a family may not contain ':' (the variant " <>
            "qualifier separator) or whitespace, ',', '(', ')', ']', or '\"'. Rename the mutator " <>
            "(name/0) or its `:as` to a colon-free token."
    end
  end

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

  # An entry's module: a registered family atom maps via the registry; a **transform-managed**
  # family module (`transform_managed/0` — logic in the transform, no producing callback, so
  # `implemented_by?` can't recognise it) passes through as itself; any other term must be a
  # custom module implementing the behaviour. A non-transform-managed built-in module resolves
  # via the `implemented_by?` branch like any mutator.
  defp to_module!(name) do
    cond do
      is_atom(name) and Keyword.has_key?(registry(), name) ->
        Keyword.fetch!(registry(), name)

      name in @transform_managed ->
        name

      Mutare.Mutator.Dispatch.implemented_by?(name) ->
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
      base <> " (#{inspect(name)} is missing name/0 or a mutation callback like mutate/1)"
    else
      base
    end
  end

  defp known_families, do: Enum.map_join(families(), ", ", &to_string/1)
end
