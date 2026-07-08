defmodule Mutare.Transform.ModulePlan do
  @moduledoc false

  # The plan for one statement sequence (a module body, or any block that defines
  # functions): each statement classified into how emission should handle it.
  #
  # This is the "module planning" stage, split out of the emission loop. It is
  # pure and id-free: it groups consecutive same-signature clauses into runs,
  # decides per run whether to lift (delegating to `FunctionPlan.plan/3`), and
  # leaves everything else for `Mutare.Transform`'s module-statement classifier.
  # `Mutare.Transform` then walks `items` in order, threading ids and rendering each.
  #
  # An item is one of:
  #
  #   * `{:lift, %FunctionPlan{}}` — a clause group to duplicate behind a dispatcher;
  #   * `{:in_place, [clause]}`    — a clause group whose clauses stay put (bodies
  #     still mutate); used for groups that can't or needn't lift, and for
  #     non-consecutive clauses (see below);
  #   * `{:statement, node}`       — any other statement, classified by
  #     `Mutare.Transform` as a nested scope, a statement block, a macro block, or
  #     compile-time scaffold.

  require Logger

  alias Mutare.Lifting
  alias Mutare.Transform.Config
  alias Mutare.Transform.FunctionPlan

  @type item ::
          {:lift, FunctionPlan.t()}
          | {:in_place, [Macro.t()]}
          | {:statement, Macro.t()}

  @type t :: %__MODULE__{
          items: [item()],
          skip_lifting_matches: MapSet.t(Lifting.skip_entry())
        }

  defstruct items: [], skip_lifting_matches: MapSet.new()

  @doc """
  Plan a statement sequence into classified `items`.

  `config` supplies the `file` (attributing the advisory warnings), the
  `skip_lifting` entry set, and the `warnings` gate — the scan/count pass warns;
  the render pass, report-time re-derivation, and poison rebuilds re-run the same
  pipeline and pass `warnings: false` so each advisory prints once.

  `skip_lifting_matches` records the normalized entries this sequence matched, so
  `Mutare.Schema` can union them across the count pass and surface configured
  entries that matched nothing anywhere.
  """
  @spec build([Macro.t()], [Mutare.Mutator.Spec.t()], Config.t(), Lifting.enclosing()) :: t()
  def build(statements, mutators, %Config{} = config, module) do
    chunks = chunk_clause_runs(statements)
    skipped = skipped_signatures(chunks, module, config.skip_lifting)
    non_consecutive = non_consecutive_signatures(chunks)
    metaprogrammed = metaprogrammed_heads(chunks)
    delegated = delegated_heads(chunks)

    # Each blocked signature gets exactly one warning, for its binding reason.
    # User-requested `:skip_lifting` wins the diagnosis: it is the most direct
    # explanation and intentionally suppresses the other lifting warnings for
    # that signature.
    # Delegation wins the diagnosis when it applies — the delegate is a concrete,
    # named sibling clause, the most specific thing we can tell the user, and no
    # other remedy restores lifting while it exists. Metaprogramming wins over
    # non-consecutive: grouping the clauses can't enable lifting (the generated
    # clauses still force in-place), so the non-consecutive advice ("group the
    # clauses") would mislead.
    if config.warnings do
      warn_skipped(skipped, module, config.file)

      warn_delegated(
        delegated_signatures(chunks, delegated) |> without_skipped(skipped),
        config.file
      )

      warn_metaprogrammed(
        metaprogrammed_signatures(chunks, metaprogrammed, delegated) |> without_skipped(skipped),
        config.file
      )

      warn_non_consecutive(
        non_consecutive_only(non_consecutive, metaprogrammed, delegated, skipped),
        config.file
      )
    end

    items =
      Enum.map(chunks, fn
        {:other, statement} ->
          {:statement, statement}

        {:clauses, clauses} ->
          plan_clause_group(
            clauses,
            skipped,
            non_consecutive,
            metaprogrammed,
            delegated,
            mutators
          )
      end)

    %__MODULE__{items: items, skip_lifting_matches: matched_entries(skipped, module)}
  end

  @doc """
  The `{visibility, name, arity}` of a `def`/`defp` clause, or `nil` for anything
  else. Public so `Mutare.Transform` can tell a clause-bearing block apart from a
  plain one without re-deriving the shape.
  """
  @spec clause_signature(Macro.t()) :: FunctionPlan.signature() | nil
  def clause_signature({vis, _meta, [head | _rest]}) when vis in [:def, :defp] do
    case name_arity(head) do
      {name, arity} -> {vis, name, arity}
      :error -> nil
    end
  end

  def clause_signature(_), do: nil

  # --- clause-group classification ------------------------------------------

  defp plan_clause_group(clauses, skipped, non_consecutive, metaprogrammed, delegated, mutators) do
    signature = clause_signature(hd(clauses))
    {_vis, name, arity} = signature

    # Non-consecutive heads can't be lifted (for now). A dispatcher is a catch-all
    # for the whole signature, so lifting one run would shadow the others; and
    # lifting every run as one unit relocates each clause's body to the
    # dispatcher's position — which silently changes semantics when a compile-time
    # `@attr` read between the heads resolves differently there
    # (`@a 1; def f(0), do: @a; @a 2; def f(1), do: @a`). Fall back to in-place;
    # guard/clause-drop mutants are simply not offered for such functions.
    #
    # Same hazard, different source: a function whose clause set is *augmented by
    # compile-time metaprogramming* — a module-level `for`/macro that `def`s the
    # same signature (`def code(integer) when …` beside `for … do def code(atom) …`).
    # Those generated clauses are invisible here (they live inside an `{:other}`
    # statement), so the run looks complete and consecutive; lifting it installs a
    # dispatcher that shadows every metaprogrammed clause and forwards to a lifted
    # group missing them — a guaranteed `FunctionClauseError`. Refuse to lift any
    # signature whose head is also generated inside a non-`def` statement.
    #
    # A `defdelegate` sharing the name/arity is the same shadowing hazard in its
    # most idiomatic form ("one explicit clause for the special case, delegate the
    # rest" — hit for real on `Phoenix.Controller.assign/2`): the delegate expands
    # to a sibling `def` clause invisible to this grouping, so the lifted run's
    # unconditional public wrapper would shadow it and the delegate's inputs would
    # crash *at baseline*, no mutant active.
    #
    # Both sets are keyed by exact {name, arity} — a same-named function at
    # another arity keeps its lifted mutants — degrading to an arity-wildcard on
    # the bare name only where `unquote_splicing` makes a generated head's arity
    # unknowable. `collect_heads/3` owns the walk, its keying, and its pruning
    # rules (including why macro bodies — `__using__` boilerplate above all —
    # don't count).
    if signature in skipped or signature in non_consecutive or
         blocked?({name, arity}, metaprogrammed) or blocked?({name, arity}, delegated) do
      {:in_place, clauses}
    else
      case FunctionPlan.plan(signature, clauses, mutators) do
        {:lift, plan} -> {:lift, plan}
        :in_place -> {:in_place, clauses}
      end
    end
  end

  defp name_arity({:when, _, [call | _guards]}), do: name_arity(call)
  defp name_arity({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp name_arity({name, _, context}) when is_atom(name) and is_atom(context), do: {name, 0}
  defp name_arity(_), do: :error

  # --- clause-run chunking ---------------------------------------------------

  # Group maximal runs of consecutive clauses that share {visibility, name, arity}.
  # A signature appearing in more than one run is "non-consecutive" (see
  # non_consecutive_signatures/1) and is never lifted.
  defp chunk_clause_runs(statements) do
    statements
    |> Enum.reduce([], fn statement, acc ->
      case {clause_signature(statement), acc} do
        {nil, acc} ->
          [{:other, statement} | acc]

        {sig, [{:clauses, sig, clauses} | rest]} ->
          [{:clauses, sig, [statement | clauses]} | rest]

        {sig, acc} ->
          [{:clauses, sig, [statement]} | acc]
      end
    end)
    |> Enum.map(fn
      {:clauses, _sig, clauses} -> {:clauses, Enum.reverse(clauses)}
      other -> other
    end)
    |> Enum.reverse()
  end

  # The deduplicated signatures of all top-level clause groups.
  defp clause_group_signatures(chunks) do
    chunks
    |> Enum.flat_map(fn
      {:clauses, clauses} -> [clause_signature(hd(clauses))]
      {:other, _statement} -> []
    end)
    |> Enum.uniq()
  end

  # Signatures whose clauses are split across more than one consecutive run —
  # something (another definition, a module attribute) appears between them.
  # These are the functions Transform refuses to lift.
  defp non_consecutive_signatures(chunks) do
    chunks
    |> Enum.flat_map(fn
      {:clauses, clauses} -> [clause_signature(hd(clauses))]
      {:other, _statement} -> []
    end)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {signature, count} when count > 1 -> [signature]
      {_signature, _count} -> []
    end)
    |> MapSet.new()
  end

  # The non-consecutive signatures whose binding reason really *is* being
  # non-consecutive — i.e. not also skipped, metaprogrammed, or delegated.
  # Dropping those here avoids a misleading "group the clauses" suggestion that
  # grouping would not honour.
  defp non_consecutive_only(non_consecutive, metaprogrammed, delegated, skipped) do
    Enum.reject(non_consecutive, fn {vis, name, arity} ->
      {vis, name, arity} in skipped or blocked?({name, arity}, metaprogrammed) or
        blocked?({name, arity}, delegated)
    end)
  end

  # `Lifting.skip?/4` is `false` for a `nil` (top-level) or unresolved-sentinel module,
  # so those scopes yield the empty set with no special clause here.
  defp skipped_signatures(chunks, module, skip_lifting) do
    chunks
    |> clause_group_signatures()
    |> Enum.filter(fn {_vis, name, arity} -> Lifting.skip?(skip_lifting, module, name, arity) end)
    |> MapSet.new()
  end

  # The normalized entries the skip set matched here. `skipped` is non-empty only for a
  # real (resolved) module, so `module` is never `nil`/the sentinel when this builds an
  # entry.
  defp matched_entries(skipped, module) do
    MapSet.new(skipped, fn {_vis, name, arity} -> {module, Atom.to_string(name), arity} end)
  end

  # Warn once per blocked signature, file-prefixed. Each caller supplies the message body for a
  # `{name, arity}` — the four lift-refusal diagnoses differ only in that text.
  defp warn(signatures, file, message_fn) do
    Enum.each(signatures, fn {_vis, name, arity} ->
      Logger.warning("#{file}: " <> message_fn.(name, arity))
    end)
  end

  defp warn_skipped(signatures, module, file) do
    warn(signatures, file, fn name, arity ->
      "#{inspect(module)}.#{name}/#{arity} matched :skip_lifting — not lifting " <>
        "(no guard, head-pattern, or clause-drop mutants for it)"
    end)
  end

  defp without_skipped(signatures, skipped),
    do: Enum.reject(signatures, &MapSet.member?(skipped, &1))

  # Lifting is silently disabled for non-consecutive clauses, which costs that
  # function its guard and clause-drop mutants. Warn once per signature so the
  # gap is visible (and actionable — grouping the clauses restores lifting).
  defp warn_non_consecutive(signatures, file) do
    warn(signatures, file, fn name, arity ->
      "clauses of #{name}/#{arity} are non-consecutive — not lifting " <>
        "(no guard or clause-drop mutants for it); group the clauses to enable lifting"
    end)
  end

  # --- metaprogramming-augmented signatures ----------------------------------

  # Heads `def`/`defp`'d *inside* a non-clause statement (a module-level `for`,
  # `if`, `Enum.each`, macro body, …). A function with such a head may gain
  # clauses at compile time that aren't visible as top-level `def` statements, so
  # its top-level run is not the whole function and must not be lifted (the
  # dispatcher would shadow the generated clauses). Collected by the shared
  # `collect_heads/4` walk — see its comment for the pruning and keying rules.
  defp metaprogrammed_heads(chunks), do: collect_chunk_heads(chunks, [:def, :defp])

  # The top-level clause-group signatures blocked from lifting by metaprogramming,
  # for the warning. Deduplicated by signature. Metaprogramming outranks
  # non-consecutiveness as the diagnosis, but yields to delegation — see the
  # precedence note in `build/4`.
  defp metaprogrammed_signatures(chunks, metaprogrammed, delegated) do
    chunks
    |> clause_group_signatures()
    |> Enum.filter(fn {_vis, name, arity} ->
      blocked?({name, arity}, metaprogrammed) and not blocked?({name, arity}, delegated)
    end)
  end

  # Mirror of warn_non_consecutive/2 for the metaprogramming case. Not user-fixable
  # (the generated clauses are intentional), but the coverage gap should still be
  # visible.
  defp warn_metaprogrammed(signatures, file) do
    warn(signatures, file, fn name, arity ->
      "clauses of #{name}/#{arity} are augmented by compile-time " <>
        "metaprogramming — not lifting (no guard or clause-drop mutants for it)"
    end)
  end

  # --- defdelegate siblings ---------------------------------------------------

  # Heads defined by a `defdelegate` anywhere in this statement sequence (top
  # level, or nested inside a non-clause statement — the same `collect_heads/4`
  # walk the metaprogrammed set uses). A delegate expands to a plain `def` clause
  # of its head's exact name/arity, but its AST form is `:defdelegate`, invisible
  # to clause_signature/1 — so a sibling top-level run of the same signature
  # looks complete and would lift, installing an unconditional public wrapper
  # that shadows the delegate clause and crashes the delegate's inputs at
  # *baseline*, no mutant active.
  defp delegated_heads(chunks), do: collect_chunk_heads(chunks, [:defdelegate])

  # The top-level clause-group signatures blocked from lifting by a defdelegate
  # sibling, for the warning. Delegation is the binding diagnosis whenever it
  # applies — see the precedence note in `build/4`.
  defp delegated_signatures(chunks, delegated) do
    chunks
    |> clause_group_signatures()
    |> Enum.filter(fn {_vis, name, arity} -> blocked?({name, arity}, delegated) end)
  end

  # Mirror of warn_metaprogrammed/2 for the defdelegate case: the delegate is an
  # invisible sibling clause, so lifting is refused and the mutant gap should be
  # visible.
  defp warn_delegated(signatures, file) do
    warn(signatures, file, fn name, arity ->
      "#{name}/#{arity} is also defined by a defdelegate — not lifting " <>
        "(no guard or clause-drop mutants for it)"
    end)
  end

  # --- nested-head collection (the shared walk) -------------------------------

  # Both safety-net sets — metaprogrammed def/defp heads and defdelegate heads —
  # come from this one walk over the non-clause statements, returning
  # `{exact, wildcard}`: a MapSet of `{name, arity}` pairs plus a MapSet of bare
  # names blocked at *every* arity. Query with `blocked?/2`.
  #
  # Keying: a head found inside a `for`/`if`/`Enum.each` body usually has a
  # statically certain arity — `def code(unquote(atom))` is arity 1 no matter
  # what `atom` unquotes to — so it blocks only its own `{name, arity}` and
  # same-named functions at other arities keep their lifted mutants (the
  # Phoenix.Presence collateral: `__using__` boilerplate reusing short names at
  # a shifted arity cost real functions their guard/clause-drop mutants).
  # `unquote_splicing` in the args is the exception — the real arity is
  # unknowable — so such a head degrades to the bare-name wildcard. A fully
  # dynamic name (`def unquote(name)(…)`) is statically invisible and
  # contributes nothing: the accepted residual hole (see NOTES
  # "Metaprogramming-augmented clauses"). Defaults in a generated head
  # contribute only the full arity — an explicit def at an implied lower arity
  # cannot legally coexist with the defaults anyway ("def f/1 conflicts with
  # defaults from f/2" is a compile error).
  #
  # Pruned as scope boundaries — their defs can't add clauses here:
  #
  #   * nested `defmodule`/`defimpl`/`defprotocol` — a different module scope;
  #   * `defmacro`/`defmacrop` bodies — a macro's body (quoted or not) runs only
  #     where the macro is *invoked*, and no invocation can target this module's
  #     own top level: a local macro call in the module body does not compile
  #     ("undefined function" — the module's own macros don't exist until it is
  #     compiled, the same principle that forbids `use __MODULE__` and
  #     `@before_compile __MODULE__`), and inside a function body a generated
  #     `def` is illegal ("cannot invoke def inside function"). All verified
  #     empirically; the `use`-boilerplate shape this recovers is pinned in
  #     lift_test. So quoted defs in `__using__`/`__before_compile__`/any
  #     def-generating macro target only *other* modules.
  #
  # A bare module-level `quote` (outside any macro definition) is NOT pruned:
  # its AST can be fed to `Module.eval_quoted(__MODULE__, …)`, which really does
  # inject defs into this module — scanning it is what keeps that shape safe.
  #
  # Accepted limitation: only literal def nodes in *this module's source* are
  # visible. A def manufactured by an opaque module-level macro call (`use
  # SomeLib`, `defmemo f(x) do … end`, a remote def-generating macro) is a call
  # node with no def AST inside — nothing static here can see the clauses it
  # mints. See NOTES "Metaprogramming-augmented clauses" for why that is
  # accepted and the half-built `Uses`-expansion mitigation if it ever bites.
  defp collect_chunk_heads(chunks, forms) do
    Enum.reduce(chunks, {MapSet.new(), MapSet.new()}, fn
      {:other, statement}, acc -> collect_heads(statement, forms, acc)
      {:clauses, _clauses}, acc -> acc
    end)
  end

  # Whether `{name, arity}` is blocked by a collected `{exact, wildcard}` set.
  defp blocked?({name, arity}, {exact, wildcard}),
    do: name in wildcard or {name, arity} in exact

  @scope_boundaries [:defmodule, :defimpl, :defprotocol, :defmacro, :defmacrop]

  defp collect_heads(statement, forms, initial) do
    {_ast, acc} =
      Macro.prewalk(statement, initial, fn
        {form, _meta, _args}, acc when form in @scope_boundaries ->
          # Prune: return a leaf so prewalk does not descend into the boundary.
          {:__mutare_pruned__, acc}

        {form, _meta, [_ | _]} = node, acc ->
          if form in forms, do: {node, collect_node(node, acc)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # `defdelegate` historically accepted a list of heads; List.wrap/1 keeps the
  # extraction total over both the single-head and list shapes.
  defp collect_node({:defdelegate, _meta, [funs | _opts]}, acc) do
    funs |> List.wrap() |> Enum.reduce(acc, &classify_head/2)
  end

  defp collect_node({form, _meta, [head | _rest]}, acc) when form in [:def, :defp] do
    classify_head(head, acc)
  end

  defp collect_node(_node, acc), do: acc

  defp classify_head(head, {exact, wildcard} = acc) do
    case name_arity(head) do
      # A dynamic name — statically invisible; the accepted residual hole.
      :error ->
        acc

      {name, arity} ->
        if spliced?(head) do
          {exact, MapSet.put(wildcard, name)}
        else
          {MapSet.put(exact, {name, arity}), wildcard}
        end
    end
  end

  defp spliced?({:when, _, [call | _guards]}), do: spliced?(call)

  defp spliced?({_name, _, args}) when is_list(args),
    do: Enum.any?(args, &match?({:unquote_splicing, _, _}, &1))

  defp spliced?(_head), do: false
end
