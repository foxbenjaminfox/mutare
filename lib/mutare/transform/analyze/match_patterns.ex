defmodule Mutare.Transform.Analyze.MatchPatterns do
  @moduledoc false

  # Pattern-structure mutation in a value-discarded position: the LHS of a `=` match
  # (`Candidate.MatchPattern`) and the escaping pattern arg of a binding-escaping known
  # macro (`destructure([x, y], v)` → `Candidate.MacroPattern`). Both deliver structural
  # swap/wildcard mutants by re-exporting the escaping bindings through a tuple. Split out
  # of `Mutare.Transform.Analyze`: it builds these candidates the descent hands off to. The
  # dependency is one-way — the only re-entry into the walk (the `:runtime` re-analysis of a
  # statement) goes through the **injected `descent`** (the `Mutare.Transform.Analyze` module,
  # passed in as the first argument by the caller) rather than naming it statically, and
  # candidate attachment goes through the dependency-neutral `Attach`.
  #
  # Entry points the descent calls (`Mutare.Transform.Analyze`):
  #   * a runtime block's non-final statement / a `with` clause → `analyze_statement/3`
  #   * a `for` qualifier                                       → `analyze_match_statement/3`

  alias Mutare.Transform.{Candidate, Meta, NodeRange, PatternStructure}
  alias Mutare.Transform.Analyze.Attach

  # === match (`=`) pattern structure =========================================

  # A value-discarded position that may host a rewriteable pattern — a non-final statement of
  # a runtime block (the `:__block__` clause) or a `with` clause. Two statement shapes offer a
  # pattern to the structural families: a `=` match (its LHS → `MatchPattern`), and a
  # **binding-escaping known macro** call (`destructure([x, y], v)`, declared
  # `:binding_pattern`) whose pattern arg → `MacroPattern` — its bindings escape exactly like a
  # `=`'s, so the same tuple-re-export delivery applies. Every other statement analyzes as an
  # ordinary runtime expression. (A `for` qualifier uses `analyze_match_statement/3` instead:
  # a bare macro call there is a *filter*, not value-discarded — only the `=` shape is safe.)
  def analyze_statement(descent, {:=, _meta, _operands} = match, mutators),
    do: analyze_match_statement(descent, match, mutators)

  def analyze_statement(descent, node, mutators) do
    case binding_pattern_macro(node) do
      nil ->
        descent.annotate(node, mutators)

      {raw_pattern, rebuild_mutant} ->
        node
        |> descent.annotate(mutators)
        |> attach_macro_pattern_candidates(raw_pattern, rebuild_mutant, mutators)
    end
  end

  # The `=`-only value-discarded path: a `for` qualifier, and the `=` shape of
  # `analyze_statement/3`. A `=` match's LHS goes to the structural families
  # (`MatchPattern`); everything else (a `<-` generator, a filter, a plain expression)
  # analyzes as ordinary runtime. A `for` qualifier deliberately stops here — a bare macro
  # call as a qualifier is a *filter* (its truthiness selects iterations), so rewriting it to
  # a binding would silently drop the filter; only a `=` (already a binding qualifier) is safe.
  def analyze_match_statement(descent, {:=, _meta, [raw_lhs, raw_rhs]} = match, mutators) do
    analyzed = descent.annotate(match, mutators)
    attach_match_pattern_candidates(analyzed, raw_lhs, raw_rhs, mutators)
  end

  def analyze_match_statement(descent, other, mutators), do: descent.annotate(other, mutators)

  # Offer the `=`'s LHS to the structural pattern families and, if any fire, attach a
  # `Candidate.MatchPattern` per mutation to the analyzed match node — emission rewrites
  # it to the tuple-export selector (`BindingEscapeEmit.match_site/3`). Each candidate
  # carries the LHS before/after (the diff), the shared export tuple, and the *raw* rhs.
  #
  # A plain `put_candidates` is safe here — unlike the *macro* path, which had to re-home a
  # whole-call mutation off the node — because the `=` node is **never offered** to mutators
  # (see the `analyze({:=, …})` clause), so the analyzed node carries no prior in-place
  # candidates to combine with. If that ever changes, this needs the macro path's re-home.
  defp attach_match_pattern_candidates(analyzed, raw_lhs, raw_rhs, mutators) do
    candidates = match_pattern_candidates(raw_lhs, raw_rhs, PatternStructure.mutators(mutators))
    Attach.put_candidates_if_any(analyzed, candidates)
  end

  defp match_pattern_candidates(raw_lhs, raw_rhs, structural) do
    if rhs_chain_rebinds_lhs_pin?(raw_lhs, raw_rhs) do
      []
    else
      case pattern_export_with_mutations(raw_lhs, structural) do
        nil ->
          []

        {lhs, range, export, mutations} ->
          export = export_with_rhs_chain(export, raw_rhs)

          Enum.map(mutations, fn {mutator, mutated} ->
            %Candidate.MatchPattern{
              mutator: mutator,
              original: lhs,
              mutated: mutated,
              export: export,
              raw_rhs: raw_rhs,
              range: range
            }
          end)
      end
    end
  end

  # === binding-escaping macro pattern structure ==============================

  # Recognise a value-discarded statement that is a **known macro whose pattern arg's
  # bindings escape** (`:binding_pattern` — `Kernel.destructure`, or a user-registered macro),
  # returning `{raw_pattern, rebuild_mutant}` — the raw pattern node and a closure that rebuilds
  # the *raw* macro call with a (mutated) pattern in its place — or `nil` for anything else.
  # The written shapes resolve to a binding-pattern arg (`Mutare.Transform.Resolve` stamps each):
  #
  #   * **direct** `destructure([x, y], v)` — the pattern is the first arg whose routing
  #     (`meta[:mutare_macro]`) is `:binding_pattern`. Rebuilds the call with that arg replaced.
  #   * **piped, the LHS** `[x, y] |> destructure(v)` — the piped value is effective arg 0; when
  #     *its* treatment is `:binding_pattern` (stamped `:mutare_macro_piped`) the pattern is the
  #     `|>` LHS. Rebuilds `<mutated> |> rhs`.
  #   * **piped, a visible arg** `value |> unpack([x, y])` with routing `[:expression,
  #     :binding_pattern]` — the binding pattern is a *written* arg of the stage, not the piped
  #     value, so it lives in the stage's own `meta[:mutare_macro]` (the visible routing). The
  #     piped-value check misses it; fall through to the stage's visible args, rebuilding the
  #     stage with that arg replaced and re-piping the LHS. (The equivalent direct call resolves
  #     via the direct clause — the two stayed asymmetric until this clause looked past the LHS.)
  #
  # The other args are kept *raw* (the mutant branch runs the baseline value; the catch-all
  # runs the emitted one, so a nested mutation there still fires — see
  # `BindingEscapeEmit.macro_pattern_site/3`).
  # NOTE (equivalent survivors, deliberately not `# mutare:ignore`d so the killed
  # `-> false` siblings stay counted): the `is_list/1` checks are defensive — a `|>` RHS
  # call node always has keyword-list meta and a list of args — so loosening the guard
  # (forcing it `true`, weakening `and` to `or`) is equivalent; forcing it `false` is killed.
  defp binding_pattern_macro({:|>, meta, [lhs, {form, rhs_meta, args} = rhs]})
       when is_list(rhs_meta) and is_list(args) do
    case Meta.piped_macro_routing(rhs_meta) do
      :binding_pattern ->
        {lhs, fn mutated -> {:|>, meta, [mutated, rhs]} end}

      _ ->
        case binding_pattern_index(rhs_meta) do
          nil ->
            nil

          index ->
            {Enum.at(args, index),
             fn mutated ->
               {:|>, meta, [lhs, {form, rhs_meta, List.replace_at(args, index, mutated)}]}
             end}
        end
    end
  end

  # NOTE (equivalent survivors, deliberately not `# mutare:ignore`d so the killed
  # `-> false` siblings stay counted): same defensive `is_list/1` checks as above — a real
  # call node always satisfies them — so loosening this guard is equivalent.
  defp binding_pattern_macro({form, meta, args}) when is_list(meta) and is_list(args) do
    case binding_pattern_index(meta) do
      nil ->
        nil

      index ->
        {Enum.at(args, index),
         fn mutated -> {form, meta, List.replace_at(args, index, mutated)} end}
    end
  end

  defp binding_pattern_macro(_node), do: nil

  # The first visible-arg position routed `:binding_pattern` (`meta[:mutare_macro]`), or `nil`.
  defp binding_pattern_index(meta) do
    case Meta.macro_routing(meta) do
      routing when is_list(routing) -> Enum.find_index(routing, &(&1 == :binding_pattern))
      _ -> nil
    end
  end

  # Offer the macro's escaping pattern to the structural families and attach a
  # `Candidate.MacroPattern` per mutation to the analyzed macro/pipe node — emission rewrites
  # it to the tuple-export selector (`BindingEscapeEmit.macro_pattern_site/3`). Each
  # candidate carries the pattern before/after (the diff), the shared export tuple, and the
  # *raw* mutant call (`rebuild_mutant.(mutated)`).
  #
  # A custom mutator that registered this macro (`macros/0`) may *also* have produced a
  # **whole-call** mutation — `analyze(:runtime)` offered the macro node to it, attaching a
  # `Candidate.InPlace`. Such a mutation can't ride an ordinary in-place selector: the macro's
  # bindings *escape*, so a selector wrapping the call would trap them inside the branch (and
  # for a piped call would splice the illegal `pattern |> case …`), leaving the bindings
  # undefined for the rest of the scope — the metamutant then fails to compile. So
  # `rehome_call_mutations/2` converts each whole-call mutation into a `MacroPattern` branch of
  # the *same* tuple-export selector — running the mutated call and exporting the bindings,
  # exactly like a pattern mutant — and strips it off the node (`Meta.take_candidates`). Both
  # kinds are then attached together in one `put_candidates_if_any`, so neither is lost.
  #
  # The export tuple is computed up front (`pattern_export_context/1`) from the pattern's bound
  # vars alone — **independent of whether any structural swap/wildcard mutant fires** — so a
  # whole-call mutation is re-homed even when no pattern mutant is produced (the user enabled
  # only their `macros/0` mutator, or the pattern admits no swap/wildcard). Without that the
  # whole-call `Candidate.InPlace` would survive as an ordinary hoisted-pipe selector and
  # poison the build. When the pattern binds nothing (or isn't rangeable) there is no escape to
  # re-export, so an in-place selector is already safe and `analyzed` is left untouched.
  defp attach_macro_pattern_candidates(analyzed, raw_pattern, rebuild_mutant, mutators) do
    case pattern_export_context(raw_pattern) do
      nil ->
        analyzed

      {pattern, range, export, used} ->
        pattern_candidates =
          macro_pattern_candidates(pattern, range, export, used, rebuild_mutant, mutators)

        {analyzed, call_candidates} = rehome_call_mutations(analyzed, export)

        # mutare:ignore[operand_swap] equivalent — `call_candidates` is non-empty only when a *custom* binding-macro mutator produced a whole-call mutation; the built-in set never does, so swapping the order of an empty list with `pattern_candidates` is a no-op for them.
        Attach.put_candidates_if_any(analyzed, call_candidates ++ pattern_candidates)
    end
  end

  # Re-home a binding macro's *whole-call* in-place mutations (a custom mutator's, attached by
  # `offer` during `analyze(:runtime)`) into `MacroPattern` candidates the tuple-export selector
  # hosts as extra branches, and return the node with them stripped (so emission doesn't *also*
  # wrap the call in a standalone selector).
  #
  # A **piped** stage carries its mutations on the `|>` RHS *child* (`[x, y] |> destructure(v)`).
  # Left in place, the child's postwalk would emit it as a selector `case`, and this node's
  # baseline (`strip_candidates/1` in `BindingEscapeEmit.macro_pattern_site/3`) would become the illegal
  # `pattern |> case …` — which also traps the macro's escaping bindings inside the branch. So
  # the stage's mutations are pulled off the child (the baseline is then the bare emitted pipe)
  # and each re-homed with `mutant_expr` the mutated stage piped back from the LHS pattern, so
  # the mutant branch runs `lhs |> <mutated stage>` and the bindings reach the export tuple.
  # mutare:ignore[guard_drop] equivalent — a `|>` RHS call node always has keyword-list meta, so the guard never excludes a real stage.
  defp rehome_call_mutations({:|>, meta, [lhs, {_form, rhs_meta, _args} = rhs]}, export)
       when is_list(rhs_meta) do
    {inplace, rhs} = take_inplace_candidates(rhs)

    call_candidates =
      Enum.map(inplace, fn ip ->
        call_mutation_candidate(ip, export, {:|>, meta, [lhs, ip.mutated]})
      end)

    {{:|>, meta, [lhs, rhs]}, call_candidates}
  end

  # A directly-written call carries its mutations on its own meta — re-home them with
  # `mutant_expr` the mutated call itself.
  # mutare:ignore[guard_drop] equivalent — a call node always has keyword-list meta, so the guard never excludes a real call.
  defp rehome_call_mutations({_form, meta, _args} = node, export) when is_list(meta) do
    {inplace, node} = take_inplace_candidates(node)

    call_candidates = Enum.map(inplace, &call_mutation_candidate(&1, export, &1.mutated))
    {node, call_candidates}
  end

  # mutare:ignore[clause_drop] equivalent — `rehome_call_mutations/2` is only ever called on the analyzed macro/pipe node, which always matches one of the two heads above; this fallback is unreachable for valid input.
  defp rehome_call_mutations(node, _export), do: {node, []}

  # Pull a node's whole-call **in-place** mutations off, returning `{in-place mutations, node}`
  # with only the in-place ones removed (any non-`InPlace` candidates stay). Only the in-place
  # ones (a whole-call mutation from a custom binding-macro mutator) are re-homed as MacroPattern
  # branches. The built-in mutators never produce an in-place candidate on a binding-macro call,
  # so `inplace` is usually `[]` and the node round-trips unchanged.
  defp take_inplace_candidates(node) do
    {all, node} = Meta.take_candidates(node, :in_place)
    {inplace, others} = Enum.split_with(all, &match?(%Candidate.InPlace{}, &1))
    {inplace, Meta.put_candidates(node, :in_place, others)}
  end

  # Convert one whole-call in-place mutation into a `MacroPattern` branch: the diff
  # (`original`/`mutated`/`range`) stays the call/stage the mutator changed, while `mutant_expr`
  # is what the branch *runs* — the (possibly piped) mutated call, before the export tuple. The
  # InPlace's `note` (a `mutate`-supplied per-mutant advisory) and `variant` (a `Mutation.tagged/2`
  # `# mutare:ignore` label) both ride through, so a noted *and* a tagged whole-call mutation on a
  # binding-escaping macro call keep their note and label on the `Mutare.Site` — the latter is what
  # a `[family:label]` directive matches on, so dropping it would leave the mutant unsuppressable.
  defp call_mutation_candidate(%Candidate.InPlace{} = ip, export, mutant_expr) do
    %Candidate.MacroPattern{
      mutator: ip.mutator,
      original: ip.original,
      mutated: ip.mutated,
      export: export,
      mutant_expr: mutant_expr,
      range: ip.range,
      note: ip.note,
      variant: ip.variant
    }
  end

  # The structural pattern mutants (swap/wildcard) for an already-discovered escaping pattern,
  # given its shared `export`/`range`/`used` (from `pattern_export_context/1`). Empty when no
  # structural family is enabled or the pattern admits none — the whole-call re-homing
  # (`rehome_call_mutations/2`) is then the only source of `MacroPattern` candidates.
  defp macro_pattern_candidates(pattern, range, export, used, rebuild_mutant, mutators) do
    pattern
    |> PatternStructure.node_mutations(used, PatternStructure.mutators(mutators))
    |> Enum.map(fn {mutator, mutated} ->
      %Candidate.MacroPattern{
        mutator: mutator,
        original: pattern,
        mutated: mutated,
        export: export,
        mutant_expr: rebuild_mutant.(mutated),
        range: range
      }
    end)
  end

  # The shared discovery for a pattern whose bindings *escape* and are re-exported through a
  # tuple — used by both the `=`-match (`MatchPattern`) and binding-pattern-macro
  # (`MacroPattern`) rewrites, which build a different candidate per mutation. Returns
  # `{pattern, range, export, [{mutator, mutated}]}` (the comment-stripped pattern, its range,
  # the shared export tuple, and the structural mutations), or `nil` when no structural family
  # is enabled, the pattern binds nothing, or it isn't rangeable.
  # mutare:ignore[clause_drop] equivalent — dropping this fast-path leaves the general clause to run `node_mutations(_, _, [])`, which returns `[]` for an empty structural set; the caller maps that to no candidates exactly as `nil` does.
  defp pattern_export_with_mutations(_raw_pattern, []), do: nil

  defp pattern_export_with_mutations(raw_pattern, structural) do
    case pattern_export_context(raw_pattern) do
      nil ->
        nil

      {pattern, range, export, used} ->
        {pattern, range, export, PatternStructure.node_mutations(pattern, used, structural)}
    end
  end

  # The pattern, its range, the shared export tuple, and its bound set — everything the
  # tuple-re-export rewrite needs that is **independent of which structural families are
  # enabled** (and of whether any structural mutation fires). Returns
  # `{pattern, range, export, used}`, or `nil` when the pattern binds nothing or isn't
  # rangeable. Split out so the binding-macro path can obtain the export tuple to re-home a
  # *whole-call* mutation onto even when no swap/wildcard pattern mutant is produced (see
  # `attach_macro_pattern_candidates/4`).
  defp pattern_export_context(raw_pattern) do
    # Sourceror attaches the *statement's* leading comment to its leftmost leaf — which, for a
    # `<pat> = e` or a piped `<pat> |> macro(…)`, is inside the pattern. Strip it so the
    # recorded `original`/`mutated` (rendered by `Site` via `Sourceror.to_string`) and the
    # generated branches don't carry it. The range/diff is unaffected (it reads positions).
    pattern = strip_comments(raw_pattern)

    with %{} = range <- NodeRange.get(pattern),
         [_ | _] = names <- PatternStructure.bound_var_names(pattern) do
      # Repeat each bound variable in the export tuple as many times as it *occurs* in the
      # pattern, so a variable the source self-used (a repeated binding `{a, a}`, a size var
      # `<<n, r::size(n)>>`) keeps that self-use in the outer rebind `{a, a} = …` instead of
      # collapsing to `{a} = …` — which would warn "unused variable" whenever the rest of
      # the scope never reads it, a warning the original didn't have. The repeated positions
      # all come from the *same* binding, so the rebind's `{a, a} = {v, v}` constraint is
      # always trivially satisfied and never re-imposes the original `t[0] == t[1]` one.
      counts = PatternStructure.occurrence_counts(pattern)
      export = export_tuple(Enum.flat_map(names, &List.duplicate({&1, [], nil}, counts[&1])))
      # Pass the full bound set as `used_outside` so the wildcard family stays in *thin*
      # mode (replace one occurrence, keep the variable bound). Every admitted mutation
      # then preserves the bound set, so the export stays consistent across all branches —
      # and every variable the export references stays bound in every branch (forced thin
      # is what lets the export repeat a variable safely; orphan-fix would strand it).
      used = MapSet.new(names)

      {pattern, range, export, used}
    else
      _ -> nil
    end
  end

  # Drop `:leading_comments`/`:trailing_comments` from every node's metadata. Used on the
  # `=`-match LHS, whose leftmost leaf carries the statement's leading comment (Sourceror
  # parks it there), so neither the recorded site nor the generated pattern repeats it.
  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      # NOTE: the `:trailing_comments` deletion is an equivalent survivor (deliberately not
      # ignored): Sourceror attaches no trailing comment to the discarded-pattern LHS nodes
      # this cleans, so swapping that key out leaks nothing. The `:leading_comments` deletion
      # *is* killed (a leading comment would otherwise leak into the recorded diff).
      # mutare:ignore[guard_drop] equivalent — every node `Macro.prewalk` visits is `{form, meta, args}` with keyword-list meta, so the guard never excludes a real node.
      {form, meta, args} when is_list(meta) ->
        {form, meta |> Keyword.delete(:leading_comments) |> Keyword.delete(:trailing_comments),
         args}

      other ->
        other
    end)
  end

  # The tuple of bound-variable nodes (with per-variable multiplicity, see above) shared by
  # the outer match and every inner-case return. A 2-element list is the unwrapped `{a, b}`
  # Sourceror produces (also the `{a, a}` a single repeated binding yields); 1 or 3+ use the
  # explicit `{:{}, …}` n-tuple form.
  # mutare:ignore[clause_drop, pattern_swap] equivalent — dropping the 2-element head leaves the general clause to build `{:{}, [], [a, b]}`, which renders and matches identically to `{a, b}`; and reversing `[a, b]` reverses the tuple consistently in *both* the outer match and the inner returns (the same `export` value is used for both), so the bindings still map correctly.
  defp export_tuple([a, b]), do: {a, b}
  defp export_tuple(vars), do: {:{}, [], vars}

  # A **chained** match (`pat = mid = rhs`) binds `mid` — and any deeper chain pattern — on top
  # of `pat`. Those bindings escape the original statement, but the tuple-re-export delivery makes
  # `rhs` the selector's inner-case *scrutinee* (`case rhs do <pat> -> <export>; … end`), so a
  # chain var bound while evaluating the scrutinee is trapped inside the selector branch — left
  # out of the export tuple it is undefined for the rest of the scope and the metamutant fails to
  # compile. Append every chain-bound var to the export so it rides back out through the outer
  # rebind; the scrutinee binds it in both the mutant and baseline branches, so it is in scope for
  # every branch's `<export>` return.
  #
  # Each chain var is repeated by its **occurrence count** in the chain pattern — exactly as the
  # LHS pattern's own vars are (`pattern_export_context/1`). A self-constraining link like
  # `{x, y} = {a, a} = e` thus exports `a` twice (`{x, y, a, a} = …`), so the outer rebind keeps
  # the self-use and doesn't gain an "unused variable a" warning the original never had; the two
  # slots come from the *same* binding, so the rebind's `{a, a} = {va, va}` is trivially satisfied
  # and re-imposes no constraint. A var the LHS pattern already exports is skipped (it is carried
  # once there, with its own multiplicity — a second slot *would* re-impose a spurious
  # `t[i] == t[j]` equality between two distinct tuple positions on the rebind).
  defp export_with_rhs_chain(export, raw_rhs) do
    existing = export_vars(export)
    existing_names = MapSet.new(existing, fn {name, _meta, _ctx} -> name end)
    link_patterns = rhs_chain_patterns(raw_rhs)

    counts =
      Enum.reduce(link_patterns, %{}, fn pattern, acc ->
        Map.merge(acc, PatternStructure.occurrence_counts(pattern), fn _name, a, b -> a + b end)
      end)

    extra =
      link_patterns
      |> Enum.flat_map(&PatternStructure.bound_var_names/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(existing_names, &1))
      |> Enum.flat_map(&List.duplicate({&1, [], nil}, Map.fetch!(counts, &1)))

    case extra do
      [] -> export
      _ -> export_tuple(existing ++ extra)
    end
  end

  # The tuple-export rewrite evaluates a chained RHS (`mid = value`) as the inner `case`
  # scrutinee, then matches the outer LHS inside that case. Usually that preserves the source's
  # right-to-left match order. It does not when the outer LHS pins a name that a chain pattern
  # rebinds: in the source, `^x` keeps the value from before the whole match, while inside the
  # generated case it sees the chain's new `x`. Decline structural candidates for exactly that
  # intersection so the baseline remains the original match. Preserving these candidates would
  # require snapshotting every pinned value before evaluating the chain, including fresh-name
  # and export plumbing; this rare shape is safer to leave unmutated.
  defp rhs_chain_rebinds_lhs_pin?(raw_lhs, raw_rhs) do
    pinned = pinned_var_names(raw_lhs)

    Enum.any?(rhs_chain_patterns(raw_rhs), fn pattern ->
      Enum.any?(PatternStructure.bound_var_names(pattern), &MapSet.member?(pinned, &1))
    end)
  end

  defp pinned_var_names(pattern) do
    {_pattern, names} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {:^, _meta, [{name, _var_meta, ctx}]} = pin, acc
        when is_atom(name) and is_atom(ctx) ->
          {pin, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # The LHS pattern of each `=` along a chained match's right spine (`a = b = {c, c} = e` →
  # `[b, {c, c}]`), stopping at the non-`=` **terminal** expression — whose vars are *reads*
  # (`parse(node)`), not bindings, so they must not be exported. Each returned node is a pure
  # pattern, safe for `bound_var_names`/`occurrence_counts`.
  defp rhs_chain_patterns({:=, _meta, [lhs, rhs]}), do: [lhs | rhs_chain_patterns(rhs)]
  defp rhs_chain_patterns(_rhs), do: []

  # The bound-variable nodes inside an export tuple built by `export_tuple/1`: the explicit
  # `{:{}, …}` n-tuple form (1 or 3+ vars) or the bare 2-tuple `{a, b}`.
  defp export_vars({:{}, _meta, vars}), do: vars
  defp export_vars({a, b}), do: [a, b]
end
