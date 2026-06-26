defmodule Mutare.Transform.BindingEscapeEmit do
  @moduledoc false

  # The pure AST builders for the two **tuple-export** rewrites — the binding-escape delivery of
  # `Mutare.Transform.Candidate.MatchPattern` (a value-discarded `=` match) and
  # `Mutare.Transform.Candidate.MacroPattern` (a binding-escaping known macro like
  # `destructure/2`). Both bind a pattern whose variables must **escape** the selector, so the
  # node can't be wrapped in an ordinary selector `case` (the bindings would be trapped in a
  # branch); instead each mutant runs in a branch of
  #
  #     <export> = case <sel> do <id> -> <mutant_body>; … ; mutare_active -> <catch_all> end
  #
  # and the escaping variables are re-exported through the shared `export` tuple and rebound
  # outside. `Mutare.Transform.emit_binding_site/6` owns the stateful orchestration (claiming
  # ids via `Ctx`, choosing the subject, the all-poisoned fallback) and calls these to build the
  # per-branch bodies — the same split as `CaseClauseEmit` / `emit_case_pattern_site/3`.

  alias Mutare.AST
  alias Mutare.Coverage.Recorder

  # === binding-escaping `=` match: tuple re-export =====================================

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
  @spec macro_pattern_catch_all([non_neg_integer()], Macro.t(), Macro.t(), atom()) :: Macro.t()
  def macro_pattern_catch_all(ids, baseline, export, var) do
    body = {:__block__, [], [Recorder.record_ast(ids, var), baseline, export]}
    {:->, [], [[Recorder.catch_all_pattern(var)], body]}
  end
end
