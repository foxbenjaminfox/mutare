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

  alias Mutare.AST
  alias Mutare.Mutator
  alias Mutare.Transform.{Candidate, NodeRange, Suppression}

  # The suppression operator vocabulary, in guard position (see `Suppression`'s twin-map):
  # the body path's five equivalent-sibling clauses below match on these shared `defguard`s
  # rather than literal operator lists, so they can't drift from the guard path's twins in
  # `Mutare.Transform.Tag`.
  import Suppression, only: [is_negation_op: 1, is_equality_op: 1, is_body_connective: 1]

  alias Mutare.Transform.Analyze.{
    CallOptions,
    Captures,
    ClausePatterns,
    Conditions,
    Macros,
    MatchPatterns,
    Returns
  }

  # The try-style body blocks whose clause bodies are *return paths*
  # (`rescue`/`catch`/`else`). Their left side is always a match, and their tails
  # return — unlike `:after`, whose value `try` discards (so it is no return path
  # and is left to mutate only in place, like `:do`).
  @clause_block_keys [:rescue, :catch, :else]

  # The keyword atoms that render a construct's `do … end` block (`do:` plus the
  # `else`/`rescue`/`catch`/`after` tails). As *block* syntax these keys carry no
  # `format: :keyword` marker, so `label_key?/1` recognises them by atom — protecting
  # a key like `do:` from being mutated (which would not even render).
  @block_keys [:do, :else, :rescue, :catch, :after]

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
  # `Mutare.Transform.Analyze.Macros` drives the `:pattern`/`:binding_pattern` argument routing
  # through (the in-module counterpart to `annotate/2`).
  def pattern(node, mutators), do: analyze(node, :pattern, mutators)

  # `when` guard (position-independent: also covers case/fn clause guards): the
  # lift path owns guard mutation, so the in-place walk never touches one.
  defp analyze({:when, _meta, [_call | guards]} = node, _context, _mutators)
       when guards != [],
       do: node

  # module attribute `@x <value>`: compile-time, pruned whole. A bare `@x` read
  # has an atom context (not a single-value list) and falls through to runtime.
  defp analyze({:@, _meta, [{_name, _am, [_value]}]} = node, _context, _mutators), do: node

  # `defmacro`/`defmacrop`: compile-time / macro-generated, pruned whole.
  defp analyze({vis, _meta, _args} = node, _context, _mutators)
       when vis in [:defmacro, :defmacrop],
       do: node

  # `import`/`alias`/`require`/`use`: lexical directives resolved at compile time.
  # Their arguments are not a runtime position — an `import`'s `only:`/`except:`
  # must be a *literal* keyword list, an `alias`'s `as:` a literal atom, a `use`'s
  # options are handed to a macro at expansion — so a runtime selector there is at
  # best inert and at worst illegal (it makes the single build fail). Pruned whole;
  # the directive rides through untouched and in position.
  defp analyze({form, _meta, args} = node, _context, _mutators)
       when form in [:import, :alias, :require, :use] and is_list(args),
       do: node

  # `defprotocol`/`defdelegate`: pure compile-time module references with no runtime
  # body to mutate — `defprotocol` declares signatures, `defdelegate` forwards to a
  # `to:` module. A selector spliced into the protocol name / delegation target would
  # not compile (it expects a literal module), so prune whole. (Relevant once an alias
  # mutator can match the module references they carry.)
  defp analyze({form, _meta, _args} = node, _context, _mutators)
       when form in [:defprotocol, :defdelegate],
       do: node

  # `defimpl`: the protocol alias and the `for:` type are compile-time module
  # references (a selector there won't compile), but the `do:` block *is* runtime —
  # its implementation defs must still mutate. Analyze only the `do:` value, passing
  # the protocol-alias arg and every non-`do:` keyword entry (notably `for:`) through
  # raw. This handles both the block form (`for:`/`do:` in separate args) and the
  # inline form (folded into one keyword).
  defp analyze({:defimpl, meta, args}, _context, mutators) when is_list(args) do
    {:defimpl, meta, Enum.map(args, &analyze_defimpl_arg(&1, mutators))}
  end

  # `quote`: its body is compile-time AST *construction*, not runtime code. The
  # literals there become part of the code the quote *generates* — instrumenting
  # which is out of scope (PHILOSOPHY: "macro-generated code is a different tool"),
  # exactly like a `defmacro` body. Worse, a selector `case` spliced into a quoted
  # pattern or guard (e.g. `quote do: (case x do "" -> … end)`) is valid *as a
  # quote* but illegal where the AST is later compiled — a poison the pre-filter
  # can't see, because the metamutant itself compiles. Pruned whole. (This also
  # prunes any `unquote(expr)` runtime sub-positions inside; mutating those is
  # deferred — see NOTES — and losing them is acceptable per the philosophy above.)
  defp analyze({:quote, _meta, args} = node, _context, _mutators)
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
  defp analyze({:&, _meta, [{:/, _smeta, [left, right]}]} = node, context, mutators) do
    cond do
      not (function_ref?(left) and integer_literal?(right)) ->
        recurse(node, context, mutators)

      context == :runtime ->
        Captures.offer(node, left, right, mutators)

      true ->
        node
    end
  end

  # A `def`/`defp` clause reaching the in-place path (one that did not lift, or the
  # *original* clause of a lifted group): the head is a pattern, the body keyword is
  # runtime, and the `:do` block's *tail expression* is additionally a return-value
  # position (only the transform knows where a clause returns — see
  # `annotate_returns/3`). A `def … rescue …` shorthand additionally gets its rescue
  # clauses narrowed/dropped (`host_def_rescue/3`). The body is first
  # `normalize_clause_blocks/1`-ed so an **inline keyword** rescue/catch/else
  # (`def f, do: …, rescue: (p -> b)`) reads like its block-form twin.
  defp analyze({vis, meta, [head, body_kw]}, _context, mutators)
       when vis in [:def, :defp] and is_list(body_kw) do
    head = analyze(head, :pattern, mutators)
    body_kw = normalize_clause_blocks(body_kw)
    analyzed_kw = analyze_do_blocks(body_kw, mutators)
    annotated_kw = Returns.annotate_returns(analyzed_kw, body_kw, mutators)
    {vis, meta, [head, host_def_rescue(annotated_kw, body_kw, mutators)]}
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
  defp analyze({:<<>>, meta, segments} = node, :runtime, mutators) do
    seg_fun =
      if Keyword.has_key?(meta, :delimiter),
        do: &analyze_segment(&1, :runtime, mutators),
        else: &analyze_construction_segment(&1, mutators)

    analyzed = {:<<>>, meta, Enum.map(segments, seg_fun)}
    offer(analyzed, node, mutators)
  end

  defp analyze({:<<>>, meta, segments}, context, mutators) do
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
  defp analyze({:%, meta, [aliases, {:%{}, mmeta, pairs}]}, context, mutators)
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
  defp analyze({:__block__, meta, stmts}, :runtime, mutators)
       when is_list(stmts) and length(stmts) >= 2 do
    {init, [last]} = Enum.split(stmts, -1)
    init = Enum.map(init, &MatchPatterns.analyze_statement(&1, mutators))
    {:__block__, meta, init ++ [analyze(last, :runtime, mutators)]}
  end

  # match `=`: the left side is a pattern, the right keeps the context. The `=` node itself is
  # deliberately **not** offered to mutators (no `offer/3` here) — there is no "mutate `=`" entry
  # point, unlike the *macro* node (`analyze_known_macro` offers it so a `macros/0` mutator can
  # fire). This is load-bearing: it is *why* the value-discarded-`=` path
  # (`attach_match_pattern_candidates/4`) can prepend its `MatchPattern` candidates with
  # `put_candidates` without shadowing anything, and why no whole-`=` mutation can trap the
  # escaping bindings. If you ever start offering this node, mirror the macro path's
  # `rehome_call_mutations/2`: re-home the whole-`=` mutation into the tuple-export selector
  # (give `Candidate.MatchPattern` a `mutant_expr`-style field, as `MacroPattern` has). The
  # invariant is guarded by `match_pattern_test.exs` ("a bare `=` node is never offered…").
  defp analyze({:=, meta, [lhs, rhs]}, context, mutators) do
    {:=, meta, [analyze(lhs, :pattern, mutators), analyze(rhs, context, mutators)]}
  end

  # `<-` generator/with-clause: the left is a pattern (matched against each value
  # in `for x <- …`, or the right's result in `with {:ok, x} <- …`), the right keeps
  # the context. Mirrors `=` — without it a literal in the LHS would be mutated.
  defp analyze({:<-, meta, [lhs, rhs]}, context, mutators) do
    {:<-, meta, [analyze(lhs, :pattern, mutators), analyze(rhs, context, mutators)]}
  end

  # (`match?`/`destructure` and any other pattern-context macro are no longer a
  # dedicated clause here: they are *known macros* (`Mutare.Macros`), recognised by
  # the lexical pre-pass via their resolved module — so a bare `match?(p, e)` is
  # routed only when it is genuinely `Kernel.match?`, and an aliased/qualified or
  # user-registered macro is handled the same way. The routing is read from the
  # `meta[:mutare_macro]` stamp in the generic runtime clause below.)

  # `cond`: the one `->` construct whose clause *left* is a runtime condition, not
  # a pattern — so it stays mutatable. Analyze its clauses keeping both sides
  # runtime, intercepting them before the generic `->` clause (below) would wrongly
  # pattern-route the conditions. The `:do` block key is protected by the
  # keyword-pair clause.
  defp analyze({:cond, meta, [blocks]}, context, mutators) when is_list(blocks) do
    body_ctx = body_context(context)
    {:cond, meta, [Enum.map(blocks, &analyze_cond_block(&1, body_ctx, mutators))]}
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
  # matching an `if`; the built-ins match none).
  #
  # When the condition binds a variable that escapes into the body (`if (name =
  # lookup()) != nil do …`), the plain path can't host a condition selector (it would
  # trap the binding — see `analyze_condition/2`), so a hoistable case is restructured
  # into a `__block__` that lifts the binding out and lets the now-binding-free
  # condition carry the decision mutant (`hoist_if/6`). Only `:runtime` — a module-level
  # (`:scaffold`) `if` runs once at compile time, so its condition is inert and falls
  # through to the non-mutating catch-all.
  defp analyze({form, meta, [condition, body_kw]} = node, :runtime, mutators)
       when form in [:if, :unless] and is_list(body_kw) do
    analyzed_body = analyze(body_kw, :runtime, mutators)
    analyzed_condition = analyze(condition, :runtime, mutators)

    if Conditions.hoist_if?(analyzed_condition, mutators) do
      Conditions.hoist_if(form, meta, condition, analyzed_condition, analyzed_body, mutators)
    else
      analyzed_condition = Conditions.finish_condition(analyzed_condition, condition, mutators)
      rebuilt = {form, meta, [analyzed_condition, analyzed_body]}
      offer(rebuilt, node, mutators)
    end
  end

  # `case`: a runtime expression whose *clause patterns/guards* are mutatable by the
  # structural families (`PatternSwap`/`PatternWildcard`), the literal families, and the
  # guard families. A `case` *has* a scrutinee, so the mutants are delivered per-clause by
  # the **tuple-the-scrutinee** rewrite (the C+M analogue of head lifting — see
  # `Mutare.Transform.emit_case_pattern_site/3`): the whole `case` becomes `case {<active>,
  # <subject>} do …` and each mutant adds one gated clause. The construct is still analyzed
  # normally (subject/bodies mutate; `->` keeps patterns `:pattern`; guards stay pruned),
  # and the per-clause `Candidate.CaseClause`s are attached under the `:mutare_case` meta key
  # (separate from `:mutare`, since they need the dedicated emit). The whole-`case`-node
  # parity offer is dropped — no built-in matches a `case`, and a custom whole-`case` mutator
  # can't be combined with the per-clause tupling (a documented, built-in-irrelevant gap).
  defp analyze({:case, _meta, [_subject, [{_do_key, clauses}]]} = node, :runtime, mutators)
       when is_list(clauses) do
    analyzed = recurse(node, :runtime, mutators)

    case ClausePatterns.case_clause_candidates(clauses, mutators) do
      [] -> analyzed
      candidates -> ClausePatterns.put_case_candidates(analyzed, candidates)
    end
  end

  # `receive`/`fn`: the same kinds of clause-pattern/guard mutations, but neither has a
  # scrutinee to tuple (`receive` matches the mailbox; `fn` matches its call arguments), so
  # each mutant is delivered by wrapping the **whole** construct in an in-place selector
  # whose mutant branch is a copy with one clause's pattern/guard changed — sound because
  # these clause bindings are local to a clause body and never escape. Each is still analyzed
  # normally, and the `Candidate.CasePattern`s are attached so emission hosts them in the
  # same selector. The two differ only in *where the clauses live* and *how to rebuild the
  # whole node*, captured by the clause list + `rebuild_fn` passed to
  # `attach_clause_pattern_candidates/4`. (Each mutant is a full copy — C×M — acceptable for
  # these rare, small constructs; `case` uses the per-clause path above.)
  defp analyze({:receive, meta, [blocks]} = node, :runtime, mutators) when is_list(blocks) do
    {clauses, rebuild} = ClausePatterns.receive_do_clauses(blocks, meta)
    ClausePatterns.attach_clause_pattern_candidates(node, clauses, rebuild, mutators)
  end

  # A `fn` additionally has its clause bodies' return tails mutated: each clause
  # returns the value of its body when the closure is called, so every clause-body
  # leaf tail is a return path (`Returns.annotate_fn_returns/3`, run on the analyzed
  # node with the raw `node` supplying the clean diff). The return candidates ride on
  # the tail nodes inside the clause bodies; the clause-pattern candidates ride on the
  # `fn` node's own meta — different nodes, so they nest cleanly at emit.
  defp analyze({:fn, meta, clauses} = node, :runtime, mutators) when is_list(clauses) do
    rebuild = fn new -> {:fn, meta, new} end

    node
    |> ClausePatterns.attach_clause_pattern_candidates(clauses, rebuild, mutators)
    |> Returns.annotate_fn_returns(node, mutators)
  end

  # `try`: a runtime expression whose `rescue` clauses are special — they match on
  # *exception types* (`var in [A, B]` / `var` / `Type`), carry **no `when` guard**, and so
  # can't be dispatched per-clause the way `case` is. `Mutare.Mutators.RescueType` mutates them
  # two ways, both delivered by the **whole-construct selector** (the whole `try` is wrapped,
  # its mutant branch a copy of the `try` — sound, a rescue binding is body-local): it narrows a
  # `var in [A, B]` list by dropping one type (`Candidate.CasePattern`), and — for the idiomatic
  # multi-branch shape where each clause catches a single type and there is no list to narrow —
  # it drops a whole `rescue` clause (`Candidate.RescueDrop`, only when ≥2 clauses are present so
  # the `rescue` is never left empty). The construct is still analyzed normally (do/rescue-bodies/
  # catch/else/after mutate; the rescue/else/catch patterns stay `:pattern`). This clause handles the
  # explicit `try`; the `def … rescue …` shorthand carries the same blocks at the def-body level and
  # is hosted in a synthesized `try` by `host_def_rescue/3` (off the same `rescue_type_candidates/3`).
  defp analyze({:try, meta, [blocks]} = node, :runtime, mutators) when is_list(blocks) do
    analyzed = recurse(node, :runtime, mutators)

    candidates =
      build_candidates(node, Mutator.mutations(node, mutators)) ++
        ClausePatterns.rescue_type_candidates(blocks, meta, mutators)

    case candidates do
      [] -> analyzed
      _ -> put_candidates(analyzed, candidates)
    end
  end

  # A `->` clause in a pattern-matching construct (`case`/`fn`/`receive`/`with` else/
  # a `try` block outside a def head/`for` reduce): the left is a pattern (never
  # mutated — a selector `case` is illegal in a pattern and would poison the single
  # build), the body inherits the construct's liveness (`body_context/1`): `:runtime`
  # normally, `:scaffold` when this construct itself wraps a metaprogrammed `def` at
  # module level (so the arm's own code is left compile-time-inert). `cond` is
  # excepted above; a `when` guard among the patterns is returned whole by the
  # `:when` clause, so guards stay untouched.
  defp analyze({:->, meta, [patterns, body]}, context, mutators) when is_list(patterns) do
    {:->, meta,
     [
       Enum.map(patterns, &analyze(&1, :pattern, mutators)),
       analyze(body, body_context(context), mutators)
     ]}
  end

  # default argument inside a pattern (`x \\ expr`): the variable is a pattern,
  # but the default runs at call time → runtime (don't regress its mutation).
  defp analyze({:\\, meta, [var, default]}, :pattern, mutators) do
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
  # its LHS into match?'s **pattern** position, and a `:skip` macro may accept a LHS that
  # is neither a valid expression nor a valid pattern. Treating it as runtime would splice
  # a selector `case` into pattern/opaque position and poison the build.
  defp analyze({:|>, meta, [lhs, rhs]}, :runtime, mutators) do
    {:|>, meta,
     [Macros.analyze_piped_value(lhs, rhs, mutators), analyze_pipe_stage(rhs, mutators)]}
  end

  # `for` comprehension: its generators (`<-`), filters, `:into`/`:reduce` options
  # and `:do`/`:reduce` body all descend as ordinary runtime, but the **`:uniq`**
  # option must be a *literal boolean* — the `for` special form rejects any
  # non-literal there (`:uniq option for comprehensions only accepts a boolean`),
  # so a selector `case` spliced into its value (Literal/Conditional firing on the
  # `true`/`false`) would poison the single build. The `:uniq` value alone is held
  # back from mutators (`analyze_for_arg/2`); the node itself is still offered for
  # parity with the generic clause (no built-in matches `for`).
  defp analyze({:for, _meta, args} = node, :runtime, mutators) when is_list(args) do
    {:for, meta, args} = offer(node, node, mutators)
    {:for, meta, Enum.map(args, &analyze_for_arg(&1, mutators))}
  end

  # `with`: a chain of clauses (`<-`/`=`/bare-expr, every one value-discarded) followed by
  # the trailing `[do: …, else: …]` keyword. A bare `=` clause is a match used solely for
  # its bindings — which escape to later clauses and the `do` body — exactly the rewriteable
  # position, so each clause routes through `analyze_statement/2` (a `=` gets a
  # `Candidate.MatchPattern`; a `<-` keeps its LHS a `:pattern`; a bare expr is ordinary
  # runtime). The keyword tail descends as usual (the `do` body's own non-final `=`
  # statements are reached there too; `else` patterns stay `:pattern` via the generic `->`
  # clause). A `<-` non-match routes to `else`, but a `=` non-match raises `MatchError`
  # (which `else` never catches) — preserved by the rewrite's trailing raise clause. (A
  # malformed `with` with no keyword tail falls back to the generic runtime descent.)
  defp analyze({:with, meta, args} = node, :runtime, mutators)
       when is_list(args) and args != [] do
    if is_list(List.last(args)) do
      {clauses, [body_kw]} = Enum.split(args, -1)
      clauses = Enum.map(clauses, &MatchPatterns.analyze_statement(&1, mutators))
      rebuilt = {:with, meta, clauses ++ [analyze(body_kw, :runtime, mutators)]}
      offer(rebuilt, node, mutators)
    else
      node |> offer(node, mutators) |> recurse_runtime(mutators)
    end
  end

  # === redundancy suppression: equivalent sibling mutants ====================
  #
  # Five shapes where one family's mutant is *guaranteed equivalent* to another's, so
  # the redundant one is dropped. The shared move (clauses 1–4) is the same as `not in`
  # always did: descend operands (so their literals still mutate) but do **not** *offer*
  # the inner/redundant node — only the outer. (Clause 5, the short-circuit connective,
  # instead *offers* the node and drops a single one of its mutations — the per-mutation
  # shape of the `in`-RHS empty-collection drop below.) Dropping a candidate here (rather
  # than post-hoc) leaves no id/site/selector, exactly like the other positive suppressions.
  #
  # (1) **Double negation** `not not x` / `!!x` — the **same** operator twice. Logical
  # strips the outer *and* the inner to the identical single-negation (`not x` / `!x`),
  # and Conditional on the inner (`not true`/`not false`) duplicates the outer's
  # `true`/`false`. Same operator only: a mixed `not !x` could differ on a non-boolean
  # operand (`not x` raises where `!x` coerces to `false`), so it is left fully offered.
  defp analyze({neg, meta, [{neg, inner_meta, [operand]}]} = node, :runtime, mutators)
       when is_negation_op(neg) do
    inner = {neg, inner_meta, [analyze(operand, :runtime, mutators)]}
    offer({neg, meta, [inner]}, node, mutators)
  end

  # (2) **`not`/`!` over `in`** (`x not in y` parses as `not(x in y)`). The inner `in`'s
  # only Relational mutation (`in` → `not in`) re-negates to `x in y` ≡ Logical's strip
  # of the outer; Conditional on the inner (`not true`/`not false`) ≡ the outer's
  # `true`/`false`. So the inner `in` is not offered (only its operands descend), and its
  # RHS is further List-suppressed — an empty list makes `x in []` ≡ `false`, again the
  # outer's Conditional (see `analyze_in_rhs/2`). The outer `not`/`!` is offered normally.
  defp analyze({neg, meta, [{:in, in_meta, [left, right]}]} = node, :runtime, mutators)
       when is_negation_op(neg) do
    inner = {:in, in_meta, [analyze(left, :runtime, mutators), analyze_in_rhs(right, mutators)]}
    offer({neg, meta, [inner]}, node, mutators)
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
  defp analyze({neg, meta, [{op, op_meta, [left, right]}]} = node, :runtime, mutators)
       when is_negation_op(neg) and is_equality_op(op) do
    inner_raw = {op, op_meta, [left, right]}

    inner =
      {op, op_meta, [analyze(left, :runtime, mutators), analyze(right, :runtime, mutators)]}
      |> offer(inner_raw, mutators)
      |> drop_negation_redundant_candidates(op)

    offer({neg, meta, [inner]}, node, mutators)
  end

  # (4) **A bare `x in [list]`** — offer the `in` node normally (Conditional `true`/`false`,
  # Relational → `not in`), but its RHS list literal is List-suppressed: collapsing it to
  # `[]` makes `x in []` ≡ `false`, which Conditional already produces on the `in` node.
  defp analyze({:in, meta, [left, right]} = node, :runtime, mutators) do
    rebuilt = {:in, meta, [analyze(left, :runtime, mutators), analyze_in_rhs(right, mutators)]}
    offer(rebuilt, node, mutators)
  end

  # (5) **A short-circuit connective whose left operand is itself a boolean op**
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
  defp analyze({op, _meta, [left, _right]} = node, :runtime, mutators)
       when is_body_connective(op) do
    analyzed = node |> offer(node, mutators) |> recurse_runtime(mutators)

    if Suppression.boolean_op_node?(left),
      do: drop_constant_candidate(analyzed, Suppression.redundant_constant(op)),
      else: analyzed
  end

  # A generic runtime node: offer it and descend, or route a known-macro call's arguments
  # by treatment — see `do_analyze_call_node/4`. (A sigil is offered whole then descended
  # *surgically* via `descend_sigil/2`, so an interpolated `~r/a#{b}c/` still mutates `b`
  # while its content `<<>>` wrapper is never offered; that gate lives in the helper.)
  defp analyze({_form, _meta, _args} = node, :runtime, mutators),
    # `descend_sigils?: true` — a generic runtime node may be sigil syntax (a piped stage never is).
    do: do_analyze_call_node(node, mutators, %{pipe_mode: :unpiped}, true)

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
  # their own clauses, before reaching here.
  defp analyze({key, value} = pair, context, mutators) do
    if block_key?(key),
      do: {key, analyze(value, context, mutators)},
      else: recurse(pair, context, mutators)
  end

  # anything else — a node in a non-runtime context, or a container/leaf:
  # descend without mutating so boundary forms (`\\`, `<<>>`) still fire on
  # children, but attach no candidate here.
  defp analyze(node, context, mutators), do: recurse(node, context, mutators)

  # The RHS of `in`: analyze it as ordinary runtime (so its keys/values/elements still
  # mutate), then drop from the **top node** any mutation whose result is an *empty
  # enumerable literal* — `[]` (List), `%{}` (MapLiteral), `~w()` (WordListLiteral),
  # `~c""` (CharlistLiteral). On the right of `in`, `x in <empty>` is constantly `false`,
  # exactly the mutant Conditional already produces on the `in` node, so it is redundant.
  # The drop is **per mutation**, not per node: a word/charlist sigil keeps its non-empty
  # sentinel (`~w(mutare)`) — only its empty sibling goes. It is scoped to the top node, so
  # an empty mutation on a *nested* literal (`x in foo([a, b])` → `foo([])`, which is *not*
  # constantly false) is left alone. Any non-collection RHS (a variable, range, call) yields
  # no empty-collection mutation, so nothing is dropped.
  defp analyze_in_rhs(right, mutators) do
    right |> analyze(:runtime, mutators) |> drop_empty_collection_candidates()
  end

  defp drop_empty_collection_candidates(node), do: reject_candidates(node, &empty_collection?/1)

  defp empty_collection?(%Candidate.InPlace{mutator: spec, mutated: mutated}),
    do: Mutator.empty_collection?(spec, mutated)

  defp empty_collection?(_candidate), do: false

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
  # `hoist_pipe/2` lifts the selector out of the illegal pipe-RHS position into a
  # one-shot closure on the piped value — `lhs |> (fn v -> case … (each branch pipes
  # `v`) … end).()`. A non-call RHS (rare) is analyzed normally.
  #
  # A piped **known-macro** stage (`q |> where([p], p.x == 1)`, the query-builder shape)
  # routes its arguments by treatment too — `Resolve` already stamped the *visible*-position
  # routing (the piped value dropped), so a `:skip` DSL body is left raw instead of mutated.
  defp analyze_pipe_stage({_form, _meta, args} = node, mutators) when is_list(args),
    # `descend_sigils?: false` — a `|>` RHS is never sigil syntax.
    do: do_analyze_call_node(node, mutators, %{pipe_mode: :piped}, false)

  defp analyze_pipe_stage(other, mutators), do: analyze(other, :runtime, mutators)

  # The shared call-node dispatch behind the generic runtime `analyze/3` clause and
  # `analyze_pipe_stage/2`: a call stamped a **known macro** (`meta[:mutare_macro]`, set by
  # `Mutare.Transform.Resolve` from `Mutare.Macros`) routes its arguments by their declared
  # treatment (`Macros.analyze_known_macro` — so a pattern arg isn't mutated in place and an
  # opaque DSL body is left raw) while the whole node is still offered to mutators; every other
  # node is offered and its children descended. `context` carries `:pipe_mode` (`:piped` for a
  # `|>` RHS, so an arity-changing mutator sees the effective arity). `descend_sigils?` gates the
  # sigil-content path, true only for the generic clause.
  defp do_analyze_call_node({form, meta, _args} = node, mutators, context, descend_sigils?) do
    case macro_routing(meta) do
      nil ->
        node = offer(node, node, mutators, context)

        # `sigil?(form)` (the `sigil_<x>` head) is necessary but **not sufficient**: a call to a
        # *function* named `sigil_s`/`sigil_r`/… (a local sigil shadowing `Kernel`'s) parses to the
        # same head. Routing such a call through `descend_sigil/2` would treat a real `<<…>>`
        # *argument* of it (`sigil_r(<<"x">>, [])`) as sigil **content** and descend it without the
        # `::binary` construction pin, breaking the baseline (the same hazard
        # `binary_valued_literal?/1` guards). Only genuine sigil syntax carries the parser's
        # `:delimiter` meta, so gate on it; a non-sigil call falls through to `recurse_runtime`,
        # which analyses its args — including a real bitstring arg — correctly.
        if descend_sigils? and sigil?(form) and Keyword.has_key?(meta, :delimiter),
          do: descend_sigil(node, mutators),
          else: recurse_runtime(node, mutators)

      routing ->
        Macros.analyze_known_macro(node, routing, mutators, context)
    end
  end

  # === known macros ==========================================================

  @doc """
  The per-argument routing stamped on a call by `Mutare.Transform.Resolve` when it
  resolves to a known macro (`Mutare.Macros`), or `nil` for an ordinary call. The one
  reader of the `:mutare_macro` contract key — `Mutare.Transform.Analyze.MatchPatterns`
  shares it rather than reimplementing the accessor.
  """
  @spec macro_routing(keyword() | term()) :: term()
  def macro_routing(meta) when is_list(meta), do: Keyword.get(meta, :mutare_macro)
  def macro_routing(_meta), do: nil

  # The known-macro argument *routing* lives in `Mutare.Transform.Analyze.Macros`:
  # `Macros.analyze_known_macro/4` (a written/piped stage) and `Macros.analyze_piped_value/3`
  # (the `|>` LHS reaching back into a macro's argument-0 treatment) route each argument by its
  # declared treatment — a pattern, an opaque `:skip` DSL body, a `:hosted` fragment — driving the
  # descent back through `annotate/2`/`pattern/2`/`offer/4`. The core walk reads the stamp here
  # (`macro_routing/1`) and dispatches there.

  # One argument of a `for`: a generator/filter/match is descended as a *statement*
  # (its value is discarded — a qualifier only binds/filters), while the trailing
  # options/body keyword list keeps every option *key* raw — `:into`/`:reduce`/`:uniq`/
  # `:do` are `for`-special-form keywords, so mutating a key is a compile error
  # (`unsupported option :mutare given to for`), unlike a free-form map/keyword key. The
  # `:uniq` *value* must also be a literal boolean (a selector there would poison the
  # build), so it is held back; every other value (`:into`/`:reduce` and the `:do`/
  # `:reduce` body) descends as ordinary runtime.
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

  # A non-keyword qualifier — a generator (`<-`), a filter, or a **bare `=` match**.
  # `analyze_match_statement/2` offers a `=` LHS to the structural pattern families (a `for`
  # `=` qualifier discards its value, so the tuple-export rewrite is sound) and leaves
  # generators/filters as ordinary runtime. (Unlike a block statement / `with` clause, a
  # *bare macro call* qualifier is a filter, not value-discarded, so it stays unrewritten.)
  defp analyze_for_arg(arg, mutators), do: MatchPatterns.analyze_match_statement(arg, mutators)

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

  # Normalize a clause's body keyword so an **inline keyword** rescue/catch/else block reads
  # like its **block-form** twin. Written inline — `def f, do: …, rescue: (p -> b)` (the
  # `rescue:`/`catch:`/`else:` value in `(…)` keyword form) — Sourceror wraps the clause list in
  # a `{:__block__, _, [clauses]}`, whereas the block form (`def f do … rescue … end`) yields the
  # bare list. Unwrap the former so every downstream consumer sees one shape: the clause routing
  # in `analyze_do_blocks/2` (guarded on `is_list` — otherwise the whole rescue is mis-analyzed as
  # a *runtime expression*, splicing a selector into a position no `->` clause may hold: poison),
  # the rescue-clause-body return tails in `annotate_returns/3` (likewise `is_list`-guarded), and
  # the rescue narrowing/clause-drop discovery in `host_def_rescue/3` → `rescue_type_candidates/3`
  # (whose `:rescue` list guard would otherwise miss it, so the valid inline `def … rescue` form
  # produced no `:rescue_type` mutants). A block-form body's clause values are already bare lists,
  # so this is a no-op there; non-clause keys (`:do`/`:after`) are never unwrapped.
  defp normalize_clause_blocks(body_kw) do
    Enum.map(body_kw, fn
      {key, {:__block__, _meta, [clauses]}} = pair when is_list(clauses) ->
        if clause_block_key?(key), do: {key, clauses}, else: pair

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
  defp analyze_do_blocks(body_kw, mutators) do
    Enum.map(body_kw, fn {key, value} ->
      if clause_block_key?(key) and is_list(value),
        do: {key, Enum.map(value, &analyze_try_clause(&1, mutators))},
        else: {key, analyze(value, :runtime, mutators)}
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
  defp host_def_rescue(annotated_kw, raw_body_kw, mutators) do
    # `do:`/`end:` block markers force Sourceror to render the synthesized `try` in block form
    # (`try do … rescue … end`); a `[]`-meta `try` over the source's `{:__block__, …, [:do]}`
    # block keys would otherwise render the invalid inline keyword form (`try do: …, rescue: …`).
    # The marker values are empty (these are generated, lineless nodes); the same meta is threaded
    # to the candidates' rebuilt mutant tries via `rescue_type_candidates/3`.
    try_meta = [do: [], end: []]

    case ClausePatterns.rescue_type_candidates(raw_body_kw, try_meta, mutators) do
      [] -> annotated_kw
      candidates -> [do: put_candidates({:try, try_meta, [annotated_kw]}, candidates)]
    end
  end

  # One `rescue`/`catch`/`else` clause: its patterns are matches (`:pattern`), its
  # body is runtime. A `when` guard among the patterns is returned whole by the
  # `:when` clause of `analyze/3` (guard mutation in a try clause isn't supported).
  defp analyze_try_clause({:->, meta, [patterns, body]}, mutators) when is_list(patterns) do
    patterns = Enum.map(patterns, &analyze(&1, :pattern, mutators))
    {:->, meta, [patterns, analyze(body, :runtime, mutators)]}
  end

  defp analyze_try_clause(other, mutators), do: analyze(other, :runtime, mutators)

  # One `cond` do-block: a `{key, clauses}` pair whose key is the `:do` label (kept
  # raw, never mutated) and whose clauses each keep *both* sides in `context` — a cond
  # clause's left is a condition, not a pattern. `context` is the construct's liveness
  # (`:runtime` for an ordinary cond; `:scaffold` for a module-level cond that wraps a
  # metaprogrammed `def`, keeping its conditions compile-time-inert). Anything
  # unexpected falls back to a plain descent in that context.
  defp analyze_cond_block({key, clauses}, context, mutators) when is_list(clauses),
    do: {key, Enum.map(clauses, &analyze_cond_clause(&1, context, mutators))}

  defp analyze_cond_block(other, context, mutators), do: analyze(other, context, mutators)

  defp analyze_cond_clause({:->, meta, [conds, body]}, context, mutators) when is_list(conds) do
    analyzed_conds =
      Enum.map(conds, fn cond_node ->
        # Analyze as a condition (runtime, IfCondition, binding-safe) only when live —
        # a `:scaffold` cond (module-level metaprogramming) runs once at compile time
        # with mutant 0, so a selector on its condition could never activate.
        if context == :runtime,
          do: Conditions.analyze_condition(cond_node, mutators),
          else: analyze(cond_node, context, mutators)
      end)

    {:->, meta, [analyzed_conds, analyze(body, context, mutators)]}
  end

  defp analyze_cond_clause(other, context, mutators), do: analyze(other, context, mutators)

  # One argument of a `defimpl`: a keyword list holding the `do:` block (its body is
  # runtime — analyze it) alongside compile-time entries like `for:` (pass raw). The
  # leading protocol-alias argument is not a list, so it passes through untouched.
  defp analyze_defimpl_arg(kw, mutators) when is_list(kw) do
    Enum.map(kw, fn
      {key, value} = pair ->
        if do_key?(key), do: {key, analyze(value, :runtime, mutators)}, else: pair

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

  # Offer `raw` to the mutators; if any fire, attach their candidates — built from
  # `raw`, so the diff renders the author's node — to `subject`, the already-analyzed
  # node whose children carry their own selectors. `subject` *is* `raw` at most sites;
  # the `<<>>`/`if`/`not in` clauses pass an analyzed/rebuilt subject distinct from the
  # raw node the candidate records. `context` carries the pipe flag (`Mutator.mutations`).
  # Public as part of the sub-walk API: `Mutare.Transform.Analyze.Macros` offers a
  # known-macro node through here (`offer(node, node, mutators, context)`).
  def offer(subject, raw, mutators, context \\ %{pipe_mode: :unpiped}) do
    case Mutator.mutations(raw, mutators, context) do
      [] -> subject
      muts -> put_candidates(subject, build_candidates(raw, muts))
    end
  end

  # `build_candidates/2` and `put_candidates/2` are part of the small sub-walk API
  # the split-out `Mutare.Transform.Analyze.ClausePatterns` uses (build node-level
  # `Candidate.InPlace`s, attach a candidate list under `:mutare`); public for it.
  def build_candidates(node, muts) do
    range = NodeRange.get(node)

    Enum.map(muts, fn {mutator, mutated, note} ->
      %Candidate.InPlace{
        mutator: mutator,
        original: node,
        mutated: mutated,
        range: range,
        note: note
      }
    end)
  end

  def put_candidates({form, meta, args}, candidates),
    do: {form, [{:mutare, candidates} | meta], args}

  @doc """
  Append candidates to a node's `:mutare` metadata, **preserving** any already there (so an
  operator candidate keeps its id before a return/condition one at a shared node). The
  candidate list is built by `build_fun.(range)` from `raw`'s source range — kept at the call
  site because the condition and return-tail descents build different `Candidate` structs. The
  node is returned unchanged when it carries no metadata or `raw` can't be ranged (no mutant
  recorded). The shared half of `Analyze.Conditions`/`Analyze.Returns`' tail attachment.
  """
  @spec append_candidates(Macro.t(), Macro.t(), (map() -> [struct()])) :: Macro.t()
  # mutare:ignore[guard_drop] equivalent — a `{form, meta, args}` AST node always carries keyword-list meta, so the guard never excludes a real node.
  def append_candidates({form, meta, args} = node, raw, build_fun) when is_list(meta) do
    case NodeRange.get(raw) do
      %{} = range ->
        existing = Keyword.get(meta, :mutare, [])
        {form, Keyword.put(meta, :mutare, existing ++ build_fun.(range)), args}

      _ ->
        node
    end
  end

  # mutare:ignore[clause_drop] equivalent — Sourceror wraps every scalar/tuple/list node in a `:__block__` 3-tuple, so the head matches every real node; this fallback is unreachable for valid input.
  def append_candidates(node, _raw, _build_fun), do: node

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
      {key, _value} -> block_key?(key)
      _other -> false
    end)
  end

  # A module-level macro-with-block (`schema do … end`): init args are compile-time
  # (`:scaffold`), and the block keyword's `do`/… body is analyzed as **`:runtime`**
  # because an *unknown* DSL macro may `unquote` it into generated function bodies (so a
  # literal there could be a real runtime value). A **registered known macro** overrides
  # that guess per argument: a `:skip` arg (`{DSL, :schema, 1, :skip}`) is left **raw** —
  # no descent, no mutation — so core never mutates inside an opaque DSL block body and
  # can't poison the DSL the registry was meant to exclude. Only `:skip` is honoured here:
  # the other treatments are compile-time-context-sensitive and the default path already
  # does the right thing (`:expression` *is* the runtime-body guess, `:pattern` has no
  # module-level use). `Resolve` stamps `meta[:mutare_macro]` for bare-imported and
  # qualified forms alike, so both route.
  def analyze_module_macro_block({form, meta, args}, mutators) do
    routing = macro_routing(meta)
    {init, [last]} = Enum.split(args, -1)

    init =
      init
      |> Enum.with_index()
      |> Enum.map(fn {arg, i} ->
        if skip_arg?(routing, i), do: arg, else: analyze(arg, :scaffold, mutators)
      end)

    last =
      if skip_arg?(routing, length(args) - 1),
        do: last,
        else: analyze_module_macro_block_arg(last, mutators)

    {form, meta, init ++ [last]}
  end

  @doc """
  The name (form atom) to tag a module-level block macro's mutation sites with, for
  poison recovery — but only when the macro is **unknown** (no known-macro routing).

  An unknown DSL block is mutated on the guess that it is unquoted into a function;
  if the injected selector `case` is illegal in the DSL it poisons the single build,
  and `Mutare.Runner` skips the whole macro by this name (see `Mutare.Site`). A
  *registered* macro (`routing != nil`) returns `nil` — the user's `:macros` choice
  (mutate or `:skip`) is honoured and never auto-skipped. Only meaningful for a node
  that `module_macro_block_statement?/1` already accepted.
  """
  @spec unknown_block_macro_name(Macro.t()) :: atom() | nil
  def unknown_block_macro_name({form, meta, _args}) do
    if macro_routing(meta) == nil, do: form, else: nil
  end

  # Whether the macro argument at position `i` is routed `:skip` (a known macro's opaque
  # arg). No stamp (`nil`) or a position past the routing list is the `:expression` default.
  defp skip_arg?(nil, _i), do: false
  defp skip_arg?(routing, i), do: Enum.at(routing, i, :expression) == :skip

  defp analyze_module_macro_block_arg(kw, mutators) when is_list(kw) do
    Enum.map(kw, fn
      {key, value} ->
        context = if block_key?(key), do: :runtime, else: :scaffold
        {key, analyze(value, context, mutators)}

      other ->
        analyze(other, :scaffold, mutators)
    end)
  end

  defp block_key?(key), do: AST.key_atom(key) in @block_keys

  @doc """
  Whether `key` names a `:do` block. Shared by clause-block routing
  (`normalize_clause_blocks/1`, `analyze_do_blocks/2`), the trailing-keyword `do:`
  guard, and `Mutare.Transform.Analyze.Returns` (which classifies the `:do` tail as a
  return path) — the one home for the predicate rather than reclassifying the atom.
  """
  @spec do_key?(Macro.t()) :: boolean()
  def do_key?(key), do: AST.key_atom(key) == :do

  @doc """
  Whether `key` names a try-style clause block whose tails are *return paths*
  (`rescue`/`catch`/`else`) — distinct from `:after`, whose value `try` discards. Analyze
  owns this canonical return-path set; `Mutare.Transform.Analyze.Returns` shares the one
  predicate for its tail classification rather than reclassifying the same atoms.
  """
  @spec clause_block_key?(Macro.t()) :: boolean()
  def clause_block_key?(key), do: AST.key_atom(key) in @clause_block_keys

  # === shared helpers ========================================================

  # The liveness a child *body* inherits from its construct. A `:scaffold`
  # (compile-time metaprogramming) parent keeps its child bodies compile-time too —
  # so a `case`/`cond`/`with`/`fn` that wraps a `def` at module level does not mutate
  # its own arms — while every other context yields an ordinary runtime body. The one
  # construct that flips a `:scaffold` descent back to `:runtime` is a `def`/`defp`
  # body, done explicitly in its own clause (a generated function's body *is* runtime).
  defp body_context(:scaffold), do: :scaffold
  defp body_context(_), do: :runtime

  defp function_ref?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp function_ref?({{:., _, _}, _meta, args}) when is_list(args), do: true
  defp function_ref?(_), do: false

  defp integer_literal?(n) when is_integer(n), do: true
  defp integer_literal?({:__block__, _meta, [n]}) when is_integer(n), do: true
  defp integer_literal?(_), do: false
end
