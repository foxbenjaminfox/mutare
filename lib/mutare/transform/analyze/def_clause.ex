defmodule Mutare.Transform.Analyze.DefClause do
  @moduledoc false

  # The body-keyword machinery of a `def`/`defp` clause: normalize its block shape, route each
  # block (`:do`/`:after` runtime, `:rescue`/`:catch`/`:else` clause lists), and host a
  # `def … rescue …` shorthand in a synthesized `try` so `RescueType` reaches it. Extracted from
  # `Mutare.Transform.Analyze` (the `def`/`defp` clause calls `normalize_clause_blocks/1` →
  # `analyze_do_blocks/2` → `host_def_rescue/3`); it reaches back only through the public
  # descent (`Analyze.annotate/2` for `:runtime`, `Analyze.pattern/2` for `:pattern`) and
  # `Analyze.put_candidates/2`/`clause_block_key?/1`, exactly like the sibling analyze submodules.

  alias Mutare.Transform.Analyze
  alias Mutare.Transform.Analyze.ClausePatterns

  # An **inline-keyword** rescue/catch/else (`def f, do: …, rescue: (p -> b)`) parses its clause
  # value as a `{:__block__, _, [clauses]}` wrapper, where a block-form body's clause value is a
  # bare list. Unwrap the former so every downstream consumer sees one shape: the clause routing
  # in `analyze_do_blocks/2` (guarded on `is_list` — otherwise the whole rescue is mis-analyzed as
  # a *runtime expression*, splicing a selector into a position no `->` clause may hold: poison),
  # the rescue-clause-body return tails in `annotate_returns/3` (likewise `is_list`-guarded), and
  # the rescue narrowing/clause-drop discovery in `host_def_rescue/3` → `rescue_type_candidates/3`
  # (whose `:rescue` list guard would otherwise miss it, so the valid inline `def … rescue` form
  # produced no `:rescue_type` mutants). A block-form body's clause values are already bare lists,
  # so this is a no-op there; non-clause keys (`:do`/`:after`) are never unwrapped.
  def normalize_clause_blocks(body_kw) do
    Enum.map(body_kw, fn
      {key, {:__block__, _meta, [clauses]}} = pair when is_list(clauses) ->
        if Analyze.clause_block_key?(key), do: {key, clauses}, else: pair

      pair ->
        pair
    end)
  end

  # The body keyword of a clause (`[do: …, rescue: …, catch: …, else: …,
  # after: …]`, possibly with Sourceror's `{:__block__, _, [:do]}` keys). `:do`
  # and `:after` are ordinary runtime bodies. `:rescue`/`:catch`/`:else` are
  # *clause lists* whose left side is a match, not runtime code, so each clause's
  # patterns are analyzed in `:pattern` (never mutated — a selector `case` spliced
  # into a rescue/else pattern is illegal Elixir and would poison the single
  # build) and only its body in `:runtime`. (`cond`, whose clause left *is*
  # runtime, is handled generically; here the routing is unambiguous because these
  # blocks always pattern-match.)
  def analyze_do_blocks(body_kw, mutators) do
    Enum.map(body_kw, fn {key, value} ->
      if Analyze.clause_block_key?(key) and is_list(value),
        do: {key, Enum.map(value, &analyze_try_clause(&1, mutators))},
        else: {key, Analyze.annotate(value, mutators)}
    end)
  end

  # A `def … rescue …` shorthand (sugar for wrapping the body in a `try`) carries its
  # rescue/catch/else/after as **def-body blocks**, not a `try` node — so the `:try` analyze
  # clause never sees it and `RescueType`'s narrowing / clause-drop would be skipped. (`raw_body_kw`
  # has already been `normalize_clause_blocks/1`-ed, so an inline-keyword rescue's clause list is a
  # bare list here, not Sourceror's `{:__block__, _, [clauses]}` wrapper.) Deliver
  # them by **hosting the body in a synthesized `try`**: when the body has rescue candidates,
  # replace the whole body keyword with `[do: try]`, the `try` carrying those candidates, so the
  # same whole-construct selector that wraps an explicit `try` wraps this one. The hosted (catch-
  # all) `try` is the **already-analyzed** body (`annotated_kw` — its do/rescue bodies keep their
  # operator and *granular* return-value selectors), so nothing the shorthand already mutated is
  # lost; the mutant branches are raw tries with one rescue clause narrowed/dropped. Sound and
  # value-transparent: `def f do b rescue r end` ≡ `def f do try do b rescue r end end` (a `try`
  # leaks no bindings, and the function's value is the try's). No rescue block / no candidates
  # (`RescueType` off, or a single-type single-clause rescue) ⇒ the body keyword is untouched, so
  # the shorthand's existing return/operator mutations are unaffected. Works under lifting for
  # free: the relocated original clause's body becomes `[do: <selector>]` like any in-place body.
  def host_def_rescue(annotated_kw, raw_body_kw, mutators) do
    # `do:`/`end:` block markers force Sourceror to render the synthesized `try` in block form
    # (`try do … rescue … end`); a `[]`-meta `try` over the source's `{:__block__, …, [:do]}`
    # block keys would otherwise render the invalid inline keyword form (`try do: …, rescue: …`).
    # The marker values are empty (these are generated, lineless nodes); the same meta is threaded
    # to the candidates' rebuilt mutant tries via `rescue_type_candidates/3`.
    try_meta = [do: [], end: []]

    case ClausePatterns.rescue_type_candidates(raw_body_kw, try_meta, mutators) do
      [] -> annotated_kw
      candidates -> [do: Analyze.put_candidates({:try, try_meta, [annotated_kw]}, candidates)]
    end
  end

  # One `rescue`/`catch`/`else` clause: its patterns are matches (`:pattern`), its
  # body is runtime. A `when` guard among the patterns is returned whole by the
  # `:when` clause of `analyze/3` (guard mutation in a try clause isn't supported).
  defp analyze_try_clause({:->, meta, [patterns, body]}, mutators) when is_list(patterns) do
    patterns = Enum.map(patterns, &Analyze.pattern(&1, mutators))
    {:->, meta, [patterns, Analyze.annotate(body, mutators)]}
  end

  defp analyze_try_clause(other, mutators), do: Analyze.annotate(other, mutators)
end
