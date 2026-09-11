defmodule Mutare.Transform.Analyze do
  @moduledoc false

  # The analyze + classify pass of the transform: a syntax-directed walk that
  # *names the context* of each position as it descends and attaches a typed
  # `Mutare.Transform.Candidate` to every node a mutator recognises in a mutating
  # context (via the node's own `meta[:mutare]`). Pure and id-free — `Mutare.Transform`
  # owns emission (id assignment, selectors, lifting) and calls in here to annotate a
  # subtree first. The dependency is one-way: this module never calls back into
  # emission.
  #
  # Entry points: `annotate/2` (the `:runtime` in-place walk), `scaffold/2` (a
  # module-level compile-time statement), and the module-macro-block classifiers
  # `module_scaffold_statement?/1` / `module_macro_block_statement?/1` /
  # `analyze_module_macro_block/2` that `Mutare.Transform.transform_statement/2` routes on.
  #
  # The pass is split across handler submodules this dispatch routes to (`Conditions`,
  # `ClausePatterns`, `MatchPatterns`, `Routed`, `DefClause`, `Returns`, `Captures`, `CallOptions`,
  # `QuoteEscape`). Candidate construction/attachment lives in `Analyze.Attach` and the block-key
  # predicates in `Analyze.Syntax`; a handler that genuinely recurses re-enters the walk by
  # calling this module directly — `annotate/2`, `pattern/2`, `descend/3`, `recurse/3` — so the
  # module graph has a runtime-call cycle between this dispatch and each such handler, on
  # purpose (NOTES "Analyze handlers call the descent statically").

  alias Mutare.AST
  alias Mutare.Mutator.Dispatch
  alias Mutare.Transform.{Candidate, Meta, Suppression}

  # The suppression operator vocabulary, in guard position (see `Suppression`'s twin-map):
  # the body path's five equivalent-sibling clauses below match on these shared `defguard`s
  # rather than literal operator lists, so they can't drift from the guard path's twins in
  # `Mutare.Transform.Tag`.
  import Suppression, only: [is_negation_op: 1, is_equality_op: 1, is_body_connective: 1]

  alias Mutare.Transform.Analyze.{
    Attach,
    CallOptions,
    Captures,
    ClausePatterns,
    Conditions,
    DefClause,
    Routed,
    MatchPatterns,
    QuoteEscape,
    Returns,
    Syntax
  }

  # Module-level forms whose block/children are known compile-time structure.
  # Unknown module-level macro calls with a block are handled separately so a DSL
  # that unquotes its `do` body into generated runtime functions keeps body mutants.
  @module_scaffold_forms [
    :@,
    :if,
    :unless,
    :for,
    :case,
    :cond,
    :with,
    :try,
    :receive,
    :quote,
    :defmacro,
    :defmacrop,
    :defimpl,
    :defprotocol,
    :defdelegate,
    :import,
    :alias,
    :require,
    :use
  ]

  # --- analyze: classify context positively, attach candidates -----------------

  # A syntax-directed walk that *names the context* of each position as it
  # descends, rather than subtracting a blacklist from "everything is a runtime
  # body". Routing is positional, so child → context is a pattern match — which a
  # single `Macro.traverse` accumulator can't express (it can't send the spec
  # side of a `::` one way and the value side another). Four contexts are threaded:
  #
  #   * `:runtime` — mutate in place. A node a mutator recognises gets a
  #     `Candidate.InPlace` attached to its own metadata; the candidate is built
  #     from the *raw* node (un-annotated children — what the report renders)
  #     before we descend.
  #   * `:pattern` — never mutate, but keep descending so nested runtime escapes
  #     (default-argument values, `size(...)` args) are still reached.
  #   * `:scaffold` — a module-level non-clause statement entered from
  #     `transform_statement/2`. Like `:pattern` it never mutates in place and keeps
  #     descending — the module body runs once, at compile time, with mutant 0
  #     active, so a selector spliced into the statement's own expressions (an `if`
  #     condition, a `for` generator, an unquoted generated head pattern, or any
  #     other bare module-body calculation) could never activate — but the one
  #     runtime escape it reaches is an explicit `def`/`defp` body (the def clause
  #     flips it back to `:runtime`). `body_context/1` propagates `:scaffold`
  #     through `case`/`cond`/… arms so nested scaffolds stay inert too.
  #
  # The remaining contexts are recognised positively and realised as pruned
  # subtrees or dedicated helpers (named here, matched in the clauses below):
  #
  #   * `:compile_time` — module-attribute values (`@x <expr>`), macro bodies
  #     (`defmacro`/`defmacrop`), `quote` blocks (AST construction), and lexical
  #     directives (`import`/`alias`/`require`/`use`, whose args must be
  #     compile-time literals). Frozen at compile / macro-expansion time, so a
  #     runtime selector there can never activate — and inside a directive arg, or
  #     a quoted pattern/guard, would not even be legal. Pruned whole.
  #   * `:spec` — the type-specifier side of a bitstring `::` segment. A `case`
  #     is illegal there and a swapped `-` separator is an illegal specifier;
  #     only `size(expr)` args are a genuine runtime sub-position (`analyze_spec/3`).
  #   * `:guard` — `when` guards, owned by the lift path (a `case` can't live in a
  #     guard). Pruned here; `FunctionPlan` mutates them by lifting instead.
  #   * `:capture_arity` — the `/` in `&fun/arity`, an arity separator not
  #     division. Pruned; real division (`& &1 / 2`) still mutates.
  #
  # On top of the node-level operator candidates, the `def`/`defp` clause is *also*
  # a structural site: the tail of each of its return-path blocks (`:do`, and each
  # `rescue`/`catch`/`else` clause body) is a return-value position
  # (`annotate_returns/3`), where a `Candidate.Return` constant is appended to the
  # tail node's own metadata — delivered by the same in-place selector, on the same
  # node, as any operator candidate there.
  #
  # Ids are *not* assigned here; emission does that bottom-up to keep post-order
  # id ordering.
  def annotate(node, mutators), do: analyze(node, :runtime, mutators)

  # The `:scaffold` entry: a module-level non-clause statement, descended but
  # never mutated in place (see the doc above and `Mutare.Transform`).
  def scaffold(node, mutators), do: analyze(node, :scaffold, mutators)

  # The `:pattern` entry: a match position — descended (so default-arg values and `size()`
  # args are still reached) but never mutated *in place*. Part of the sub-walk API
  # `Mutare.Transform.Analyze.Routed` drives the `:pattern`/`:binding_pattern` argument routing
  # through (the in-module counterpart to `annotate/2`).
  def pattern(node, mutators), do: analyze(node, :pattern, mutators)

  # The general context-carrying descent — `annotate`/`scaffold`/`pattern` are this specialized
  # to a fixed context. Public so a split-out analyze helper (e.g. `Analyze.Conditions`, which
  # owns `cond`/`if` routing) can fall back to the full descent in whatever liveness context it
  # was handed, instead of re-deriving the dispatch.
  def descend(node, context, mutators), do: analyze(node, context, mutators)

  # The one entry every form clause below is reached through — the public wrappers above and
  # every recursive descent alike — so the call-level `:skip` is honoured **before** any
  # form-specific clause looks at the node. A route names a resolved head and the resolver stamps
  # whatever it resolves — `Mixpanel.track/3`, but equally `Kernel.if/2`, `Kernel.and/2`, or
  # `Kernel.SpecialForms.case/2` — so the inert-leaf promise must hold for the heads with their
  # own clauses here (`if`/`unless`, `case`, `cond`, `with`, the negations and connectives, …)
  # exactly as for a call the generic clause handles: not offered, not descended, whatever the
  # context. (The negation clauses check their *inner* operand the same way, so a skipped `in`
  # under `not` is a leaf too.) Positional routes never reach a structural head — they are
  # rejected or excluded upstream, `Mutare.Transform.StructuralForms`. `Mutare.Transform.Tag`
  # does the same at the head of its guard and pattern walks; `Analyze.Returns` treats a skipped
  # tail as one leaf.
  defp analyze(node, context, mutators) do
    if Meta.skipped?(node), do: node, else: analyze_form(node, context, mutators)
  end

  # `when` guard (position-independent: also covers case/fn clause guards): the
  # lift path owns guard mutation, so the in-place walk never touches one.
  defp analyze_form({:when, _meta, [_call | guards]} = node, _context, _mutators)
       when guards != [],
       do: node

  # module attribute `@x <value>`: compile-time, pruned whole. A bare `@x` read
  # has an atom context (not a single-value list) and falls through to runtime.
  defp analyze_form({:@, _meta, [{_name, _am, [_value]}]} = node, _context, _mutators), do: node

  # `defmacro`/`defmacrop`: compile-time / macro-generated, pruned whole.
  defp analyze_form({vis, _meta, _args} = node, _context, _mutators)
       when vis in [:defmacro, :defmacrop],
       do: node

  # `import`/`alias`/`require`/`use`: lexical directives resolved at compile time.
  # Their arguments are not a runtime position — an `import`'s `only:`/`except:`
  # must be a *literal* keyword list, an `alias`'s `as:` a literal atom, a `use`'s
  # options are handed to a macro at expansion — so a runtime selector there is at
  # best inert and at worst illegal (it makes the single build fail). Pruned whole;
  # the directive rides through untouched and in position.
  defp analyze_form({form, _meta, args} = node, _context, _mutators)
       when form in [:import, :alias, :require, :use] and is_list(args),
       do: node

  # `defprotocol`/`defdelegate`: pure compile-time module references with no runtime
  # body to mutate — `defprotocol` declares signatures, `defdelegate` forwards to a
  # `to:` module. A selector spliced into the protocol name / delegation target would
  # not compile (it expects a literal module), so prune whole. (Relevant once an alias
  # mutator can match the module references they carry.)
  defp analyze_form({form, _meta, _args} = node, _context, _mutators)
       when form in [:defprotocol, :defdelegate],
       do: node

  # `defimpl` reached as an *expression*: the protocol alias and the `for:` type are
  # compile-time module references (a selector there won't compile), but the `do:` block
  # *is* runtime — its implementation defs must still mutate. Analyze only the `do:` value,
  # passing the protocol-alias arg and every non-`do:` keyword entry (notably `for:`) through
  # raw. This handles both the block form (`for:`/`do:` in separate args) and the inline form
  # (folded into one keyword). Two kinds of `defimpl` arrive here: one nested inside a scaffold
  # (`for type <- … do defimpl … end`, analyzed whole with the scaffold) and a *displaced* one
  # (a DSL macro over `Kernel.defimpl`). A genuine `Kernel.defimpl` standing as a module-body
  # statement never does — `Mutare.Transform` plans it as a module body (so its guards/head
  # literals/clause structure lift), keyed on the impl-module stamp `Resolve` leaves on it.
  defp analyze_form({:defimpl, meta, args}, _context, mutators) when is_list(args) do
    {:defimpl, meta, Enum.map(args, &analyze_defimpl_arg(&1, mutators))}
  end

  # `quote`: its body is compile-time AST *construction*, not runtime code. The
  # literals there become part of the code the quote *generates* — instrumenting
  # which is out of scope (PHILOSOPHY: "macro-generated code is a different tool"),
  # exactly like a `defmacro` body. Worse, a selector `case` spliced into a quoted
  # pattern or guard (e.g. `quote do: (case x do "" -> … end)`) is valid *as a
  # quote* but illegal where the AST is later compiled — a poison the pre-filter
  # can't see, because the metamutant itself compiles. So quoted data stays raw.
  #
  # The runtime exception is an escaping `unquote(expr)` / `unquote_splicing(expr)`:
  # `expr` is evaluated when the quote is built, so in a runtime quote it can host
  # ordinary in-place selectors. This is quote-level aware: a single unquote inside
  # an inner quote only escapes that inner quote and remains data to the outer one;
  # `quote unquote: false` and implicit `bind_quoted` unquote disabling both
  # leave the quote raw; `unquote: true` explicitly re-enables escaping.
  defp analyze_form({:quote, meta, args} = node, :runtime, mutators)
       when is_list(args) do
    if QuoteEscape.quote_unquote_enabled?(args),
      do: {:quote, meta, QuoteEscape.analyze_quote_args(args, 1, mutators)},
      else: node
  end

  defp analyze_form({:quote, _meta, args} = node, _context, _mutators)
       when is_list(args),
       do: node

  # `&Mod.fun/arity` capture: the `/` is arity, not division. The capture is a call *value*
  # (`&Mod.fun/N ≡ fn a… -> Mod.fun(a…) end`), so in a **`:runtime`** position it is offered to
  # the call-matching families (renames + CallRemoval) by `Captures.offer/4` — which probes them
  # with a synthesized N-ary call and re-captures each mutant — instead of being pruned. A
  # *bare/local* ref is deferred (left unmutated by `offer`); anything else under `&`
  # (e.g. `& &1 / 2`) keeps mutating in the surrounding context.
  #
  # A genuine capture reached in a **non-runtime** context — module-level `:scaffold`
  # metaprogramming (`for f <- [&String.first/1] do def … end`), where the surrounding statement
  # runs *once* at compile time with mutant 0 active — must NOT be offered: like every other
  # scaffold position, a selector there could never activate or record coverage at test time, so
  # it would only mint inert no-coverage mutants. Leave the capture raw (the `/` is an arity
  # separator, `:capture_arity`, so there is nothing to descend into); a real `def` body reached
  # from the scaffold flips back to `:runtime` and its captures mutate normally.
  defp analyze_form({:&, _meta, [{:/, _smeta, [left, right]}]} = node, context, mutators) do
    cond do
      not Captures.capture_ref?(left, right) ->
        recurse(node, context, mutators)

      context == :runtime ->
        Captures.offer(node, left, right, mutators)

      true ->
        node
    end
  end

  # An *expression* capture (`&(&1 && &2)`, `&if(v = f(&1), do: v, else: g(&1))`): the body is
  # ordinary runtime code (unlike the `&Mod.fun/N` reference capture above), so it analyzes
  # exactly like the generic runtime clause — except that the direct capture argument is the
  # one expression position where a `__block__` is illegal ("block expressions are not allowed
  # inside the capture operator &"; every *nested* position under `&` accepts one). The only
  # block the descent manufactures is the if/unless condition hoist, so it is re-delivered
  # with the hoists folded into the condition (`Conditions.fold_hoist_into_condition/1`) — a
  # legal, semantically identical position — before the capture is rebuilt.
  defp analyze_form({:&, _meta, [_body]} = node, :runtime, mutators) do
    case do_analyze_call_node(node, mutators, %{pipe_mode: :unpiped}) do
      {:&, amp_meta, [child]} ->
        {:&, amp_meta, [Conditions.fold_hoist_into_condition(child)]}

      other ->
        other
    end
  end

  # A `def`/`defp` clause reaching the in-place path (one that did not lift, or the
  # *original* clause of a lifted group): the head is a pattern, the body keyword is
  # runtime, and the `:do` block's *tail expression* is additionally a return-value
  # position (only the transform knows where a clause returns — see
  # `annotate_returns/3`). A `def … rescue …` shorthand additionally gets its rescue
  # clauses narrowed/dropped (`host_def_rescue/3`). The body is first
  # `Syntax.normalize_clause_blocks/1`-ed so an **inline keyword** rescue/catch/else
  # (`def f, do: …, rescue: (p -> b)`) reads like its block-form twin.
  defp analyze_form({vis, meta, [head, body_kw]}, _context, mutators)
       when vis in [:def, :defp] and is_list(body_kw) do
    head = analyze(head, :pattern, mutators)
    body_kw = Syntax.normalize_clause_blocks(body_kw)
    analyzed_kw = DefClause.analyze_do_blocks(body_kw, mutators)
    annotated_kw = Returns.annotate_returns(analyzed_kw, body_kw, mutators)
    {vis, meta, [head, DefClause.host_def_rescue(annotated_kw, body_kw, mutators)]}
  end

  # bitstring: each segment's value keeps the surrounding context; the spec side
  # is excluded except for `size(expr)` args (`analyze_segment/3`). In a runtime
  # body the `<<…>>` node is *also* offered to mutators (BitstringLiteral collapses
  # it to `<<>>`) — built from the raw node so the diff renders the author's
  # literal, with the analyzed segments kept underneath so their own selectors stay
  # reachable. In a pattern (or any non-runtime context) it is only descended.
  #
  # A **real bitstring** (no `delimiter`) is a *construction*: its segments are
  # type-pinned via `analyze_construction_segment/2` so a binary-valued literal
  # segment that gets a selector keeps its `binary` type (see there). An
  # **interpolated string** / heredoc (`delimiter`-marked `<<>>`) is *not* a
  # construction — its parts are string content, descended as ordinary segments.
  defp analyze_form({:<<>>, meta, segments} = node, :runtime, mutators) do
    seg_fun =
      if Keyword.has_key?(meta, :delimiter),
        do: &analyze_segment(&1, :runtime, mutators),
        else: &analyze_construction_segment(&1, mutators)

    analyzed = {:<<>>, meta, Enum.map(segments, seg_fun)}
    Attach.offer(analyzed, node, mutators)
  end

  defp analyze_form({:<<>>, meta, segments}, context, mutators) do
    {:<<>>, meta, Enum.map(segments, &analyze_segment(&1, context, mutators))}
  end

  # `%Struct{…}`: the inner `%{…}` is the struct's *field map*, not a standalone
  # map literal — collapsing it to `%{}` (MapLiteral) would drop required fields /
  # change the struct, not shrink "the same" value. Descend into the field map's
  # contents (so each field *value* still mutates) but never offer the `%{}` wrapper
  # itself to a mutator, and — unlike a free-form map/keyword key — keep each field
  # *key* raw: a struct field name is compile-time-checked, so mutating it to another
  # atom names a field the struct doesn't define (a compile error, both for the
  # literal `%S{a: 1}` and the update `%S{m | a: 1}` forms). The alias rides untouched.
  defp analyze_form({:%, meta, [aliases, {:%{}, mmeta, pairs}]}, context, mutators)
       when is_list(pairs) do
    pairs = Enum.map(pairs, &analyze_struct_field(&1, context, mutators))
    {:%, meta, [aliases, {:%{}, mmeta, pairs}]}
  end

  # A runtime statement sequence: every statement but the **last** is in *statement
  # position* — its value is discarded (only the block's final expression is its value).
  # That is exactly where a `=` match can be rewritten to mutate its LHS pattern: a
  # destructuring `=` there is used solely for its bindings, so re-exporting them through
  # a tuple (`attach_match_pattern_candidates/4`) is value-transparent. A trailing `=`
  # *is* the block's value, so it stays a plain match (its value would change — see
  # `Candidate.MatchPattern`). Non-`=` statements analyze exactly as before. A single- or
  # empty-statement block has no non-final statement, so it falls through to the generic
  # recurse below (its lone statement is the value, analyzed normally).
  defp analyze_form({:__block__, meta, stmts}, :runtime, mutators)
       when is_list(stmts) and length(stmts) >= 2 do
    {init, [last]} = Enum.split(stmts, -1)
    init = Enum.map(init, &MatchPatterns.analyze_statement(&1, mutators))
    {:__block__, meta, init ++ [analyze(last, :runtime, mutators)]}
  end

  # match `=`: the left side is a pattern, the right keeps the context. The `=` node itself is
  # deliberately **not** offered to mutators (no `offer/3` here) — there is no "mutate `=`" entry
  # point, unlike the *macro* node (`analyze_routed_call` offers it so a `call_routes/0` mutator can
  # fire). This is load-bearing: it is *why* the value-discarded-`=` path
  # (`attach_match_pattern_candidates/4`) can prepend its `MatchPattern` candidates with
  # `put_candidates` without shadowing anything, and why no whole-`=` mutation can trap the
  # escaping bindings. If you ever start offering this node, mirror the macro path's
  # `rehome_call_mutations/2`: re-home the whole-`=` mutation into the tuple-export selector
  # (give `Candidate.MatchPattern` a `mutant_expr`-style field, as `MacroPattern` has). The
  # invariant is guarded by `match_pattern_test.exs` ("a bare `=` node is never offered…").
  defp analyze_form({:=, meta, [lhs, rhs]}, context, mutators) do
    {:=, meta, [analyze(lhs, :pattern, mutators), analyze(rhs, context, mutators)]}
  end

  # `<-` generator/with-clause: the left is a pattern (matched against each value
  # in `for x <- …`, or the right's result in `with {:ok, x} <- …`), the right keeps
  # the context. Mirrors `=` — without it a literal in the LHS would be mutated.
  defp analyze_form({:<-, meta, [lhs, rhs]}, context, mutators) do
    {:<-, meta, [analyze(lhs, :pattern, mutators), analyze(rhs, context, mutators)]}
  end

  # (`match?`/`destructure` and any other pattern-context macro are no longer a
  # dedicated clause here: they are *known macros* (`Mutare.CallRouting.Registry`), recognised by
  # the lexical pre-pass via their resolved module — so a bare `match?(p, e)` is
  # routed only when it is genuinely `Kernel.match?`, and an aliased/qualified or
  # user-registered macro is handled the same way. The routing is read from the
  # `meta[:mutare_route]` stamp in the generic runtime clause below.)

  # `cond`: the one `->` construct whose clause *left* is a runtime condition, not
  # a pattern — so it stays mutatable. Analyze its clauses keeping both sides
  # runtime, intercepting them before the generic `->` clause (below) would wrongly
  # pattern-route the conditions. The `:do` block key is protected by the
  # keyword-pair clause. The blocks are first `Syntax.normalize_clause_blocks/1`-ed
  # so the keyword form (`cond(do: (c -> b))`) reads like its block-form twin —
  # otherwise the wrapped clause list falls past `cond_block`'s list guard into the
  # generic descent, which pattern-routes the conditions and leaves them unmutated.
  defp analyze_form({:cond, meta, [blocks]}, context, mutators) when is_list(blocks) do
    blocks = Syntax.normalize_clause_blocks(blocks)
    {:cond, meta, [Conditions.cond_blocks(blocks, body_context(context), mutators)]}
  end

  # `if`/`unless`: the condition is an ordinary runtime expression *and* the one
  # position `Mutare.Mutators.IfCondition` targets — it forces the condition to
  # `true`/`false` (the "remove the decision" mutation) for the conditions a value
  # family can't reach (a bare predicate call, `is_*`, a remote boolean), the
  # boolean-operator ones being left to `Conditional`. So the condition is analyzed
  # as a condition (`analyze_condition/2` — runtime, plus IfCondition, minus any
  # selector that would trap an escaping binding; see there); the body keyword
  # (`do:`/`else:` values) is analyzed exactly as the generic runtime clause would,
  # and the whole node is still offered to mutators for parity (a custom mutator
  # matching an `if`; the built-ins match none). A `:skip` route on `if`/`unless`
  # (`{Kernel, :if, 2, :skip}`) never reaches this clause — `analyze/3` returns the
  # node first — and a positional route never reaches the node at all
  # (`Mutare.Transform.StructuralForms`).
  #
  # When the condition binds a variable that escapes into the body (`if (name =
  # lookup()) != nil do …`), the plain path can't host a condition selector (it would
  # trap the binding — see `analyze_condition/2`), so a hoistable case is restructured
  # into a `__block__` that lifts the binding out and lets the now-binding-free
  # condition carry the decision mutant (`hoist_if/6`). Only `:runtime` — a module-level
  # (`:scaffold`) `if` runs once at compile time, so its condition is inert and falls
  # through to the non-mutating catch-all.
  defp analyze_form({form, meta, [condition, body_kw]} = node, :runtime, mutators)
       when form in [:if, :unless] and is_list(body_kw) do
    analyzed_body = analyze(body_kw, :runtime, mutators)
    analyzed_condition = analyze(condition, :runtime, mutators)

    if Conditions.hoist_if?(analyzed_condition, mutators) do
      Conditions.hoist_if(form, meta, condition, analyzed_condition, analyzed_body, mutators)
    else
      analyzed_condition = Conditions.finish_condition(analyzed_condition, condition, mutators)
      rebuilt = {form, meta, [analyzed_condition, analyzed_body]}
      Attach.offer(rebuilt, node, mutators)
    end
  end

  # `case`: a runtime expression whose *clause patterns/guards* are mutatable by the
  # structural families (`PatternSwap`/`PatternWildcard`), the literal families, and the
  # guard families. A `case` *has* a scrutinee, so the mutants are delivered per-clause by
  # the **tuple-the-scrutinee** rewrite (the C+M analogue of head lifting — see
  # `Mutare.Transform.CaseClauseEmit.emit/3`): the whole `case` becomes `case {<active>,
  # <subject>} do …` and each mutant adds one gated clause. The construct is still analyzed
  # normally (subject/bodies mutate; `->` keeps patterns `:pattern`; guards stay pruned),
  # and the per-clause `Candidate.CaseClause`s are attached under the `:mutare_case` meta key
  # (separate from `:mutare`, since they need the dedicated emit). The whole-`case`-node
  # parity offer is dropped — no built-in matches a `case`, and a custom whole-`case` mutator
  # can't be combined with the per-clause tupling (a documented, built-in-irrelevant gap).
  #
  # The keyword form (`case x, do: (p -> b; …)`) wraps the clause list in an extra
  # `:__block__` (`Syntax.normalize_clause_blocks/1`'s shape); unwrap and re-dispatch so
  # it gets the same per-clause candidates as its block-form twin (rendering flips to
  # block form at the final render, where block keys become plain atoms).
  defp analyze_form(
         {:case, meta,
          [subject, [{do_key, {:__block__, _bmeta, [[{:->, _, _} | _] = clauses]}}]]},
         :runtime,
         mutators
       ),
       do: analyze({:case, meta, [subject, [{do_key, clauses}]]}, :runtime, mutators)

  defp analyze_form({:case, _meta, [_subject, [{_do_key, clauses}]]} = node, :runtime, mutators)
       when is_list(clauses) do
    analyzed = recurse(node, :runtime, mutators)

    case ClausePatterns.case_clause_candidates(clauses, mutators) do
      [] -> analyzed
      candidates -> ClausePatterns.put_case_candidates(analyzed, candidates)
    end
  end

  # `receive` retains its native mailbox scan and after block; ReceiveClause candidates
  # interleave guarded variants before each original message clause during emission.
  # Normalize keyword blocks for traversal while preserving the whole-node custom offer.
  defp analyze_form({:receive, meta, [blocks]} = node, :runtime, mutators) when is_list(blocks) do
    normalized_blocks = Syntax.normalize_clause_blocks(blocks)
    normalized_node = {:receive, meta, [normalized_blocks]}

    ClausePatterns.attach_receive_candidates(
      normalized_node,
      node,
      mutators
    )
  end

  # A `fn` additionally has its clause bodies' return tails mutated: each clause
  # returns the value of its body when the closure is called, so every clause-body
  # leaf tail is a return path (`Returns.annotate_fn_returns/3`, run on the analyzed
  # node with the raw `node` supplying the clean diff). The return candidates ride on
  # the tail nodes inside the clause bodies; the clause-pattern candidates ride on the
  # `fn` node's own meta — different nodes, so they nest cleanly at emit.
  # FnClause candidates store one raw mutant clause each; FnClauseEmit preserves arity,
  # captures the selector and records all head/guard ids at creation, before any invocation.
  defp analyze_form({:fn, _meta, clauses} = node, :runtime, mutators) when is_list(clauses) do
    attached = ClausePatterns.attach_fn_candidates(node, mutators)
    Returns.annotate_fn_returns(attached, node, mutators)
  end

  # `try`: a runtime expression whose `rescue` clauses are special — they match on
  # *exception types* (`var in [A, B]` / `var` / `Type`), carry **no `when` guard**, and so
  # can't be dispatched per-clause the way `case` is. `Mutare.Mutators.RescueType` mutates them
  # two ways, both represented as whole-try replacements (RescueEmit factors eligible
  # bound-handler shapes; other shapes retain a whole-construct selector): it narrows a
  # `var in [A, B]` list by dropping one type (`Candidate.CasePattern`), and — for the idiomatic
  # multi-branch shape where each clause catches a single type and there is no list to narrow —
  # it drops a whole `rescue` clause (`Candidate.RescueDrop`, only when ≥2 clauses are present so
  # the `rescue` is never left empty). The construct is still analyzed normally (do/rescue-bodies/
  # catch/else/after mutate; the rescue/else/catch patterns stay `:pattern`). This clause handles the
  # explicit `try`; the `def … rescue …` shorthand carries the same blocks at the def-body level and
  # is hosted in a synthesized `try` by `host_def_rescue/3` (off the same `rescue_type_candidates/3`).
  # The blocks are first `Syntax.normalize_clause_blocks/1`-ed so the keyword form
  # (`try(do: …, rescue: (p -> b))`) reads like its block-form twin — otherwise
  # `rescue_type_candidates/3`'s list guard misses the wrapped clause list and the
  # narrowing/clause-drop mutants are silently skipped.
  defp analyze_form({:try, meta, [blocks]} = node, :runtime, mutators) when is_list(blocks) do
    normalized_blocks = Syntax.normalize_clause_blocks(blocks)
    analyzed = recurse({:try, meta, [normalized_blocks]}, :runtime, mutators)

    # `catch`/`else` clause guards get their guard-only mutants (`ClauseGuardEmit`) —
    # `rescue` clauses carry no guard.
    candidates =
      Attach.build_candidates(node, Dispatch.mutations(node, mutators)) ++
        ClausePatterns.rescue_type_candidates(normalized_blocks, meta, mutators) ++
        ClausePatterns.guard_only_candidates(
          ClausePatterns.located_block(normalized_blocks, :catch) ++
            ClausePatterns.located_block(normalized_blocks, :else),
          mutators
        )

    Attach.put_candidates_if_any(analyzed, candidates)
  end

  # A `->` clause in a pattern-matching construct (`case`/`fn`/`receive`/`with` else/
  # a `try` block outside a def head/`for` reduce): the left is a pattern (never
  # mutated — a selector `case` is illegal in a pattern and would poison the single
  # build), the body inherits the construct's liveness (`body_context/1`): `:runtime`
  # normally, `:scaffold` when this construct itself wraps a metaprogrammed `def` at
  # module level (so the arm's own code is left compile-time-inert). `cond` is
  # excepted above; a `when` guard among the patterns is returned whole by the
  # `:when` clause, so guards stay untouched.
  defp analyze_form({:->, meta, [patterns, body]}, context, mutators) when is_list(patterns) do
    {:->, meta,
     [
       Enum.map(patterns, &analyze(&1, :pattern, mutators)),
       analyze(body, body_context(context), mutators)
     ]}
  end

  # default argument inside a pattern (`x \\ expr`): the variable is a pattern,
  # but the default runs at call time → runtime (don't regress its mutation).
  defp analyze_form({:\\, meta, [var, default]}, :pattern, mutators) do
    {:\\, meta, [analyze(var, :pattern, mutators), analyze(default, :runtime, mutators)]}
  end

  # `|>` pipe: the right side is a call whose *effective* first argument is the piped
  # left side — which is the `|>` node's LHS, **not** present in the call's own args.
  # So a pipe stage carries one fewer argument than the source reads, which makes a
  # node-local mutator misjudge its arity. Route the RHS through `analyze_pipe_stage/2`
  # so an arity-changing mutator (`CollectionArity`) is offered the node *as piped*
  # and sees the true arity. (Arity-blind mutators are unaffected — they ignore the flag.)
  #
  # The LHS is *usually* an ordinary runtime expression, but when the RHS is a **known
  # macro** the piped value is that macro's effective argument 0, so it inherits position
  # 0's treatment (`analyze_piped_value/3` — the "reach back"): a `1 |> match?(1)` pipes
  # its LHS into match?'s **pattern** position, and a `:raw` macro may accept a LHS that
  # is neither a valid expression nor a valid pattern. Treating it as runtime would splice
  # a selector `case` into pattern/opaque position and poison the build.
  defp analyze_form({:|>, meta, [lhs, rhs]}, :runtime, mutators) do
    {:|>, meta,
     [
       Routed.analyze_piped_value(lhs, rhs, mutators),
       analyze_pipe_stage(rhs, mutators)
     ]}
  end

  # `for` comprehension: its generators (`<-`), filters, `:into`/`:reduce` options
  # and `:do`/`:reduce` body all descend as ordinary runtime, but the **`:uniq`**
  # option must be a *literal boolean* — the `for` special form rejects any
  # non-literal there (`:uniq option for comprehensions only accepts a boolean`),
  # so a selector `case` spliced into its value (Literal/Conditional firing on the
  # `true`/`false`) would poison the single build. The `:uniq` value alone is held
  # back from mutators (`analyze_for_arg/2`); the node itself is still offered for
  # parity with the generic clause (no built-in matches `for`).
  #
  # A guarded generator (`x when x > 0 <- xs`) and a guarded `reduce:` `do` clause get their
  # guard-only mutants (`ClauseGuardEmit`); the patterns themselves stay `:pattern`.
  defp analyze_form({:for, _meta, args} = node, :runtime, mutators) when is_list(args) do
    {:for, meta, args} = Attach.offer(node, node, mutators)
    {qualifiers, trailing} = Enum.split(args, -1)

    guards =
      ClausePatterns.guard_only_candidates(
        ClausePatterns.located_clauses(qualifiers) ++
          Enum.flat_map(trailing, &ClausePatterns.located_block(&1, :do)),
        mutators
      )

    {:for, meta, Enum.map(args, &analyze_for_arg(&1, mutators))}
    |> Meta.append_candidates(:in_place, guards)
  end

  # `with`: a chain of clauses (`<-`/`=`/bare-expr, every one value-discarded) followed by
  # the trailing `[do: …, else: …]` keyword. A bare `=` clause is a match used solely for
  # its bindings — which escape to later clauses and the `do` body — exactly the rewriteable
  # position, so each clause routes through `analyze_statement/2` (a `=` gets a
  # `Candidate.MatchPattern`; a `<-` keeps its LHS a `:pattern`; a bare expr is ordinary
  # runtime). The keyword tail is `Syntax.normalize_clause_blocks/1`-ed (so a keyword-form
  # `else: (p -> b)` reads like its block-form twin) and descends as usual (the `do` body's
  # own non-final `=` statements are reached there too; `else` patterns stay `:pattern` via
  # the generic `->` clause). A `<-` non-match routes to `else`, but a `=` non-match raises `MatchError`
  # (which `else` never catches) — preserved by the rewrite's trailing raise clause. (A
  # malformed `with` with no keyword tail falls back to the generic runtime descent.)
  defp analyze_form({:with, meta, args} = node, :runtime, mutators)
       when is_list(args) and args != [] do
    if is_list(List.last(args)) do
      {raw_clauses, [body_kw]} = Enum.split(args, -1)
      clauses = Enum.map(raw_clauses, &MatchPatterns.analyze_statement(&1, mutators))
      body_kw = Syntax.normalize_clause_blocks(body_kw)
      rebuilt = {:with, meta, clauses ++ [analyze(body_kw, :runtime, mutators)]}

      # Guard-only mutants of the `<-` clauses and the `else` clauses (`ClauseGuardEmit`);
      # their patterns stay `:pattern`.
      guards =
        ClausePatterns.guard_only_candidates(
          ClausePatterns.located_clauses(raw_clauses) ++
            ClausePatterns.located_block(body_kw, :else),
          mutators
        )

      rebuilt |> Attach.offer(node, mutators) |> Meta.append_candidates(:in_place, guards)
    else
      node |> Attach.offer(node, mutators) |> recurse_runtime(mutators)
    end
  end

  # === redundancy suppression: equivalent sibling mutants ====================
  #
  # Four shapes where one family's mutant is *guaranteed equivalent* to another's, so
  # the redundant one is dropped. The shared move (clauses 1–4) is the same as `not in`
  # always did: descend operands (so their literals still mutate) but do **not** *offer*
  # the inner/redundant node — only the outer. (Clause 4, the short-circuit connective,
  # instead *offers* the node and drops a single one of its mutations.) Dropping a candidate
  # here (rather than post-hoc) leaves no id/site/selector, exactly like the other positive
  # suppressions.
  #
  # (1) **Double negation** `not not x` / `!!x` — the **same** operator twice. Logical
  # strips the outer *and* the inner to the identical single-negation (`not x` / `!x`),
  # and Conditional on the inner (`not true`/`not false`) duplicates the outer's
  # `true`/`false`. Same operator only: a mixed `not !x` could differ on a non-boolean
  # operand (`not x` raises where `!x` coerces to `false`), so it is left fully offered.
  defp analyze_form(
         {neg, meta, [{neg, inner_meta, [operand]} = raw_inner]} = node,
         :runtime,
         mutators
       )
       when is_negation_op(neg) do
    # A skipped inner node is a leaf with no mutants to be redundant with: the generic path.
    if Meta.skipped?(raw_inner) do
      do_analyze_call_node(node, mutators, %{pipe_mode: :unpiped})
    else
      inner = {neg, inner_meta, [analyze(operand, :runtime, mutators)]}
      Attach.offer({neg, meta, [inner]}, node, mutators)
    end
  end

  # (2) **`not`/`!` over `in`** (`x not in y` parses as `not(x in y)`). The inner `in`'s
  # only Relational mutation (`in` → `not in`) re-negates to `x in y` ≡ Logical's strip
  # of the outer; Conditional on the inner (`not true`/`not false`) ≡ the outer's
  # `true`/`false`. So the inner `in` is not offered (only its operands descend), and its
  # outer's Conditional. Its operands still mutate normally: an empty RHS mutant is not
  # equivalent in a body because it evaluates the left operand while the outer constant
  # skips it. The outer `not`/`!` is offered normally.
  defp analyze_form(
         {neg, meta, [{:in, in_meta, [left, right]} = raw_inner]} = node,
         :runtime,
         mutators
       )
       when is_negation_op(neg) do
    if Meta.skipped?(raw_inner) do
      do_analyze_call_node(node, mutators, %{pipe_mode: :unpiped})
    else
      inner =
        {:in, in_meta, [analyze(left, :runtime, mutators), analyze(right, :runtime, mutators)]}

      Attach.offer({neg, meta, [inner]}, node, mutators)
    end
  end

  # (3) **`not`/`!` over an equality operator** (`==`/`!=`/`===`/`!==`) — case (2)
  # generalised: each equality operator is its own exact polarity complement, so
  # Relational's flip under the negation ≡ Logical's strip, and Conditional on the inner
  # ≡ the outer's `true`/`false`. **Only** the ordering operators (`<`/`>`/`<=`/`>=`) are
  # left untouched by *this* clause — they mutate to a boundary/reversal that survives
  # negation as a genuinely new mutant (`!(a >= b)` ≡ `a < b`, ≠ the strip `a > b`), so
  # they fall through to the generic clause and are offered.
  #
  # Unlike case (2), the inner equality node *is* offered — but with only its
  # negation-redundant mutations dropped (`drop_negation_redundant_candidates/2`): the
  # polarity complement (Relational, ≡ Logical's strip) and the `true`/`false` constants
  # (Conditional, ≡ the outer's). A *strictness relaxation* (`===` → `==`,
  # `Mutare.Mutators.StrictEquality`) is **not** the polarity complement, so `not (a == b)`
  # ≢ `a === b` survives negation as a genuinely new mutant and is kept. The operands still
  # descend either way.
  defp analyze_form({neg, meta, [{op, op_meta, [left, right]}]} = node, :runtime, mutators)
       when is_negation_op(neg) and is_equality_op(op) do
    inner_raw = {op, op_meta, [left, right]}

    if Meta.skipped?(inner_raw) do
      do_analyze_call_node(node, mutators, %{pipe_mode: :unpiped})
    else
      # The inner node takes the ordinary call path — offered, its operands by their stamped
      # positions when it carries a route (`{Kernel, :==, 2, :interior}` holds under `not` as it
      # does bare); this clause adds only the negation-redundancy drop on top.
      inner =
        inner_raw
        |> do_analyze_call_node(mutators, %{pipe_mode: :unpiped})
        |> drop_negation_redundant_candidates(op)

      Attach.offer({neg, meta, [inner]}, node, mutators)
    end
  end

  # (4) **A short-circuit connective whose left operand is itself a boolean op**
  # (`and`/`&&`/`or`/`||`). Conditional forces this connective node to `true`/`false`, but one
  # of those constants is identical to Conditional forcing the *left* operand: on `and`/`&&`,
  # `(L and R) → false` ≡ `L → false` (the false left short-circuits the whole node to false,
  # R unreached); on `or`/`||`, `(L or R) → true` ≡ `L → true`. Both produce the same program,
  # so the connective-node constant is the redundant one — dropped, leaving the operand's more
  # precise `L → false`/`L → true` diff. The drop is conditioned on the left being a
  # Conditional-eligible boolean op, since that is exactly when the subsuming sibling is
  # generated (`valid?(x) and y` has no `valid?(x) → false`, so its `→ false` is genuine and
  # kept — R's effects there would survive a left-operand force but not the node force). The
  # *other* constant survives (`(L and R) → true` still evaluates R — distinct), as do Logical's
  # `and`↔`or` and both operands. `&&`/`||` are body-only (guard-illegal), so the guard twin in
  # `Mutare.Transform.Tag` handles only `and`/`or`. See NOTES "Equivalent-sibling suppression".
  defp analyze_form({op, _meta, [left, _right]} = node, :runtime, mutators)
       when is_body_connective(op) do
    analyzed = node |> Attach.offer(node, mutators) |> recurse_runtime(mutators)

    # (A skipped left operand has no `L → false`/`L → true` of its own to defer to.)
    if Suppression.boolean_op_node?(left) and not Meta.skipped?(left),
      do: drop_constant_candidate(analyzed, Suppression.redundant_constant(op)),
      else: analyzed
  end

  # An interpolated quoted atom: `:"a#{x}b"` parses as `:erlang.binary_to_atom(<<segments>>,
  # encoding)` with the parser's `:delimiter` stamped on the *call* meta (`NodeRange.get/1`
  # keys on the same shape). Offer the whole node — `AtomLiteral` swaps it for the sentinel —
  # then descend the content segments surgically, exactly like a sigil's: the inner `<<>>` is
  # atom content, not a user-written bitstring, so its wrapper is never offered
  # (BitstringLiteral collapsing it would mint a mutant misattributed to `:bitstring` with a
  # corrupt diff) and the construction `::binary` pin doesn't apply (string content, not a
  # construction). The `:delimiter` gate is the usual authenticity guard: a hand-written
  # `:erlang.binary_to_atom(bin, :utf8)` call carries none and stays an ordinary call node.
  # (No charlist twin here: a legacy `'a#{x}b'` wraps its segments in a plain *list*, which
  # the walk never offers, so the generic clause below already handles it correctly.)
  defp analyze_form(
         {{:., _, [:erlang, :binary_to_atom]} = dot, meta, [{:<<>>, bmeta, segments}, encoding]} =
           node,
         :runtime,
         mutators
       )
       when is_list(segments) do
    if Keyword.has_key?(meta, :delimiter) do
      content = {:<<>>, bmeta, Enum.map(segments, &analyze_segment(&1, :runtime, mutators))}
      Attach.offer({dot, meta, [content, encoding]}, node, mutators)
    else
      do_analyze_call_node(node, mutators, %{pipe_mode: :unpiped})
    end
  end

  # A **stab-clause block** — `{:__block__, _, [[-> …]]}`, the parse of parenthesized arrow
  # clauses. Only arrow clauses produce this shape (`[a -> b]` is a syntax error, so a genuine
  # list literal never contains a `->`), yet it is byte-identical to a list literal's, so the
  # generic clause below would *offer* it — letting `List` collapse required `->` clauses to
  # `[]` — and splice a selector where only clauses are legal: poison twice over. It surfaces
  # wherever arrow clauses sit in a position with no dedicated construct clause: a keyword-form
  # tail (`with …, else: (_ -> …)`, an unrouted macro's `do:`), a `for` `reduce:` `do:` body,
  # a bare macro argument. (`case`/`cond`/`receive`/`try`/`def rescue` never reach here — their
  # clauses `Syntax.normalize_clause_blocks/1` the wrapper away first.) Descend clause-wise —
  # the `->` clause keeps each LHS a `:pattern`, the safe default for an unknown host — and
  # never offer the wrapper.
  defp analyze_form({:__block__, meta, [[{:->, _, _} | _] = clauses]}, :runtime, mutators),
    do: {:__block__, meta, [Enum.map(clauses, &analyze(&1, :runtime, mutators))]}

  # A generic runtime node: offer it and descend, or route a known-macro call's arguments
  # by treatment — see `do_analyze_call_node/3`. (A sigil is offered whole then descended
  # *surgically* via `descend_sigil/2`, so an interpolated `~r/a#{b}c/` still mutates `b`
  # while its content `<<>>` wrapper is never offered; that gate lives in the helper.)
  defp analyze_form({_form, _meta, _args} = node, :runtime, mutators),
    do: do_analyze_call_node(node, mutators, %{pipe_mode: :unpiped})

  # A keyword/map/block pair (`key: value`, `%{a: …}`, a `do:`/`else:`/`rescue:`/
  # `catch:`/`after:` block). Only a **block key** is a pure structural label that
  # must never be offered: a selector spliced into a `do:`/`else:`/… key is malformed
  # and would not even render. A *data* key — `a:` in a map or keyword list, an
  # option like `timeout:` in a call's trailing keywords — is a real runtime value:
  # mutating it changes which entry the map/list carries, exactly like the arrow form
  # `%{:a => …}` (which has always mutated). So a non-block pair descends both sides
  # through `recurse` and the key stays mutatable; the keyword-shorthand `format:
  # :keyword` marker on the original key is harmless — Sourceror renders the spliced
  # selector as an arrow (`%{(sel) => v}`) or a tuple (`[{(sel), v}]`) automatically.
  # Compile-time-constrained data keys (struct fields, `for` options) are kept raw by
  # their own clauses, before reaching here. (A value holding a keyword-form clause tail —
  # `with …, else: (_ -> fallback)` — descends into the stab-clause-block clause above,
  # which keeps the wrapper raw; no special casing is needed here.)
  defp analyze_form({key, value} = pair, context, mutators) do
    if Syntax.block_key?(key),
      do: {key, analyze(value, context, mutators)},
      else: recurse(pair, context, mutators)
  end

  # anything else — a node in a non-runtime context, or a container/leaf:
  # descend without mutating so boundary forms (`\\`, `<<>>`) still fire on
  # children, but attach no candidate here.
  defp analyze_form(node, context, mutators), do: recurse(node, context, mutators)

  # Drop from the **top node** the Conditional candidate forcing it to `bool` — the redundant
  # short-circuit constant. Per mutation (the sibling constant and Logical's swap stay) and
  # top-node scoped (via `Candidate.update_candidates/2`, a no-op when the node carries no
  # candidates).
  defp drop_constant_candidate(node, bool),
    do: reject_candidates(node, &constant_candidate?(&1, bool))

  defp constant_candidate?(%Candidate.InPlace{mutated: mutated}, bool),
    do: Suppression.boolean_literal?(mutated, bool)

  defp constant_candidate?(_candidate, _bool), do: false

  # Drop from an equality node *under a negation* its negation-redundant candidates: the
  # polarity complement (Relational's flip, ≡ Logical's strip of the outer `not`) and the
  # `true`/`false` constants (Conditional, ≡ the outer's). A strictness relaxation
  # (`===` → `==`) is neither, so it survives — `not (a == b)` ≢ `a === b`. Per mutation and
  # top-node scoped (via `Candidate.update_candidates/2`, a no-op when the node carries no
  # candidates).
  defp drop_negation_redundant_candidates(node, op),
    do: reject_candidates(node, &negation_redundant?(&1, op))

  defp negation_redundant?(%Candidate.InPlace{mutated: mutated}, op),
    do: Suppression.negation_redundant?(mutated, op)

  defp negation_redundant?(_candidate, _op), do: false

  # Reject from a node's candidate list every candidate matching `predicate` (a no-op
  # when the node carries no candidates). The shared body of the three top-node
  # equivalent-sibling drops above.
  defp reject_candidates(node, predicate) do
    Candidate.update_candidates(node, fn cands -> Enum.reject(cands, predicate) end)
  end

  # The right side of a `|>` (see the `:|>` clause of `analyze/3`): offer it to
  # mutators *as piped* (so an arity-changing mutator sees the effective arity =
  # visible args + 1), then descend its arguments as ordinary runtime. Mirrors the
  # generic runtime clause (a pipe stage is never a sigil). The resulting candidate
  # is a normal `Candidate.InPlace`, so emission wraps it in a selector and
  # `PipeEmit.hoist/2` lifts the selector out of the illegal pipe-RHS position into a
  # one-shot closure on the piped value — `lhs |> (fn v -> case … (each branch pipes
  # `v`) … end).()`. A non-call RHS (rare) is analyzed normally.
  #
  # A piped **known-macro** stage (`q |> where([p], p.x == 1)`, the query-builder shape)
  # routes its arguments by treatment too — `Resolve` already stamped the *visible*-position
  # routing (the piped value dropped), so a `:raw` DSL body is left raw instead of mutated.
  defp analyze_pipe_stage({_form, _meta, args} = node, mutators) when is_list(args),
    do: do_analyze_call_node(node, mutators, %{pipe_mode: :piped})

  defp analyze_pipe_stage(other, mutators), do: analyze(other, :runtime, mutators)

  # The shared call-node dispatch behind the generic runtime `analyze/3` clause and
  # `analyze_pipe_stage/2`: a call stamped a **known macro** (`meta[:mutare_route]`, set by
  # `Mutare.Transform.Resolve` from `Mutare.CallRouting.Registry`) routes its arguments by their declared
  # treatment (`Routed.analyze_routed_call` — so a pattern arg isn't mutated in place and an
  # opaque DSL body is left raw) while the whole node is still offered to mutators; every other
  # node is offered and its children descended. `context` carries `:pipe_mode` (`:piped` for a
  # `|>` RHS, so an arity-changing mutator sees the effective arity) — which also gates the
  # sigil-content path: a `|>` RHS (`:piped`) is never sigil syntax, so only the generic-runtime
  # (`:unpiped`) path descends sigil content.
  defp do_analyze_call_node({form, meta, _args} = node, mutators, context) do
    case Meta.routing(meta) do
      # The call-level `:skip`: an **inert leaf** — no whole-node offer, nothing inside the
      # parentheses descended. (A piped receiver is the `|>`'s other operand, analyzed by the
      # pipe clause before this node is reached, so `Repo.insert!(u) |> Skipped.call()` keeps
      # the receiver's mutants. A tail-position skipped call still gets its return-value
      # replacements — those belong to the enclosing function, attached by `Returns`.) Reached
      # only from `analyze_pipe_stage/2`, a `|>` RHS — an unpiped node is intercepted by
      # `analyze/3`'s dispatcher before any clause.
      :skip ->
        node

      nil ->
        node = Attach.offer(node, node, mutators, context)

        # `sigil?(form)` (the `sigil_<x>` head) is necessary but **not sufficient**: a call to a
        # *function* named `sigil_s`/`sigil_r`/… (a local sigil shadowing `Kernel`'s) parses to the
        # same head. Routing such a call through `descend_sigil/2` would treat a real `<<…>>`
        # *argument* of it (`sigil_r(<<"x">>, [])`) as sigil **content** and descend it without the
        # `::binary` construction pin, breaking the baseline (the same hazard
        # `binary_valued_literal?/1` guards). Only genuine sigil syntax carries the parser's
        # `:delimiter` meta, so gate on it; a non-sigil call falls through to `recurse_runtime`,
        # which analyses its args — including a real bitstring arg — correctly.
        if context.pipe_mode == :unpiped and sigil?(form) and Keyword.has_key?(meta, :delimiter),
          do: descend_sigil(node, mutators),
          else: node |> recurse_runtime(mutators) |> descend_receiver(mutators)

      routing ->
        Routed.analyze_routed_call(node, routing, mutators, context)
    end
  end

  # A dot-call's **receiver**. `recurse_runtime/2` descends only the call's *arguments*, leaving the
  # whole `{:., _, [recv, fun]}` head raw — which is correct for the **module side** of a remote call
  # (`Enum.filter(...)`, `:lists.sort(...)`): a module reference is opaque, never mutated. But when the
  # receiver is *not* a module reference it is an ordinary **runtime sub-expression** — a chained call
  # (`get_config().fetch(k)`, `Repo.get(...).name`) or a result dispatch — and must be analyzed like
  # any other value, or the call families silently never fire on it. Split on exactly that: analyze a
  # non-module receiver as `:runtime`, leave a module reference (and the `fun` name atom) raw. Mirrors
  # the `Mutare.Transform.Resolve` clause-#4 split that stamps the same receiver.
  defp descend_receiver({{:., dm, [recv, fun]}, meta, args}, mutators) do
    if module_reference?(recv),
      do: {{:., dm, [recv, fun]}, meta, args},
      else: {{:., dm, [analyze(recv, :runtime, mutators), fun]}, meta, args}
  end

  # An **anonymous call** `callee.(args)` — `f.(x)`, `m.field.(x)`, and the immediately-invoked
  # `(fn … end).(x)` — has a one-element dot head with no function name. Its callee is never a module
  # reference, always a runtime value, so it is analyzed like any non-module receiver. Without this an
  # inline `fn` was invisible to every family (its guards, patterns *and* bodies) while the same `fn`
  # bound to a variable first mutated fully — the analysis happening at the binding site, not the call.
  defp descend_receiver({{:., dm, [callee]}, meta, args}, mutators),
    do: {{:., dm, [analyze(callee, :runtime, mutators)]}, meta, args}

  defp descend_receiver(node, _mutators), do: node

  # Whether a dot-call receiver is a **module reference** (opaque — the module side of a remote call)
  # rather than a runtime expression: an Elixir alias path (`Enum`, kept opaque even when dynamic so a
  # `Foo.unquote(x).bar` receiver is never split), a Sourceror-wrapped atom module (`:lists`), or a
  # bare atom (the only way a bare atom appears in receiver position is as a module).
  defp module_reference?({:__aliases__, _meta, _path}), do: true
  defp module_reference?({:__block__, _meta, [atom]}) when is_atom(atom), do: true
  defp module_reference?(atom) when is_atom(atom), do: true
  defp module_reference?(_other), do: false

  # === known macros ==========================================================

  # The known-macro argument *routing* lives in `Mutare.Transform.Analyze.Routed`:
  # `Routed.analyze_routed_call/4` (a written/piped stage) and `Routed.analyze_piped_value/3`
  # (the `|>` LHS reaching back into a macro's argument-0 treatment) route each argument by its
  # declared treatment — a pattern, an opaque `:raw` DSL body, a `:hosted` fragment — driving the
  # descent back through `annotate/2`/`pattern/2`/`offer/4`. The core walk reads the stamp via
  # `Mutare.Transform.Meta.routing/1` and dispatches there.

  # One argument of a `for`: a generator/filter/match is descended as a *statement*
  # (its value is discarded — a qualifier only binds/filters), while the trailing
  # options/body keyword list keeps every option *key* raw — `:into`/`:reduce`/`:uniq`/
  # `:do` are `for`-special-form keywords, so mutating a key is a compile error
  # (`unsupported option :mutare given to for`), unlike a free-form map/keyword key. The
  # `:uniq` *value* must also be a literal boolean (a selector there would poison the
  # build), so it is held back; every other value (`:into`/`:reduce` and the `:do`/
  # `:reduce` body) descends as ordinary runtime.
  #
  # (A `reduce:` comprehension's `do:` body is a *stab-clause* block — `acc -> expr`
  # clauses the `for` special form demands stay literal ("the do block must be written
  # using acc -> expr clauses"). It needs no handling here: the stab-clause-block clause
  # of the main descent descends it clause-wise with the wrapper left raw.)
  defp analyze_for_arg(opts, mutators) when is_list(opts) do
    Enum.map(opts, fn
      {key, value} ->
        if AST.key_atom(key) == :uniq,
          do: {key, value},
          else: {key, analyze(value, :runtime, mutators)}

      other ->
        analyze(other, :runtime, mutators)
    end)
  end

  # A **bitstring generator** `<<seg, …, last <- enum>>`: the `<-` rides the *last* segment,
  # the segments before it are plain pattern segments. The wrapper is `for`-special-form
  # syntax, not a bitstring value — offering it would let `BitstringLiteral` swap the whole
  # generator for `<<>>`, and the selector `case` spliced into generator position poisons the
  # build (`misplaced operator ::/2`). So: leading segments as `:pattern`, the `<-` through the
  # ordinary generator clause (its LHS a pattern, its RHS runtime), the wrapper never offered.
  defp analyze_for_arg({:<<>>, meta, segments}, mutators) when is_list(segments) do
    case List.pop_at(segments, -1) do
      {{:<-, _gmeta, [_lhs, _rhs]} = generator, leading} ->
        {:<<>>, meta,
         Enum.map(leading, &analyze(&1, :pattern, mutators)) ++
           [analyze(generator, :runtime, mutators)]}

      _ ->
        MatchPatterns.analyze_match_statement({:<<>>, meta, segments}, mutators)
    end
  end

  # A non-keyword qualifier — a generator (`<-`), a filter, or a **bare `=` match**.
  # `analyze_match_statement/2` offers a `=` LHS to the structural pattern families (a `for`
  # `=` qualifier discards its value, so the tuple-export rewrite is sound) and leaves
  # generators/filters as ordinary runtime. (Unlike a block statement / `with` clause, a
  # *bare macro call* qualifier is a filter, not value-discarded, so it stays unrewritten.)
  defp analyze_for_arg(arg, mutators),
    do: MatchPatterns.analyze_match_statement(arg, mutators)

  # One entry of a struct's field map: keep the key (a compile-time field name) raw and
  # descend only the value. A struct update (`%S{base | a: 1}`) carries a `:|` node
  # whose right side is the field list — descend the base normally, recurse the fields.
  defp analyze_struct_field({:|, meta, [base, fields]}, context, mutators) when is_list(fields) do
    base = analyze(base, context, mutators)
    fields = Enum.map(fields, &analyze_struct_field(&1, context, mutators))
    {:|, meta, [base, fields]}
  end

  defp analyze_struct_field({key, value}, context, mutators),
    do: {key, analyze(value, context, mutators)}

  defp analyze_struct_field(other, context, mutators),
    do: analyze(other, context, mutators)

  # Recurse a runtime call's arguments as ordinary runtime data, then tag its call-option
  # keys. A call-rewriting mutator (ModeSwap) and a leaf mutator (AtomLiteral) may both fire
  # on the same atom/key, but the redundant leaf mutant is dropped *after* analysis by the
  # diff-derived `Mutare.Transform.Overlap` pass (it sees the call rewrite already covers that
  # node) — so the analyzer no longer needs to know which positions are "owned".
  defp recurse_runtime({_form, _meta, args} = node, mutators) when is_list(args) do
    node |> recurse(:runtime, mutators) |> CallOptions.mark()
  end

  defp recurse_runtime(node, mutators), do: recurse(node, :runtime, mutators)

  # Generic structural descent over every Sourceror node shape, re-analyzing the
  # children in the same context. Public as part of the small sub-walk API the
  # split-out clause-pattern builder (`Mutare.Transform.Analyze.ClausePatterns`)
  # uses to analyze a `receive`/`fn` node normally before attaching its candidates.
  def recurse({form, meta, args}, context, mutators) when is_list(args),
    do: {form, meta, Enum.map(args, &analyze(&1, context, mutators))}

  def recurse({form, meta, arg}, _context, _mutators), do: {form, meta, arg}

  def recurse({left, right}, context, mutators),
    do: {analyze(left, context, mutators), analyze(right, context, mutators)}

  def recurse(list, context, mutators) when is_list(list),
    do: Enum.map(list, &analyze(&1, context, mutators))

  def recurse(other, _context, _mutators), do: other

  # One argument of a `defimpl`: a keyword list holding the `do:` block (its body is
  # runtime — analyze it) alongside compile-time entries like `for:` (pass raw). The
  # leading protocol-alias argument is not a list, so it passes through untouched.
  defp analyze_defimpl_arg(kw, mutators) when is_list(kw) do
    Enum.map(kw, fn
      {key, value} = pair ->
        if Syntax.do_key?(key), do: {key, analyze(value, :runtime, mutators)}, else: pair

      other ->
        other
    end)
  end

  defp analyze_defimpl_arg(other, _mutators), do: other

  # A bitstring segment `<<value::spec>>`: the value keeps the surrounding
  # context; the spec side is excluded except for `size(expr)` args.
  defp analyze_segment({:"::", meta, [value, spec]}, context, mutators) do
    {:"::", meta, [analyze(value, context, mutators), analyze_spec(spec, context, mutators)]}
  end

  defp analyze_segment(segment, context, mutators), do: analyze(segment, context, mutators)

  # A segment of a runtime bitstring *construction*. A binary-valued literal — a string,
  # an interpolated string, or a `~s`/`~S` sigil — written *untyped* defaults to a `binary`
  # segment only because the value is a literal; the moment a mutation wraps it in a selector
  # `case` the segment reverts to the integer default and construction raises at runtime (the
  # baseline included — `<<"x">>` becomes `<<(case … end)>>`, "expected an integer"). Pin
  # `::binary` explicitly so the selector — and the mutated binaries it yields — construct
  # correctly. Semantically a no-op (`<<"x">>` ≡ `<<"x"::binary>>`); the report still diffs the
  # bare value (it patches the original source, not the metamutant). An already-typed
  # (`::utf8`/`::binary`/…) segment, or a non-binary one (an integer/char/`size(expr)`), is
  # analyzed unchanged.
  defp analyze_construction_segment({:"::", _meta, _args} = typed, mutators),
    do: analyze_segment(typed, :runtime, mutators)

  defp analyze_construction_segment(segment, mutators) do
    analyzed = analyze_segment(segment, :runtime, mutators)

    if binary_valued_literal?(segment),
      do: {:"::", [], [analyzed, {:binary, [], nil}]},
      else: analyzed
  end

  # A bitstring segment value whose runtime type is a binary, recognised syntactically: a
  # string literal (`{:__block__, _, [binary]}`), an interpolated string / heredoc (a
  # `delimiter`-marked `<<>>`), or a `~s`/`~S` sigil *literal*. These are exactly the untyped
  # segments a selector would mis-type as an integer (see `analyze_construction_segment/2`).
  #
  # The sigil clause keys on the parser's `:delimiter` meta, **not the head atom alone**: a call
  # to a *function* named `sigil_s`/`sigil_S` (e.g. `<<sigil_s("a", [])>>` — a local sigil that
  # shadowed `Kernel`'s) parses to the same `{:sigil_s, …}` head but carries no `:delimiter` and
  # may return an integer, so pinning `::binary` there would break the baseline (the call would
  # have to yield a binary). Only genuine sigil syntax — like the interpolated-string `<<>>`
  # above — gets the parser's `:delimiter` stamp.
  defp binary_valued_literal?({:__block__, _meta, [value]}), do: is_binary(value)
  defp binary_valued_literal?({:<<>>, meta, _segs}), do: Keyword.has_key?(meta, :delimiter)

  defp binary_valued_literal?({sigil, meta, _args}) when sigil in [:sigil_s, :sigil_S],
    do: Keyword.has_key?(meta, :delimiter)

  defp binary_valued_literal?(_), do: false

  # The type-specifier side of a bitstring segment. Separators (`-`), type atoms
  # and `unit(...)` stay raw — a swapped `-` is an illegal specifier and a `case`
  # is illegal in a spec. `size(expr)` is the one runtime sub-position: its arg is
  # recursed in the segment's context (mutated in a body, pruned in a pattern).
  defp analyze_spec({:-, meta, [left, right]}, context, mutators),
    do:
      {:-, meta, [analyze_spec(left, context, mutators), analyze_spec(right, context, mutators)]}

  defp analyze_spec({:size, meta, [arg]}, context, mutators),
    do: {:size, meta, [analyze(arg, context, mutators)]}

  defp analyze_spec(other, _context, _mutators), do: other

  # Is this node form a sigil (`~r`, `~D`, `~w`, a custom `~X`)? Sigils parse as
  # `{:sigil_<name>, _, [<<>>, modifiers]}`; the analyzer offers the whole node to
  # the sigil mutators and descends into its content via `descend_sigil/2`.
  defp sigil?(form) when is_atom(form) do
    case Atom.to_string(form) do
      "sigil_" <> _ -> true
      _ -> false
    end
  end

  defp sigil?(_), do: false

  # Descend into a sigil's content `<<>>` *segments* (so an interpolated expression
  # like `~r/a#{b}c/` still mutates `b` — a genuine runtime sub-position) without
  # ever offering the content `<<>>` *wrapper* to a mutator: a sigil's content is
  # not a user-written bitstring literal, so collapsing it (BitstringLiteral) or
  # splicing a selector into it would be illegal. The modifier list is left raw; the
  # sigil node itself was already offered to the sigil mutators by the caller. A
  # bare-binary segment (`~r/foo/`'s `"foo"`) is descended too but offers nothing.
  defp descend_sigil({sigil, meta, [{:<<>>, bmeta, segments}, modifiers]}, mutators) do
    content = {:<<>>, bmeta, Enum.map(segments, &analyze_segment(&1, :runtime, mutators))}
    {sigil, meta, [content, modifiers]}
  end

  defp descend_sigil(node, _mutators), do: node

  def module_scaffold_statement?({form, _meta, _args}) when form in @module_scaffold_forms,
    do: true

  def module_scaffold_statement?(_node), do: false

  def module_macro_block_statement?({_form, _meta, args}) when is_list(args) and args != [] do
    case List.last(args) do
      kw when is_list(kw) -> block_keyword_list?(kw)
      _other -> false
    end
  end

  def module_macro_block_statement?(_node), do: false

  defp block_keyword_list?(kw) do
    Enum.any?(kw, fn
      {key, _value} -> Syntax.block_key?(key)
      _other -> false
    end)
  end

  # A module-level macro-with-block (`schema do … end`): init args are compile-time
  # (`:scaffold`), and the block keyword's `do`/… body is analyzed as **`:runtime`**
  # because an *unknown* DSL macro may `unquote` it into generated function bodies (so a
  # literal there could be a real runtime value). A **registered known macro** overrides
  # that guess per argument: a `:raw` arg (`{DSL, :schema, 1, :raw}`) is left **raw** —
  # no descent, no mutation — so core never mutates inside an opaque DSL block body and
  # can't poison the DSL the registry was meant to exclude. `:raw` and the call-level `:skip` are
  # honoured, and so is a **keyed refinement** over the block keyword (`[[do: :raw]]` keeps an
  # explicitly excluded DSL body untouched while the other pairs take the module-level default —
  # `route_module_arg/4`). The other treatments collapse to the default path, which already does
  # the right thing: `:expression` *is* the runtime-body guess, `:interior` has nothing to
  # withhold (a module-level container is never offered), `:pattern` has no module-level use.
  # `Resolve` stamps `meta[:mutare_route]` for bare-imported and qualified forms alike, so both
  # route.
  def analyze_module_macro_block({form, meta, args} = node, mutators) do
    case Meta.routing(meta) do
      # The call-level `:skip`: the whole block macro is an inert leaf.
      :skip ->
        node

      routing ->
        {init, [last]} = Enum.split(args, -1)

        init =
          init
          |> Enum.with_index()
          |> Enum.map(fn {arg, i} ->
            route_module_arg(
              arg,
              module_position(routing, i),
              &analyze(&1, :scaffold, mutators),
              fn _key, value -> analyze(value, :scaffold, mutators) end
            )
          end)

        last =
          route_module_arg(
            last,
            module_position(routing, length(args) - 1),
            &analyze_module_macro_block_arg(&1, mutators),
            &analyze_module_pair_value(&1, &2, mutators)
          )

        {form, meta, init ++ [last]}
    end
  end

  @doc """
  The name (form atom) to tag a module-level block macro's mutation sites with, for
  poison recovery — but only when the macro is **unknown** (no known-macro routing).

  An unknown DSL block is mutated on the guess that it is unquoted into a function;
  if the injected selector `case` is illegal in the DSL it poisons the single build,
  and `Mutare.Runner` skips the whole macro by this name (see `Mutare.Site`). A
  *registered* macro (`routing != nil`) returns `nil` — the user's `:call_routes` choice
  (mutate, `:raw`, or `:skip`) is honoured and never auto-skipped. Only meaningful for a node
  that `module_macro_block_statement?/1` already accepted.
  """
  @spec unknown_block_macro_name(Macro.t()) :: atom() | nil
  def unknown_block_macro_name({form, meta, _args}) do
    if Meta.routing(meta) == nil, do: form, else: nil
  end

  # The routed position of a module-level macro argument: no stamp (`nil`), or a position past
  # the routing list, is the `:expression` default.
  defp module_position(nil, _i), do: :expression
  defp module_position(routing, i), do: Enum.at(routing, i, :expression)

  # A module-level macro argument by its position. `:raw` leaves it as written. A keyed
  # refinement over a keyword argument (the `do:` block list, or trailing options) routes each
  # named value by its own position and the rest by the leading treatment's reading — `:raw`
  # stays raw, anything else is the module-level default for that pair (`pair_default`, keyed by
  # the pair's key: a block body is the runtime guess, an option value is scaffold) — and every
  # key stays raw (keys are compile-time here, block and data alike). A non-keyword argument
  # takes the leading treatment alone. Every other position takes `arg_default`, the module-level
  # guess for the whole argument.
  defp route_module_arg(arg, :raw, _arg_default, _pair_default), do: arg

  defp route_module_arg(arg, {:keyed, leading, pairs}, arg_default, pair_default) do
    case CallOptions.keyword_pairs(arg) do
      {:ok, kw_pairs, rewrap} ->
        inner = if leading == :raw, do: :raw, else: :expression

        kw_pairs
        |> Enum.map(fn {key, value} ->
          position =
            case List.keyfind(pairs, AST.key_atom(key), 0) do
              {_key, position} -> position
              nil -> inner
            end

          value_default = fn v -> pair_default.(key, v) end
          {key, route_module_arg(value, position, value_default, pair_default)}
        end)
        |> rewrap.()

      :error ->
        route_module_arg(arg, leading, arg_default, pair_default)
    end
  end

  defp route_module_arg(arg, _position, arg_default, _pair_default), do: arg_default.(arg)

  # The module-level default for one keyword pair's value: a block key's body is analyzed as
  # `:runtime` (an unknown DSL may unquote it into generated functions), an option value as
  # `:scaffold`.
  defp analyze_module_pair_value(key, value, mutators) do
    context = if Syntax.block_key?(key), do: :runtime, else: :scaffold
    analyze(value, context, mutators)
  end

  defp analyze_module_macro_block_arg(kw, mutators) when is_list(kw) do
    Enum.map(kw, fn
      {key, value} -> {key, analyze_module_pair_value(key, value, mutators)}
      other -> analyze(other, :scaffold, mutators)
    end)
  end

  # === shared helpers ========================================================

  # The liveness a child *body* inherits from its construct. A `:scaffold`
  # (compile-time metaprogramming) parent keeps its child bodies compile-time too —
  # so a `case`/`cond`/`with`/`fn` that wraps a `def` at module level does not mutate
  # its own arms — while every other context yields an ordinary runtime body. The one
  # construct that flips a `:scaffold` descent back to `:runtime` is a `def`/`defp`
  # body, done explicitly in its own clause (a generated function's body *is* runtime).
  defp body_context(:scaffold), do: :scaffold
  defp body_context(_), do: :runtime
end
