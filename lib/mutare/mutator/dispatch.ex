defmodule Mutare.Mutator.Dispatch do
  @moduledoc false
  # The transform-facing side of the mutator contract: running mutators over a node, discovering
  # which enabled specs implement a structural hook, invoking those hooks (preferring the
  # behaviour-aware arity), normalizing the noted-mutant / selector-host return shapes, and the
  # mutator-resolution check the registry uses. None of this is something a *mutator author*
  # touches — they implement `Mutare.Mutator`'s callbacks; `Mutare.Transform` (and the
  # `Mutare.Mutators` registry) call into here. Split out of `Mutare.Mutator` so the behaviour
  # module stays a focused author-facing contract.

  alias Mutare.AST
  alias Mutare.Mutator.{Mutation, Spec}

  @doc """
  Run every mutator over `node`, flattening to `{mutator, mutated_node, note}` triples.

  The single place a node meets the mutator set. Both the in-place analyzer
  (`Mutare.Transform`) and the lifted-guard planner (`Mutare.Transform.FunctionPlan`)
  call this, so "which mutations does this node admit" has one answer regardless of
  where the node sits — placement is decided afterwards, positionally.

  Each entry is a `Mutare.Mutator.Spec` (a bare module is coerced to one); its
  `mutate/1` is always run, and its optional `mutate/2` is *also* run when
  implemented, with a per-spec `context` carrying the pipe mode **and** the spec's
  `:opts`. So pipe-aware/arity-changing *and* configurable mutators both
  participate here. `context` defaults to `%{pipe_mode: :unpiped}`; the transform passes
  `%{pipe_mode: :piped}` for a `|>` right-hand side. Each result is tagged with its
  **spec** (not the bare module), so the family name and config travel with it, and with
  its `note` (the third element — `nil` unless the mutator returned a
  `%Mutare.Mutator.Mutation{}`), so a per-mutant advisory rides through to the `Mutare.Site`.

      iex> [{spec, mutated, note}] = Mutare.Mutator.Dispatch.mutations({:+, [], [1, 2]}, [Mutare.Mutators.Arithmetic])
      iex> {spec.name, mutated, note}
      {:arithmetic, {:-, [], [1, 2]}, nil}
  """
  @spec mutations(Macro.t(), [Spec.t() | module()], Mutare.Mutator.context()) ::
          [{Spec.t(), Macro.t(), String.t() | nil}]
  def mutations(node, mutators, context \\ %{pipe_mode: :unpiped}) do
    Enum.flat_map(mutators, fn entry ->
      spec = Spec.coerce(entry)
      ctx = context |> Map.put(:opts, spec.opts) |> Map.put(:behaviours, spec.behaviours)
      node_local(spec, node) ++ contextual(spec, node, ctx)
    end)
  end

  # `mutate/1` is optional (a structural/pipe-only family omits it), so call it only when exported —
  # mirroring `contextual/1`'s guard on `mutate/2`.
  defp node_local(spec, node) do
    if function_exported?(spec.module, :mutate, 1),
      do: tag(spec, spec.module.mutate(node)),
      else: []
  end

  defp contextual(spec, node, context) do
    if function_exported?(spec.module, :mutate, 2),
      do: tag(spec, spec.module.mutate(node, context)),
      else: []
  end

  defp tag(_spec, :skip), do: []

  # Pair each returned mutation with its producing spec, carrying its note: `normalize_mutants/1`
  # drops the `nil` slots and turns a bare node / a `%Mutation{}` into `{node, note}` (enforcing
  # the noted-mutant contract — struct required, string note), then each pair gains its spec.
  defp tag(spec, mutations) when is_list(mutations),
    do: mutations |> normalize_mutants() |> Enum.map(fn {node, note} -> {spec, node, note} end)

  @doc """
  The specs in `specs` whose module implements the optional callback `fun`/`arity`.

  The single home for "which enabled mutators opt into this structural hook", used for the
  position-routed structural callbacks (`return_replacements/1`, `condition_replacements/1`,
  `pattern_mutations/2`) — so the transform asks every implementer rather than hardcoding a
  built-in module.
  """
  @spec implementing([Spec.t()], atom(), arity()) :: [Spec.t()]
  def implementing(specs, fun, arity), do: implementing_any(specs, fun, [arity])

  @doc """
  The specs in `specs` whose module implements `fun` at **any** of `arities` — the
  any-arity variant of `implementing/3`, used to discover the structural hooks that come
  in a base form (`fun/n`) *and* a behaviour-aware form (`fun/(n+1)`, taking the structural
  context): a mutator implements one or the other. `return_replacements/{1,2}`,
  `condition_replacements/{1,2}`, `pattern_mutations/{2,3}`. The dispatch helpers
  (`return_replacements/2`, `condition_replacements/2`, `pattern_mutations/3` below) then
  call whichever arity each spec actually exports.
  """
  @spec implementing_any([Spec.t()], atom(), [arity()]) :: [Spec.t()]
  def implementing_any(specs, fun, arities) do
    Enum.filter(specs, fn %{module: module} ->
      Enum.any?(arities, &exports?(module, fun, &1))
    end)
  end

  # Whether `module` (loaded on demand) exports `fun`/`arity` — the single home for the
  # "ensure the module is loaded, then check the export" probe the structural-hook discovery
  # (`implementing*/3`, `host_targets/3`) and the mutator-resolution check (`implemented_by?/1`)
  # share. `Code.ensure_loaded?` is idempotent and cheap once loaded, so calling it per arity is
  # fine.
  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  @doc """
  Run `spec`'s return-tail hook over `tail`, preferring the behaviour-aware
  `c:Mutare.Mutator.Structural.return_replacements/2` (passing the structural context) when the module
  exports it, else the base `c:Mutare.Mutator.Structural.return_replacements/1`, so a mutator can
  implement either arity.
  """
  @spec return_replacements(Spec.t(), Macro.t()) :: [Macro.t()]
  def return_replacements(%Spec{} = spec, tail),
    do: dispatch_structural(spec, :return_replacements, [tail])

  @doc """
  Run `spec`'s condition hook over `condition`, preferring
  `c:Mutare.Mutator.Structural.condition_replacements/2` (with the structural context) when exported, else
  `c:Mutare.Mutator.Structural.condition_replacements/1`. The condition-position twin of
  `return_replacements/2`.
  """
  @spec condition_replacements(Spec.t(), Macro.t()) :: [Macro.t()]
  def condition_replacements(%Spec{} = spec, condition),
    do: dispatch_structural(spec, :condition_replacements, [condition])

  @doc """
  Run `spec`'s head-pattern hook over `head_args`/`used_outside`, preferring
  `c:Mutare.Mutator.Structural.pattern_mutations/3` (with the structural context) when exported, else
  `c:Mutare.Mutator.Structural.pattern_mutations/2`. The lifted-pattern twin of `return_replacements/2`.
  """
  @spec pattern_mutations(Spec.t(), [Macro.t()], MapSet.t()) :: [[Macro.t()]]
  def pattern_mutations(%Spec{} = spec, head_args, used_outside),
    do: dispatch_structural(spec, :pattern_mutations, [head_args, used_outside])

  # The shared arity dispatch behind the three structural hooks above: prefer the
  # behaviour-aware `fun/(n+1)` (the base args plus the structural context) when the module
  # exports it, else the base `fun/n`. So the three are one-line faces and adding a fourth
  # structural hook is one more delegating clause, not another copy of this exported-or-base
  # dance.
  @spec dispatch_structural(Spec.t(), atom(), [term()]) :: term()
  defp dispatch_structural(%Spec{module: module} = spec, fun, base_args) do
    if function_exported?(module, fun, length(base_args) + 1),
      do: apply(module, fun, base_args ++ [structural_context(spec)]),
      else: apply(module, fun, base_args)
  end

  @doc """
  The **selector-host targets** `spec`'s mutator declares for the known-macro node `node`
  (`c:Mutare.Mutator.MacroAware.host/2`), normalized — each a map with `:original`, a list `:mutants`, a
  2-arity `:splice`, a 1-arity `:wrap` (defaulted to identity), and an optional `:range`. `[]`
  when the module doesn't implement `host/2`. `context0` (`%{pipe_mode: …}`) is enriched with the
  spec's `:opts`/`:behaviours` before the callback runs, mirroring `mutations/3`.

  The single home for invoking a hosting mutator and validating its target shape, so
  `Mutare.Transform.Analyze` builds `Mutare.Transform.Candidate.Hosted`s without re-deriving
  the contract.
  """
  @spec host_targets(Spec.t(), Macro.t(), Mutare.Mutator.context()) :: [map()]
  def host_targets(%Spec{module: module, opts: opts, behaviours: behaviours}, node, context0) do
    if exports?(module, :host, 2) do
      context = context0 |> Map.put(:opts, opts) |> Map.put(:behaviours, behaviours)
      module.host(node, context) |> Enum.map(&normalize_target/1)
    else
      []
    end
  end

  # Default `:wrap` to identity and `:range` to absent; require `:original`, a list `:mutants`,
  # and a 2-arity `:splice`. A malformed target raises (a library bug, not a target to silently
  # drop) — caught at transform time with the offending value. Each mutant is normalized to a
  # `{node, note}` pair by the shared `normalize_mutants/1` (dropping any `nil` slot).
  defp normalize_target(%{original: original, mutants: mutants, splice: splice} = target)
       when is_list(mutants) and is_function(splice, 2) do
    %{
      original: original,
      mutants: normalize_mutants(mutants),
      splice: splice,
      wrap: target_wrap(Map.get(target, :wrap)),
      range: Map.get(target, :range)
    }
  end

  defp normalize_target(other) do
    raise ArgumentError,
          "a host target must be a map with :original, a list :mutants and a 2-arity :splice " <>
            "(optional :wrap/:range), got: #{inspect(other)}"
  end

  # Normalize one mutant — a bare node, or a `%Mutare.Mutator.Mutation{}` carrying an advisory —
  # to a `{node, note}` pair (a bare node gets `note: nil`). The single home for the noted-mutant
  # contract, shared by the `mutate/1`,`mutate/2` return path (`tag/2`) and the selector-host
  # `:mutants` path (`normalize_target/1`).
  #
  # Anything other than a bare node or a well-formed `%Mutation{}` is a library bug — a bare
  # `%{node:, note:}` *map* (the struct is required: a quoted map literal is itself a valid
  # mutation node, so a bare map can't unambiguously mean "noted mutant"), some *other* struct
  # (no AST node is a struct, and the note would otherwise silently vanish), or a `%Mutation{}`
  # whose `:note` is neither a string nor nil (the report renders it verbatim). All raise rather
  # than silently drop — fail loud over a vanishing/garbled mutant. (`nil` is filtered by the
  # callers — see `normalize_mutants/1` — never reaching here.) An empty-string note is coerced
  # to `nil`: a blank note carries no signal, and `nil` keeps the report from rendering a dangling
  # `— ` suffix (and the JSON reporter from emitting an empty `description`).
  @spec normalize_mutant(Macro.t() | Mutation.t() | map()) :: {Macro.t(), String.t() | nil}
  def normalize_mutant(%Mutation{node: node, note: note}) when is_binary(note) or is_nil(note),
    do: {node, presence(note)}

  def normalize_mutant(%Mutation{note: note}) do
    raise ArgumentError,
          "a Mutare.Mutator.Mutation :note must be a string or nil, got: #{inspect(note)}"
  end

  def normalize_mutant(%{node: _} = map) when not is_struct(map) do
    raise ArgumentError,
          "a noted mutant must be a %Mutare.Mutator.Mutation{}, not a bare map, got: #{inspect(map)}"
  end

  def normalize_mutant(%_{} = other) do
    raise ArgumentError,
          "a noted mutant must be a %Mutare.Mutator.Mutation{}, got a " <>
            "#{inspect(other.__struct__)}: #{inspect(other)}"
  end

  def normalize_mutant(node), do: {node, nil}

  # A blank note is no note — collapse `""` to `nil` so downstream rendering treats it as absent.
  defp presence(""), do: nil
  defp presence(note), do: note

  # Reject the `nil` slots, then normalize each surviving mutant to a `{node, note}` pair. The
  # shared front of both noted-mutant paths — the `mutate/1`/`mutate/2` return (`tag/2`) and the
  # selector-host `:mutants` (`normalize_target/1`) — so the nil-drop rule lives in one place.
  defp normalize_mutants(mutants),
    do: mutants |> Enum.reject(&is_nil/1) |> Enum.map(&normalize_mutant/1)

  defp target_wrap(nil), do: &Function.identity/1
  defp target_wrap(wrap) when is_function(wrap, 1), do: wrap

  defp target_wrap(other) do
    raise ArgumentError, "a host target :wrap must be a 1-arity function, got: #{inspect(other)}"
  end

  # The structural-callback context: the enclosing module's behaviour set, nothing else.
  defp structural_context(%Spec{behaviours: behaviours}), do: %{behaviours: behaviours}

  # The mutation-producing callbacks: a module is a mutator if it exports `name/0` *and* at least
  # one of these. `mutate/1` is no longer required — a structural/pipe-only family produces its
  # mutations through `mutate/2` or a structural hook instead. (`macros/0`/`empty_collection?/1`
  # are routing/classification, not producers, so they don't qualify a module on their own.)
  @producing_callbacks [
    mutate: 1,
    mutate: 2,
    pattern_mutations: 2,
    pattern_mutations: 3,
    return_replacements: 1,
    return_replacements: 2,
    condition_replacements: 1,
    condition_replacements: 2,
    host: 2
  ]

  @doc """
  Whether `term` is a module that implements `Mutare.Mutator` — it exports `name/0` and at least
  one mutation-producing callback (`mutate/1`, the pipe-aware `mutate/2`, or a structural hook such
  as `return_replacements/1`). Total over any term, so a non-module entry in a `:mutators` list is
  *reported* by resolution rather than crashing a guard.

      iex> Mutare.Mutator.Dispatch.implemented_by?(Mutare.Mutators.Arithmetic)
      true
      iex> Mutare.Mutator.Dispatch.implemented_by?(Enum)
      false
      iex> Mutare.Mutator.Dispatch.implemented_by?("arithmetic")
      false
  """
  @spec implemented_by?(term()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    exports?(module, :name, 0) and
      Enum.any?(@producing_callbacks, fn {fun, arity} -> exports?(module, fun, arity) end)
  end

  # Total over any term: a non-atom (e.g. a string in `.mutare.exs`) is simply
  # not a mutator, so resolution reports it rather than crashing on the guard.
  def implemented_by?(_term), do: false

  @doc """
  Whether the mutation `{spec, mutated, _note}` produces an **empty enumerable literal** — a
  value for which `x in v` is constantly `false`, so it is redundant on the right of `in`
  (the in-RHS suppression; see `Mutare.Transform.Analyze` / `Mutare.Transform.Tag`).

  Two sources, OR-ed: the shape-based `Mutare.AST.empty_collection_literal?/1` (the
  standard `[]`/`%{}`/`~w()`/`~c""`, recognised for any mutator), and the producing
  mutator's optional `c:Mutare.Mutator.empty_collection?/1` (its own non-standard shape — a
  custom sigil, `MapSet.new([])`, …). Dispatching on the *producing* spec's module is correct
  because only the mutator that emitted the value knows the shape of its own output.
  """
  @spec empty_collection?(Spec.t(), Macro.t()) :: boolean()
  def empty_collection?(%Spec{module: module}, mutated) do
    AST.empty_collection_literal?(mutated) or
      (function_exported?(module, :empty_collection?, 1) and module.empty_collection?(mutated))
  end

  @doc """
  The **variant label(s)** `spec`'s module declares for the mutation `{original, mutated}` — a
  deduplicated, downcased label list, or `[]` when the mutator hasn't opted in (it must export
  *both* `c:Mutare.Mutator.variants/0` and `c:Mutare.Mutator.variant/2`) or returned `nil` for this
  pair (an unlabeled mutant). The single home for invoking the optional `c:Mutare.Mutator.variant/2`
  callback (mirroring `empty_collection?/2`), so `Mutare.Site` records the labels without reaching
  into a mutator module itself. Dispatching on the *producing* spec's module is correct: only the
  mutator that emitted the mutation knows which kind(s) it is.

  A mutation is usually **one** kind (a single label), but may be several: a value-family mutant
  that collapses two relationships onto one value (`Mutare.Mutators.Literal`'s deduped `1 - 1`/`0`)
  returns `["pred", "zero"]`, and a qualifier naming *either* suppresses it. `c:Mutare.Mutator.variant/2`
  may therefore return `nil`, a single label, or a list — all normalized here through `List.wrap/1`.
  """
  @spec variant(Spec.t(), Macro.t(), Macro.t()) :: [String.t()]
  def variant(%Spec{module: module}, original, mutated) do
    # `variants/0` and `variant/2` are a **pair** (see `opted_in?/1`): a mutator must export *both*
    # to record a label. Gating on the shared predicate keeps the *recording* side here consistent
    # with the *validation* side (`Mutare.Mutators.vocabulary/1`): a half-implementation records no
    # label *and* exposes no vocabulary, so a `[family:label]` qualifier against it can't both
    # validate-as-known and silently match nothing.
    if opted_in?(module) do
      module.variant(original, mutated)
      |> List.wrap()
      |> Enum.map(&Mutare.Mutator.normalize_label/1)
      |> Enum.uniq()
    else
      []
    end
  end

  @doc """
  Whether `module` opts into the variant-label system — it must export **both**
  `c:Mutare.Mutator.variants/0` (the vocabulary) and `c:Mutare.Mutator.variant/2` (the per-mutation
  tagging). The *single* definition of "opted in", shared by `variant/3` (which records a site's
  label) and `Mutare.Mutators.vocabulary/1` (which validates a `[family:label]` qualifier against the
  declared labels). Routing both through it means the two sides can't disagree: a mutator declaring
  only one half is treated uniformly as *not opted in* — it records no label **and** exposes no
  vocabulary — so a qualifier against it is a hard `Mutare.Ignore.SpecError` (the `:no_variants` case)
  rather than silently matching nothing. (`exports?/3` loads the module on demand, so an un-loadable
  module degrades to `false`.)
  """
  @spec opted_in?(module()) :: boolean()
  def opted_in?(module), do: exports?(module, :variants, 0) and exports?(module, :variant, 2)
end
