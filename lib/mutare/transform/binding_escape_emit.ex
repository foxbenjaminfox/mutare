defmodule Mutare.Transform.BindingEscapeEmit do
  @moduledoc false

  # The tuple-export delivery for the two binding-escape candidates:
  # `Mutare.Transform.Candidate.MatchPattern` (a value-discarded `=` match) and
  # `Mutare.Transform.Candidate.MacroPattern` (a binding-escaping known macro like
  # `destructure/2`). Both bind a pattern whose variables must **escape** the selector, so the
  # node can't be wrapped in an ordinary selector `case` (the bindings would be trapped in a
  # branch); instead each mutant runs in a branch of
  #
  #     <export> = case <sel> do <id> -> <mutant_body>; … ; mutare_active -> <catch_all> end
  #
  # and the escaping variables are re-exported through the shared `export` tuple and rebound
  # outside. This module owns the small stateful orchestration for that delivery: claiming ids
  # via `Ctx`, choosing the selector subject, preserving the all-poisoned fallback, and building
  # the per-branch bodies. `expression_bindings/1` also supplies the common export set when a
  # routed pipe's expression selector cannot bind its operand ahead of the call.

  alias Mutare.AST
  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.Candidate
  alias Mutare.Transform.Candidate.Delivery
  alias Mutare.Transform.{KeywordRouting, QuoteStructure}
  alias Mutare.Transform.{Calls, CoverageEmit, Ctx, Meta, PatternStructure, Resolve, SelectorEmit}

  @doc "Bindings guaranteed to escape an expression, each once, in the order they are bound (a match's right-hand side before its pattern)."
  @spec expression_bindings(Macro.t()) :: [atom()]
  def expression_bindings(node), do: node |> bound_names(%{}) |> Enum.uniq()

  defp bound_names({_form, meta, _args} = node, context) when is_list(meta),
    do: collect_bindings(node, Resolve.context(node, context))

  defp bound_names(node, context), do: collect_bindings(node, context)

  defp collect_bindings({:__block__, _, statements}, context) when is_list(statements) do
    {bindings, _context} =
      Enum.map_reduce(statements, context, fn statement, context ->
        {bound_names(statement, context), Resolve.advance_context(statement, context)}
      end)

    List.flatten(bindings)
  end

  # A withheld stage still receives argument zero when Kernel expands it. Inspect
  # that complete call so a conditional's branches never become its condition.
  defp collect_bindings({:|>, meta, args} = pipe, context) do
    case Resolve.preserved_pipe_call(pipe, context) do
      nil -> argument_bindings(args, Meta.routing(meta), context)
      call -> bound_names(call, context)
    end
  end

  # Only unconditional expression positions export bindings. Clause bodies, short-circuit
  # right operands, and syntax-routed arguments have their own scopes or evaluation rules.
  defp collect_bindings({:=, _, [pattern, rhs]}, context),
    do: bound_names(rhs, context) ++ PatternStructure.bound_var_names(pattern)

  defp collect_bindings({:case, _, [first | _]}, context), do: bound_names(first, context)

  defp collect_bindings({form, meta, [first | _] = args} = node, context)
       when form in [:if, :unless, :and, :or, :&&, :||] do
    if Calls.kernel_call?(node),
      do: bound_names(first, context),
      else: argument_bindings(args, Meta.routing(meta), context)
  end

  defp collect_bindings({form, _, _}, _context)
       when form in [:fn, :for, :with, :try, :cond, :receive, :->, :&],
       do: []

  # Live quote parts execute in the surrounding scope: option values, and the arguments
  # of escapes in a quoted body (`QuoteStructure`).
  defp collect_bindings({:quote, _, args}, context) when is_list(args) do
    {parts, _rebuild} = QuoteStructure.parts(args)

    Enum.flat_map(parts, fn
      {value, :live} -> bound_names(value, context)
      {value, :quoted} -> unquote_bindings(value, context)
      {_value, :inert} -> []
    end)
  end

  defp collect_bindings({form, meta, args}, context) when is_list(args) do
    bound_names(form, context) ++ argument_bindings(args, Meta.routing(meta), context)
  end

  defp collect_bindings({left, right}, context),
    do: bound_names(left, context) ++ bound_names(right, context)

  defp collect_bindings(list, context) when is_list(list),
    do: Enum.flat_map(list, &bound_names(&1, context))

  defp collect_bindings(_, _context), do: []

  defp argument_bindings(args, routing, context) do
    case routing do
      nil ->
        Enum.flat_map(args, &bound_names(&1, context))

      :skip ->
        # Skip withholds mutation and nested routing, not ordinary evaluation. Unresolved
        # calls still export their arguments' bindings unless a visible route says otherwise.
        Enum.flat_map(args, &bound_names(&1, context))

      treatments when is_list(treatments) ->
        Enum.zip(args, treatments)
        |> Enum.flat_map(fn {arg, treatment} ->
          argument_bindings_for(arg, treatment, context)
        end)

      _ ->
        []
    end
  end

  @doc """
  The bindings guaranteed to escape one argument of a routed call, read as its `treatment`
  says: an `:expression`/`:interior` value's, a `:binding_pattern`'s pattern names, a keyword
  treatment's pairs by their own treatments, and nothing from a position read as syntax or
  evaluated at the callee's discretion.
  """
  @spec argument_bindings(Macro.t(), term()) :: [atom()]
  def argument_bindings(arg, treatment),
    do: arg |> argument_bindings_for(treatment, %{}) |> Enum.uniq()

  defp argument_bindings_for(arg, treatment, context) when treatment in [:expression, :interior],
    do: bound_names(arg, context)

  defp argument_bindings_for(arg, :binding_pattern, _context),
    do: PatternStructure.bound_var_names(arg)

  defp argument_bindings_for(arg, {:keyed, _, _} = treatment, context),
    do: keyword_bindings(arg, treatment, context)

  defp argument_bindings_for(arg, {:keyword, _} = treatment, context),
    do: keyword_bindings(arg, treatment, context)

  defp argument_bindings_for(_arg, _treatment, _context), do: []

  defp keyword_bindings(arg, treatment, context) do
    case KeywordRouting.decode(arg, treatment) do
      {:pairs, pairs, _rewrap} ->
        Enum.flat_map(pairs, fn {{key, key_treatment}, {value, value_treatment}} ->
          argument_bindings_for(key, key_treatment, context) ++
            argument_bindings_for(value, value_treatment, context)
        end)

      {:whole, fallback} ->
        argument_bindings_for(arg, fallback, context)
    end
  end

  defp unquote_bindings({form, _, args} = node, context) when is_list(args) do
    case QuoteStructure.quoted(node) do
      {:escape, arg, _rebuild} ->
        bound_names(arg, context)

      {:options, options, _rebuild} ->
        unquote_bindings(options, context)

      :inert ->
        []

      :data ->
        unquote_bindings(form, context) ++ Enum.flat_map(args, &unquote_bindings(&1, context))
    end
  end

  defp unquote_bindings({left, right}, context),
    do: unquote_bindings(left, context) ++ unquote_bindings(right, context)

  defp unquote_bindings(list, context) when is_list(list),
    do: Enum.flat_map(list, &unquote_bindings(&1, context))

  defp unquote_bindings(_, _context), do: []

  # === binding-escaping `=` match: tuple re-export =====================================

  @doc """
  Emit a `Candidate.MatchPattern` site by re-exporting its bindings through a selector.
  """
  @spec match_site(Macro.t(), [Candidate.MatchPattern.t()], Ctx.t()) :: {Macro.t(), Ctx.t()}
  def match_site({:=, _meta, [_lhs, emitted_rhs]} = match_node, candidates, ctx) do
    %Candidate.MatchPattern{export: export, original: original_lhs} = hd(candidates)

    binding_site(
      match_node,
      export,
      candidates,
      ctx,
      fn c -> match_inner_case(c.raw_rhs, c.mutated, export) end,
      fn ids, ctx ->
        inner = match_inner_case(emitted_rhs, original_lhs, export)
        SelectorEmit.catch_all_clause(ids, inner, ctx)
      end
    )
  end

  @doc """
  `case <rhs> do <pattern> -> <export>; u -> Elixir.Kernel.raise(Elixir.MatchError, term: u) end`
  — re-binds the match by matching `rhs` against `pattern` and returning the shared export tuple.
  The trailing clause makes a non-match raise the *same* `MatchError` the original `=` raised (not
  a `CaseClauseError`): exact baseline semantics, and still a clean kill on a mutant whose pattern
  stopped matching. The pattern is a refutable container (a bare var / pin-only LHS is never
  offered), so that clause is always reachable.
  """
  @spec match_inner_case(Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  def match_inner_case(rhs, pattern, export) do
    {:case, [], [rhs, [do: [{:->, [], [[pattern], export]}, match_raise_clause()]]]}
  end

  @doc """
  `mutare_unmatched -> Elixir.Kernel.raise(Elixir.MatchError, term: mutare_unmatched)`.

  Both names are spelled in **absolute** form so they resolve **independently of the target
  module's lexical environment**, and the generated raise behaves identically to the `=` it
  replaces — which always raises `Elixir.MatchError` regardless of imports/aliases:

    * `Elixir.Kernel.raise` is *absolute-qualified*, so it survives both
      `import Kernel, except: [raise: 2]` (an exclusion only removes the *unqualified* macro — an
      unqualified `raise` there would make the metamutant baseline fail to compile) *and*
      `alias Foo, as: Kernel` (`__aliases__` led by `:Elixir` is never alias-rewritten, where a
      plain `Kernel.raise` could be redirected).
    * `Elixir.MatchError` is likewise the *absolute* form, so `alias Foo, as: MatchError` / a
      nested `MatchError` module can't redirect it to the wrong exception.

  The binding is local to this one clause body (a fresh case-clause pattern variable, used only
  here), so a fixed name can't capture or collide — unlike a lifted *head* arg, the gated-equality
  hazard `Names` salts against doesn't apply to a body case clause.
  """
  @spec match_raise_clause() :: Macro.t()
  def match_raise_clause do
    unmatched = {:mutare_unmatched, [], nil}

    raise_node =
      AST.absolute_call([:Kernel], :raise, [AST.absolute_alias([:MatchError]), [term: unmatched]])

    {:->, [], [[unmatched], raise_node]}
  end

  # === binding-escaping macro pattern mutation: tuple re-export ========================

  @doc """
  Emit a `Candidate.MacroPattern` site by running the binding macro inside selector branches.
  """
  @spec macro_pattern_site(Macro.t(), [Candidate.MacroPattern.t()], Ctx.t()) ::
          {Macro.t(), Ctx.t()}
  def macro_pattern_site(node, candidates, ctx) do
    %Candidate.MacroPattern{export: export} = hd(candidates)
    baseline = Meta.strip_delivery(node)

    binding_site(
      node,
      export,
      candidates,
      ctx,
      fn c -> macro_pattern_branch(c.mutant_expr, export) end,
      fn ids, ctx -> macro_pattern_catch_all(ids, baseline, export, ctx) end
    )
  end

  @doc """
  One selector branch body for a binding-pattern macro: run the macro (binding the pattern's vars
  into the branch scope), then yield the shared export tuple for the outer rebind —
  `{macro; export}`.
  """
  @spec macro_pattern_branch(Macro.t(), Macro.t()) :: Macro.t()
  def macro_pattern_branch(macro_call, export),
    do: {:__block__, [], [macro_call, export]}

  @doc """
  The selector catch-all for a rewritten binding-pattern macro: record the hosted ids (inert
  outside the probe), run the baseline (emitted) macro, then yield the export.
  """
  @spec macro_pattern_catch_all([pos_integer()], Macro.t(), Macro.t(), Ctx.t()) ::
          {Macro.t(), Ctx.t()}
  def macro_pattern_catch_all(ids, baseline, export, ctx) do
    {record, ctx} = CoverageEmit.record(ids, ctx, :local)
    body = {:__block__, [], [record, baseline, export]}
    {{:->, [], [[Recorder.catch_all_pattern(ctx.config.active_var)], body]}, ctx}
  end

  # Shared skeleton for the tuple-export rewrites. The callers supply only the mutant branch body
  # and the baseline catch-all; id claiming, site recording, selector assembly, and the all-poisoned
  # fallback are common.
  defp binding_site(node, export, candidates, ctx, mutant_body, catch_all)
       when is_function(mutant_body, 1) and is_function(catch_all, 2) do
    {clauses, ctx} =
      SelectorEmit.claim_items(candidates, ctx, {&Delivery.site/4, &Delivery.line/1}, fn id,
                                                                                         candidate ->
        {:->, [], [[id], mutant_body.(candidate)]}
      end)

    case clauses do
      [] ->
        {Meta.strip_delivery(node), ctx}

      _ ->
        ids = SelectorEmit.ids_from_clauses(clauses)
        {fallback, ctx} = catch_all.(ids, ctx)
        {case_node, ctx} = SelectorEmit.raw_case(clauses, fallback, ctx)
        {{:=, [], [export, case_node]}, ctx}
    end
  end
end
