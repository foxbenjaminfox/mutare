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
  alias Mutare.Mutator.Spec
  alias Mutare.Transform.{Candidate, Names, NodeRange, PatternStructure, Tag}

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

  # Data/structural forms that reach the generic runtime clause but are *not* calls,
  # so a keyword-list-shaped trailing element (a `%{a: 1}` pair list, a `{a, [b: 1]}`
  # tuple's last element) is never mistaken for a call's trailing options (`call_form?/1`).
  @non_call_forms [:{}, :%{}, :<<>>, :__block__, :__aliases__]

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

  # `&fun/arity` capture: the `/` is arity, not division — pruned. Anything else
  # under `&` (e.g. `& &1 / 2`) keeps mutating.
  defp analyze({:&, _meta, [{:/, _smeta, [left, right]}]} = node, context, mutators) do
    if function_ref?(left) and integer_literal?(right),
      do: node,
      else: recurse(node, context, mutators)
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
    annotated_kw = annotate_returns(analyzed_kw, body_kw, mutators)
    {vis, meta, [head, host_def_rescue(annotated_kw, body_kw, mutators)]}
  end

  # bitstring: each segment's value keeps the surrounding context; the spec side
  # is excluded except for `size(expr)` args (`analyze_segment/3`). In a runtime
  # body the `<<…>>` node is *also* offered to mutators (BitstringLiteral collapses
  # it to `<<>>`) — built from the raw node so the diff renders the author's
  # literal, with the analyzed segments kept underneath so their own selectors stay
  # reachable. In a pattern (or any non-runtime context) it is only descended.
  defp analyze({:<<>>, meta, segments} = node, :runtime, mutators) do
    analyzed = {:<<>>, meta, Enum.map(segments, &analyze_segment(&1, :runtime, mutators))}
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
    init = Enum.map(init, &analyze_statement(&1, mutators))
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

    if hoist_if?(analyzed_condition, mutators) do
      hoist_if(form, meta, condition, analyzed_condition, analyzed_body, mutators)
    else
      analyzed_condition = finish_condition(analyzed_condition, condition, mutators)
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

    case case_clause_candidates(clauses, mutators) do
      [] -> analyzed
      candidates -> put_case_candidates(analyzed, candidates)
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
    {clauses, rebuild} = receive_do_clauses(blocks, meta)
    attach_clause_pattern_candidates(node, clauses, rebuild, mutators)
  end

  defp analyze({:fn, meta, clauses} = node, :runtime, mutators) when is_list(clauses) do
    rebuild = fn new -> {:fn, meta, new} end
    attach_clause_pattern_candidates(node, clauses, rebuild, mutators)
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
        rescue_type_candidates(blocks, meta, mutators)

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
    {:|>, meta, [analyze_piped_value(lhs, rhs, mutators), analyze_pipe_stage(rhs, mutators)]}
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
      clauses = Enum.map(clauses, &analyze_statement(&1, mutators))
      rebuilt = {:with, meta, clauses ++ [analyze(body_kw, :runtime, mutators)]}
      offer(rebuilt, node, mutators)
    else
      node |> offer(node, mutators) |> recurse_runtime(mutators, :unpiped)
    end
  end

  # === redundancy suppression: equivalent sibling mutants ====================
  #
  # Four shapes where one family's mutant is *guaranteed equivalent* to another's, so
  # the redundant one is dropped. The shared move is the same as `not in` always did:
  # descend operands (so their literals still mutate) but do **not** *offer* the
  # inner/redundant node — only the outer. Dropping a candidate here (rather than
  # post-hoc) leaves no id/site/selector, exactly like the other positive suppressions.
  #
  # (1) **Double negation** `not not x` / `!!x` — the **same** operator twice. Logical
  # strips the outer *and* the inner to the identical single-negation (`not x` / `!x`),
  # and Conditional on the inner (`not true`/`not false`) duplicates the outer's
  # `true`/`false`. Same operator only: a mixed `not !x` could differ on a non-boolean
  # operand (`not x` raises where `!x` coerces to `false`), so it is left fully offered.
  defp analyze({neg, meta, [{neg, inner_meta, [operand]}]} = node, :runtime, mutators)
       when neg in [:not, :!] do
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
       when neg in [:not, :!] do
    inner = {:in, in_meta, [analyze(left, :runtime, mutators), analyze_in_rhs(right, mutators)]}
    offer({neg, meta, [inner]}, node, mutators)
  end

  # (3) **`not`/`!` over an equality operator** (`==`/`!=`/`===`/`!==`) — case (2)
  # generalised: each equality operator is its own exact polarity complement, so
  # Relational's flip under the negation ≡ Logical's strip, and Conditional on the inner
  # ≡ the outer's `true`/`false`. **Only** the equality operators qualify: the ordering
  # operators (`<`/`>`/`<=`/`>=`) mutate to a boundary/reversal that survives negation as
  # a genuinely new mutant (`!(a >= b)` ≡ `a < b`, ≠ the strip `a > b`), so they are
  # left offered.
  defp analyze({neg, meta, [{op, op_meta, [left, right]}]} = node, :runtime, mutators)
       when neg in [:not, :!] and op in [:==, :!=, :===, :!==] do
    inner = {op, op_meta, [analyze(left, :runtime, mutators), analyze(right, :runtime, mutators)]}
    offer({neg, meta, [inner]}, node, mutators)
  end

  # (4) **A bare `x in [list]`** — offer the `in` node normally (Conditional `true`/`false`,
  # Relational → `not in`), but its RHS list literal is List-suppressed: collapsing it to
  # `[]` makes `x in []` ≡ `false`, which Conditional already produces on the `in` node.
  defp analyze({:in, meta, [left, right]} = node, :runtime, mutators) do
    rebuilt = {:in, meta, [analyze(left, :runtime, mutators), analyze_in_rhs(right, mutators)]}
    offer(rebuilt, node, mutators)
  end

  # a generic runtime node: build the candidate from the raw node (so `original`
  # keeps un-annotated children), then descend into the children. A sigil is offered
  # as a whole (so the sigil mutators — Regex/Charlist/DateTime — match it), then
  # descended *surgically* via `descend_sigil/2`: its content `<<>>` segments are
  # analyzed (so an interpolated expression `~r/a#{b}c/` still mutates `b`), but the
  # content `<<>>` *wrapper* itself is never offered — collapsing a sigil's content
  # (BitstringLiteral) or splicing a selector into it is illegal.
  #
  # A call stamped a **known macro** (`meta[:mutare_macro]`, set by
  # `Mutare.Transform.Resolve` from `Mutare.Macros`) routes its arguments by their
  # declared treatment instead of the default all-runtime descent — so a pattern
  # argument (`match?`/`destructure`) isn't mutated in place and an opaque DSL body
  # (`Ecto.Query.from`) is left raw — while the whole node is still offered to
  # mutators (a library's custom mutator fires on it). Every other (non-macro) node
  # falls through to the existing offer/descend below, unchanged.
  defp analyze({form, meta, _args} = node, :runtime, mutators) do
    case macro_routing(meta) do
      nil ->
        node = offer(node, node, mutators)

        if sigil?(form),
          do: descend_sigil(node, mutators),
          else: recurse_runtime(node, mutators, :unpiped)

      routing ->
        analyze_known_macro(node, routing, mutators)
    end
  end

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

  defp drop_empty_collection_candidates({form, meta, args} = node) when is_list(meta) do
    case Keyword.get(meta, :mutare) do
      nil -> node
      cands -> {form, Keyword.put(meta, :mutare, Enum.reject(cands, &empty_collection?/1)), args}
    end
  end

  defp drop_empty_collection_candidates(node), do: node

  defp empty_collection?(%Candidate.InPlace{mutator: spec, mutated: mutated}),
    do: Mutator.empty_collection?(spec, mutated)

  defp empty_collection?(_candidate), do: false

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
  defp analyze_pipe_stage({_form, meta, args} = node, mutators) when is_list(args) do
    case macro_routing(meta) do
      nil ->
        node = offer(node, node, mutators, %{pipe_mode: :piped})
        recurse_runtime(node, mutators, :piped)

      routing ->
        analyze_known_macro(node, routing, mutators, %{pipe_mode: :piped})
    end
  end

  defp analyze_pipe_stage(other, mutators), do: analyze(other, :runtime, mutators)

  # === known macros ==========================================================

  # The per-argument routing stamped on a call by `Mutare.Transform.Resolve` when it
  # resolves to a known macro (`Mutare.Macros`), or `nil` for an ordinary call.
  defp macro_routing(meta) when is_list(meta), do: Keyword.get(meta, :mutare_macro)
  defp macro_routing(_meta), do: nil

  # Analyze a known-macro call: offer the *whole* node to mutators (so a custom mutator
  # registered for the macro still fires — e.g. an Ecto query mutator on `from(...)`),
  # then route each *visible* argument by its declared treatment instead of the default
  # all-runtime descent. `context` carries the pipe flag (so a pipe-aware custom mutator sees
  # the effective arity); `mark_call_option_keys/1` still runs (harmless for `:skip`/`:pattern`
  # args, which carry no candidates; correct for `:expression` args, preserving option-key gating).
  defp analyze_known_macro(node, routing, mutators, context \\ %{pipe_mode: :unpiped}) do
    {form, meta, args} = offer(node, node, mutators, context)
    mark_call_option_keys({form, meta, route_macro_args(args, routing, mutators)})
  end

  # Route each argument by its treatment. A position past the routing list defaults to
  # `:expression`.
  defp route_macro_args(args, routing, mutators) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, i} ->
      route_macro_arg(arg, Enum.at(routing, i, :expression), mutators)
    end)
  end

  # Route one macro argument by its declared treatment — shared by the visible-arg routing
  # (`route_macro_args/3`) and the piped-value reach-back (`analyze_piped_value/3`), so the
  # piped LHS is treated identically to a written first argument: `:expression` → ordinary
  # runtime (mutate); `:pattern`/`:binding_pattern` → a match context (descend for nested
  # runtime escapes, never mutate the pattern *in place*); `:skip` → leave the argument **raw**
  # (no descent, no mutation — an opaque value the macro may accept even though it is neither a
  # valid expression nor a valid pattern). `:binding_pattern` routes identically to `:pattern`
  # here; its *extra* structural-mutant offering is delivered separately (the macro call sits in
  # a value-discarded position — see `binding_pattern_macro/1` / `attach_macro_pattern_candidates/4`).
  defp route_macro_arg(arg, :skip, _mutators), do: arg

  defp route_macro_arg(arg, treatment, mutators) when treatment in [:pattern, :binding_pattern],
    do: analyze(arg, :pattern, mutators)

  defp route_macro_arg(arg, _expression, mutators), do: analyze(arg, :runtime, mutators)

  # The left side of a `|>` whose right side is a known macro: the piped value is the macro's
  # *effective argument 0*, so it inherits position 0's treatment, which `Resolve` recorded on
  # the stage as `:mutare_macro_piped` (stamped only when it isn't the `:expression` default —
  # so the common runtime LHS carries no stamp and falls through unchanged). Routing it through
  # the same `route_macro_arg/3` as the visible args keeps the piped position in lockstep with
  # a written first argument: a `1 |> match?(1)` LHS routes as `:pattern`, a `:skip` macro's LHS
  # is left raw, and any other LHS stays ordinary runtime.
  defp analyze_piped_value(lhs, {_form, rhs_meta, _args}, mutators) when is_list(rhs_meta) do
    case Keyword.get(rhs_meta, :mutare_macro_piped) do
      nil -> analyze(lhs, :runtime, mutators)
      treatment -> route_macro_arg(lhs, treatment, mutators)
    end
  end

  defp analyze_piped_value(lhs, _rhs, mutators), do: analyze(lhs, :runtime, mutators)

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
  defp analyze_for_arg(arg, mutators), do: analyze_match_statement(arg, mutators)

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
  # node) — so the analyzer no longer needs to know which positions are "owned". `pipe_mode` is
  # unused now but kept so the three call sites need not change.
  defp recurse_runtime({_form, _meta, args} = node, mutators, _pipe_mode) when is_list(args) do
    node |> recurse(:runtime, mutators) |> mark_call_option_keys()
  end

  defp recurse_runtime(node, mutators, _pipe_mode), do: recurse(node, :runtime, mutators)

  # === call-option keys ======================================================

  # When this runtime node is a *call* whose final argument is a keyword list
  # (`foo(x, timeout: 5, retries: 3)` — the trailing-keyword sugar, the same AST as
  # an explicit `[timeout: 5, …]` last arg), tag each of that list's *key* candidates
  # `call_option_key?`. Emission (`Transform.gate_candidates/1`) then drops a tagged
  # candidate whose mutator was configured `{Module, call_option_keys: false}` — leaving
  # that option name unmutated while its value still mutates. A data/structural form
  # (`%{}`, a 3+-tuple) is not a call, so its trailing element is left alone; only the
  # call context (known here) can make this distinction. The marking is shallow: nested
  # maps/lists inside an option *value* keep their own keys.
  defp mark_call_option_keys({form, meta, args} = node) when is_list(args) and args != [] do
    last = List.last(args)

    if call_form?(form) and keyword_list_shaped?(last) do
      {init, [_last]} = Enum.split(args, -1)
      {form, meta, init ++ [tag_option_keys(last)]}
    else
      node
    end
  end

  defp mark_call_option_keys(node), do: node

  # A genuine call: a remote `Foo.bar(…)` (`{:., …}` form) or a local/operator call (an
  # atom form), minus the data/structural forms that also reach the generic runtime
  # clause and could carry a keyword-list-shaped trailing element without being a call.
  defp call_form?({:., _meta, _args}), do: true
  defp call_form?(form) when is_atom(form), do: form not in @non_call_forms
  defp call_form?(_form), do: false

  defp keyword_list_shaped?(list) when is_list(list) and list != [],
    do: Enum.all?(list, &match?({_k, _v}, &1))

  defp keyword_list_shaped?(_other), do: false

  defp tag_option_keys(kw) do
    Enum.map(kw, fn
      {key, value} -> {tag_option_key(key), value}
      other -> other
    end)
  end

  # Stamp `call_option_key?` onto each candidate already attached to a key node. A key
  # with no candidates (a block key, or a key no mutator matched) is left untouched.
  defp tag_option_key({form, meta, kargs} = key) when is_list(meta) do
    case Keyword.get(meta, :mutare) do
      nil ->
        key

      candidates ->
        {form, Keyword.put(meta, :mutare, Enum.map(candidates, &as_call_option/1)), kargs}
    end
  end

  defp tag_option_key(key), do: key

  defp as_call_option(%Candidate.InPlace{} = c), do: %{c | call_option_key?: true}
  defp as_call_option(other), do: other

  # Generic structural descent over every Sourceror node shape, re-analyzing the
  # children in the same context.
  defp recurse({form, meta, args}, context, mutators) when is_list(args),
    do: {form, meta, Enum.map(args, &analyze(&1, context, mutators))}

  defp recurse({form, meta, arg}, _context, _mutators), do: {form, meta, arg}

  defp recurse({left, right}, context, mutators),
    do: {analyze(left, context, mutators), analyze(right, context, mutators)}

  defp recurse(list, context, mutators) when is_list(list),
    do: Enum.map(list, &analyze(&1, context, mutators))

  defp recurse(other, _context, _mutators), do: other

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

    case rescue_type_candidates(raw_body_kw, try_meta, mutators) do
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
          do: analyze_condition(cond_node, mutators),
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

  # === clause-list pattern mutation (case / receive / fn) ====================

  # --- case: per-clause tuple-the-scrutinee (Candidate.CaseClause) -----------

  # One `Candidate.CaseClause` per {clause, mutation} for a `case`. A `case` clause has a
  # single pattern (one subject); each clause admits guard-operator swaps, pattern-literal
  # swaps, and structural pattern rewrites. The candidate carries the mutant clause's
  # *pattern* and *guard* (a literal/structure mutation mutates the pattern and keeps the
  # original guard; a guard mutation mutates the guard and keeps the original pattern) plus
  # the clause's *raw body* — everything `Mutare.Transform.emit_case_pattern_site/3` needs
  # to build the gated mutant clause. The originals come from the (already-analyzed) case
  # node at emit; only the mutants come from here.
  defp case_clause_candidates(clauses, mutators) do
    structural = PatternStructure.mutators(mutators)

    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      case case_clause_parts(clause) do
        nil ->
          []

        {pattern, guard, body, used} ->
          guard_clause_candidates(index, pattern, guard, body, mutators) ++
            literal_clause_candidates(index, pattern, guard, body, mutators) ++
            structural_clause_candidates(index, pattern, guard, body, used, structural)
      end
    end)
  end

  # A `case` clause's single pattern, its guard (or `nil`), its body, and the names read in
  # guard+body (the wildcard family's `used_outside`). Handles the guarded form (the guard
  # is the last `when` arg; a `when a when b` OR-guard is a single nested `when` node) and
  # the unguarded form. Anything with more than one pattern (not a `case` clause) → `nil`.
  defp case_clause_parts({:->, _meta, [[{:when, _wm, when_args}], body]})
       when length(when_args) >= 2 do
    case Enum.split(when_args, -1) do
      {[pattern], [guard]} -> {pattern, guard, body, PatternStructure.used_names([guard, body])}
      _ -> nil
    end
  end

  defp case_clause_parts({:->, _meta, [[pattern], body]}),
    do: {pattern, nil, body, PatternStructure.used_names([body])}

  defp case_clause_parts(_clause), do: nil

  defp guard_clause_candidates(_index, _pattern, nil, _body, _mutators), do: []

  defp guard_clause_candidates(index, pattern, guard, body, mutators) do
    {tagged_guard, {_next, targets}} = Tag.guard_targets(guard, {0, []}, mutators)

    Tag.expand_targets(targets, fn tag, original, mutator, mutated, range ->
      %Candidate.CaseClause{
        clause_index: index,
        mutator: mutator,
        mutant_pattern: pattern,
        mutant_guard: Tag.replace_tag(tagged_guard, tag, mutated),
        raw_body: body,
        original: original,
        mutated: mutated,
        range: range
      }
    end)
  end

  defp literal_clause_candidates(index, pattern, guard, body, mutators) do
    {tagged_pattern, {_next, targets}} = Tag.pattern_literal_targets(pattern, {0, []}, mutators)

    Tag.expand_targets(targets, fn tag, original, mutator, mutated, range ->
      %Candidate.CaseClause{
        clause_index: index,
        mutator: mutator,
        mutant_pattern: Tag.replace_tag(tagged_pattern, tag, mutated),
        mutant_guard: guard,
        raw_body: body,
        original: original,
        mutated: mutated,
        range: range
      }
    end)
  end

  defp structural_clause_candidates(_index, _pattern, _guard, _body, _used, []), do: []

  defp structural_clause_candidates(index, pattern, guard, body, used, structural) do
    structural_mutations(pattern, used, structural, fn mutator, mutated, range ->
      %Candidate.CaseClause{
        clause_index: index,
        mutator: mutator,
        mutant_pattern: mutated,
        mutant_guard: guard,
        raw_body: body,
        original: pattern,
        mutated: mutated,
        range: range
      }
    end)
  end

  # Run the structural (swap/wildcard) discovery on one clause pattern, skipping the
  # pattern when Sourceror can't range it (no focused diff possible — the same guard the
  # tagged path applies via `Tag.expand_targets/2`). Each `{mutator, mutated}` becomes a
  # candidate via `build.(mutator, mutated, range)`. Shared by the `case` (`CaseClause`)
  # and `receive`/`fn` (`CasePattern`) paths, which differ only in the struct they build.
  defp structural_mutations(pattern, used, structural, build) do
    case NodeRange.get(pattern) do
      %{} = range ->
        pattern
        |> PatternStructure.node_mutations(used, structural)
        |> Enum.map(fn {mutator, mutated} -> build.(mutator, mutated, range) end)

      _ ->
        []
    end
  end

  defp put_case_candidates({form, meta, args}, candidates),
    do: {form, [{:mutare_case, candidates} | meta], args}

  # --- receive / fn: whole-construct selector (Candidate.CasePattern) --------

  # Analyze the construct normally (bodies/subject mutate), then attach the clause-pattern
  # candidates so emission hosts them in the same in-place selector that wraps the whole
  # node. `clauses` is the construct's `->` clause list; `rebuild_fn` rebuilds the whole node
  # from a mutated clause list (the only thing that differs across receive/fn). The
  # node-level mutator offer is preserved for parity with the generic runtime clause (a
  # custom mutator matching the whole node; built-ins match none).
  defp attach_clause_pattern_candidates(node, clauses, rebuild_fn, mutators) do
    analyzed = recurse(node, :runtime, mutators)

    candidates =
      build_candidates(node, Mutator.mutations(node, mutators)) ++
        clause_list_candidates(clauses, rebuild_fn, mutators)

    case candidates do
      [] -> analyzed
      _ -> put_candidates(analyzed, candidates)
    end
  end

  # The receive's `do` clauses plus a rebuilder that swaps them back into `blocks`
  # (preserving an `after` block). An absent `do` (shouldn't happen) → no clauses and an
  # identity rebuild, so the construct is still analyzed but offers no pattern mutants.
  defp receive_do_clauses(blocks, meta) do
    case Enum.find(blocks, fn {key, _value} -> AST.key_atom(key) == :do end) do
      {_do_key, clauses} when is_list(clauses) ->
        rebuild = fn new ->
          new_blocks =
            Enum.map(blocks, fn {key, value} ->
              if AST.key_atom(key) == :do, do: {key, new}, else: {key, value}
            end)

          {:receive, meta, [new_blocks]}
        end

        {clauses, rebuild}

      _ ->
        {[], fn _new -> {:receive, meta, [blocks]} end}
    end
  end

  # For each clause: structural pattern rewrites + pattern-literal swaps at each pattern
  # position, plus guard-operator swaps. Each builds a `Candidate.CasePattern` whose
  # `replacement` is the whole construct with just that one clause's pattern/guard changed
  # (raw clauses → first-order, no nested selectors, like a lifted mutant clause). The diff
  # stays focused on the single changed pattern/literal/guard-operator (always rangeable).
  defp clause_list_candidates(clauses, rebuild_fn, mutators) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      replace_clause = fn new_clause ->
        rebuild_fn.(List.replace_at(clauses, index, new_clause))
      end

      clause_pattern_candidates(clause, replace_clause, mutators)
    end)
  end

  defp clause_pattern_candidates(clause, replace_clause, mutators) do
    structural = PatternStructure.mutators(mutators)

    case clause_patterns(clause) do
      nil ->
        []

      {patterns, used} ->
        pattern_cands =
          patterns
          |> Enum.with_index()
          |> Enum.flat_map(
            &position_candidates(&1, clause, replace_clause, used, mutators, structural)
          )

        pattern_cands ++ clause_guard_candidates(clause, replace_clause, mutators)
    end
  end

  defp position_candidates({pattern, pos}, clause, replace_clause, used, mutators, structural) do
    structural_position_candidates(pattern, pos, clause, replace_clause, used, structural) ++
      literal_position_candidates(pattern, pos, clause, replace_clause, mutators)
  end

  defp structural_position_candidates(pattern, pos, clause, replace_clause, used, structural) do
    structural_mutations(pattern, used, structural, fn mutator, mutated, range ->
      %Candidate.CasePattern{
        mutator: mutator,
        original: pattern,
        mutated: mutated,
        replacement: replace_clause.(put_clause_pattern_at(clause, pos, mutated)),
        range: range
      }
    end)
  end

  defp literal_position_candidates(pattern, pos, clause, replace_clause, mutators) do
    {tagged_pattern, {_next, targets}} = Tag.pattern_literal_targets(pattern, {0, []}, mutators)

    Tag.expand_targets(targets, fn tag, original, mutator, mutated, range ->
      mutated_pattern = Tag.replace_tag(tagged_pattern, tag, mutated)

      %Candidate.CasePattern{
        mutator: mutator,
        original: original,
        mutated: mutated,
        replacement: replace_clause.(put_clause_pattern_at(clause, pos, mutated_pattern)),
        range: range
      }
    end)
  end

  defp clause_guard_candidates(clause, replace_clause, mutators) do
    case clause_guard(clause) do
      nil ->
        []

      guard ->
        {tagged_guard, {_next, targets}} = Tag.guard_targets(guard, {0, []}, mutators)

        Tag.expand_targets(targets, fn tag, original, mutator, mutated, range ->
          mutated_guard = Tag.replace_tag(tagged_guard, tag, mutated)

          %Candidate.CasePattern{
            mutator: mutator,
            original: original,
            mutated: mutated,
            replacement: replace_clause.(put_clause_guard(clause, mutated_guard)),
            range: range
          }
        end)
    end
  end

  # A clause's pattern positions plus the names read in its guard/body (the `used_outside`
  # set the wildcard family needs). A guard wraps *all* patterns: `[{:when, _, [p1, …, pN,
  # guard]}]`. Unguarded, the LHS list *is* the patterns (one for case/receive, N for fn).
  # Anything else (a malformed/guard-only LHS) → `nil` (skip). Each pattern is mutated
  # independently, so a duplicate variable *across* fn arguments (`fn x, x -> …`) isn't seen
  # — rare, and within-argument duplicates (`fn {x, x} -> …`) still are.
  defp clause_patterns({:->, _meta, [[{:when, _wm, when_args}], body]})
       when length(when_args) >= 2 do
    {patterns, [guard]} = Enum.split(when_args, -1)
    {patterns, PatternStructure.used_names([guard, body])}
  end

  defp clause_patterns({:->, _meta, [lhs_list, body]}) when is_list(lhs_list) do
    if Enum.any?(lhs_list, &match?({:when, _, _}, &1)),
      do: nil,
      else: {lhs_list, PatternStructure.used_names([body])}
  end

  defp clause_patterns(_clause), do: nil

  # The guard of a `->` clause (its last `when` arg), or `nil` when unguarded.
  defp clause_guard({:->, _meta, [[{:when, _wm, when_args}], _body]})
       when length(when_args) >= 2,
       do: List.last(when_args)

  defp clause_guard(_clause), do: nil

  # Replace pattern position `pos` of a clause's head with `mutated`, re-wrapping a `when`
  # guard if present (the guard is always the last `when` arg).
  defp put_clause_pattern_at({:->, meta, [[{:when, wm, when_args}], body]}, pos, mutated)
       when length(when_args) >= 2 do
    {patterns, [guard]} = Enum.split(when_args, -1)
    {:->, meta, [[{:when, wm, List.replace_at(patterns, pos, mutated) ++ [guard]}], body]}
  end

  defp put_clause_pattern_at({:->, meta, [lhs_list, body]}, pos, mutated) do
    {:->, meta, [List.replace_at(lhs_list, pos, mutated), body]}
  end

  # Replace a guarded `->` clause's guard (the last `when` arg) with `new_guard`.
  defp put_clause_guard({:->, meta, [[{:when, wm, when_args}], body]}, new_guard)
       when length(when_args) >= 2 do
    {patterns, [_guard]} = Enum.split(when_args, -1)
    {:->, meta, [[{:when, wm, patterns ++ [new_guard]}], body]}
  end

  # --- try: rescue narrowing + clause drop (CasePattern / RescueDrop) ---------

  # The `rescue` mutations: per-clause type-list narrowings (`Candidate.CasePattern`, each
  # `replacement` the whole `try` with one clause's list shrunk) plus whole-clause drops
  # (`Candidate.RescueDrop`, the `try` with one clause removed). Gated on
  # `Mutare.Mutators.RescueType` being enabled.
  defp rescue_type_candidates(blocks, meta, mutators) do
    case Spec.find(mutators, Mutare.Mutators.RescueType) do
      nil -> []
      spec -> rescue_clause_candidates(blocks, meta, spec)
    end
  end

  defp rescue_clause_candidates(blocks, meta, spec) do
    case Enum.find(blocks, fn {key, _v} -> AST.key_atom(key) == :rescue end) do
      {_rescue_key, clauses} when is_list(clauses) ->
        rebuild_try = fn new_clauses ->
          new_blocks =
            Enum.map(blocks, fn {key, v} ->
              if AST.key_atom(key) == :rescue, do: {key, new_clauses}, else: {key, v}
            end)

          {:try, meta, [new_blocks]}
        end

        narrowings =
          clauses
          |> Enum.with_index()
          |> Enum.flat_map(&rescue_type_drops(&1, clauses, rebuild_try, spec))

        narrowings ++ rescue_clause_drops(clauses, rebuild_try, spec)

      _ ->
        []
    end
  end

  # The whole-clause counterpart of `rescue_type_drops/4`: drop each `rescue` branch in turn,
  # `replacement` being the `try` with that one clause removed. This covers the idiomatic
  # multi-branch shape `rescue e in A -> …; e in B -> …` — where each branch catches a single
  # type, so there is no list for `rescue_type_drops` to narrow — by asking the same question one
  # level up (is each branch's handling relied on?). Offered **only when ≥2 clauses are present**
  # (a `try` can't carry an empty `rescue`), so every result still compiles; the head shape is
  # irrelevant (a bare-variable catch-all clause is droppable too). The diff is a `:delete` of the
  # dropped clause (`Candidate.RescueDrop`).
  defp rescue_clause_drops(clauses, rebuild_try, spec) when length(clauses) >= 2 do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      case NodeRange.get(clause) do
        %{} = range ->
          [
            %Candidate.RescueDrop{
              mutator: spec,
              dropped: clause,
              replacement: rebuild_try.(List.delete_at(clauses, index)),
              range: range
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp rescue_clause_drops(_clauses, _rebuild_try, _spec), do: []

  # One rescue clause — a `CasePattern` per type-drop, whose `replacement` is the whole `try`
  # rebuilt with this clause's exception-type list narrowed. Both list-bearing shapes are
  # mutated: `var in [t1, ..., tn]` (bound) and a bare `[t1, ..., tn]` head (no binding) —
  # `narrowable_types/1` returns the type list and a head-rebuilder for each. The diff
  # (`original`/`mutated`/`range`) is the clause **head** before/after, so the bound form shows
  # `var in [A, B]`→`var in [A]` and the bare form `[A, B]`→`[A]`. The non-list shapes (`var`,
  # `Type`, `var in Single`) yield nothing.
  defp rescue_type_drops({{:->, cmeta, [[head], body]}, index}, clauses, rebuild_try, spec) do
    with {types, rebuild_head} <- narrowable_types(head),
         %{} = range <- NodeRange.get(head) do
      types
      |> Mutare.Mutators.RescueType.drops()
      |> Enum.map(fn kept ->
        mutated_head = rebuild_head.(kept)
        mutated_clause = {:->, cmeta, [[mutated_head], body]}

        %Candidate.CasePattern{
          mutator: spec,
          original: head,
          mutated: mutated_head,
          replacement: rebuild_try.(List.replace_at(clauses, index, mutated_clause)),
          range: range
        }
      end)
    else
      _ -> []
    end
  end

  defp rescue_type_drops(_clause_indexed, _clauses, _rebuild_try, _spec), do: []

  # A rescue clause head's exception-type list plus a closure to rebuild the head from a
  # narrowed list, or `nil` when the head holds no mutatable list. Two list-bearing shapes:
  # `var in [t1, ..., tn]` (keep the `in` binding) and a bare `[t1, ..., tn]` head (a valid
  # rescue form with no binding — narrow the list directly). `rescue_types/1` does the list
  # extraction (and `:__block__`-aware rebuild) for both, returning `nil` for a single alias
  # (`var in Single` / `Type`) or a bare variable, so those fall through to no mutation.
  defp narrowable_types({:in, imeta, [var, types_node]}) do
    case rescue_types(types_node) do
      {wrap, types} -> {types, fn kept -> {:in, imeta, [var, wrap.(kept)]} end}
      nil -> nil
    end
  end

  defp narrowable_types(types_node) do
    case rescue_types(types_node) do
      {wrap, types} -> {types, wrap}
      nil -> nil
    end
  end

  # The exception-type list inside a rescue head's list node, plus a closure to rebuild the
  # node from a narrowed list. Sourceror wraps the list literal in a `:__block__` (preserved so
  # the mutant renders cleanly); a bare list is handled too. A non-list (a single alias) → `nil`.
  defp rescue_types({:__block__, bmeta, [list]}) when is_list(list),
    do: {fn new -> {:__block__, bmeta, [new]} end, list}

  defp rescue_types(list) when is_list(list), do: {fn new -> new end, list}
  defp rescue_types(_node), do: nil

  # === match (`=`) pattern structure =========================================

  # A value-discarded position that may host a rewriteable pattern — a non-final statement of
  # a runtime block (the `:__block__` clause) or a `with` clause. Two statement shapes offer a
  # pattern to the structural families: a `=` match (its LHS → `MatchPattern`), and a
  # **binding-escaping known macro** call (`destructure([x, y], v)`, declared
  # `:binding_pattern`) whose pattern arg → `MacroPattern` — its bindings escape exactly like a
  # `=`'s, so the same tuple-re-export delivery applies. Every other statement analyzes as an
  # ordinary runtime expression. (A `for` qualifier uses `analyze_match_statement/2` instead:
  # a bare macro call there is a *filter*, not value-discarded — only the `=` shape is safe.)
  defp analyze_statement({:=, _meta, _operands} = match, mutators),
    do: analyze_match_statement(match, mutators)

  defp analyze_statement(node, mutators) do
    case binding_pattern_macro(node) do
      nil ->
        analyze(node, :runtime, mutators)

      {raw_pattern, rebuild_mutant} ->
        node
        |> analyze(:runtime, mutators)
        |> attach_macro_pattern_candidates(raw_pattern, rebuild_mutant, mutators)
    end
  end

  # The `=`-only value-discarded path: a `for` qualifier, and the `=` shape of
  # `analyze_statement/2`. A `=` match's LHS goes to the structural families
  # (`MatchPattern`); everything else (a `<-` generator, a filter, a plain expression)
  # analyzes as ordinary runtime. A `for` qualifier deliberately stops here — a bare macro
  # call as a qualifier is a *filter* (its truthiness selects iterations), so rewriting it to
  # a binding would silently drop the filter; only a `=` (already a binding qualifier) is safe.
  defp analyze_match_statement({:=, _meta, [raw_lhs, raw_rhs]} = match, mutators) do
    analyzed = analyze(match, :runtime, mutators)
    attach_match_pattern_candidates(analyzed, raw_lhs, raw_rhs, mutators)
  end

  defp analyze_match_statement(other, mutators), do: analyze(other, :runtime, mutators)

  # Offer the `=`'s LHS to the structural pattern families and, if any fire, attach a
  # `Candidate.MatchPattern` per mutation to the analyzed match node — emission rewrites
  # it to the tuple-export selector (`Mutare.Transform.emit_match_site/3`). Each candidate
  # carries the LHS before/after (the diff), the shared export tuple, and the *raw* rhs.
  #
  # `put_candidates` (a plain prepend) is safe here — unlike the *macro* path, which had to
  # re-home a shadowed whole-call mutation — because the `=` node is **never offered** to
  # mutators (see the `analyze({:=, …})` clause), so the analyzed node carries no prior
  # `:mutare` to shadow. If that ever changes, this needs the macro path's re-home.
  defp attach_match_pattern_candidates(analyzed, raw_lhs, raw_rhs, mutators) do
    case match_pattern_candidates(raw_lhs, raw_rhs, PatternStructure.mutators(mutators)) do
      [] -> analyzed
      candidates -> put_candidates(analyzed, candidates)
    end
  end

  defp match_pattern_candidates(raw_lhs, raw_rhs, structural) do
    case pattern_export(raw_lhs, structural) do
      nil ->
        []

      {lhs, range, export, mutations} ->
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
  # runs the emitted one, so a nested mutation there still fires — see `emit_macro_pattern_site/3`).
  defp binding_pattern_macro({:|>, meta, [lhs, {form, rhs_meta, args} = rhs]})
       when is_list(rhs_meta) and is_list(args) do
    case Keyword.get(rhs_meta, :mutare_macro_piped) do
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
    case macro_routing(meta) do
      routing when is_list(routing) -> Enum.find_index(routing, &(&1 == :binding_pattern))
      _ -> nil
    end
  end

  # Offer the macro's escaping pattern to the structural families and attach a
  # `Candidate.MacroPattern` per mutation to the analyzed macro/pipe node — emission rewrites
  # it to the tuple-export selector (`Mutare.Transform.emit_macro_pattern_site/3`). Each
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
  # exactly like a pattern mutant — and strips it off the node. Both kinds then live under a
  # single `:mutare`; without this the prepended entry would silently shadow the whole-call
  # mutants (`Transform.candidates_of/1` reads only the first `:mutare`).
  #
  # The export tuple is computed up front (`pattern_export_base/1`) from the pattern's bound
  # vars alone — **independent of whether any structural swap/wildcard mutant fires** — so a
  # whole-call mutation is re-homed even when no pattern mutant is produced (the user enabled
  # only their `macros/0` mutator, or the pattern admits no swap/wildcard). Without that the
  # whole-call `Candidate.InPlace` would survive as an ordinary hoisted-pipe selector and
  # poison the build. When the pattern binds nothing (or isn't rangeable) there is no escape to
  # re-export, so an in-place selector is already safe and `analyzed` is left untouched.
  defp attach_macro_pattern_candidates(analyzed, raw_pattern, rebuild_mutant, mutators) do
    case pattern_export_base(raw_pattern) do
      nil ->
        analyzed

      {pattern, range, export, used} ->
        pattern_candidates =
          macro_pattern_candidates(pattern, range, export, used, rebuild_mutant, mutators)

        {analyzed, call_candidates} = rehome_call_mutations(analyzed, export)

        case call_candidates ++ pattern_candidates do
          [] -> analyzed
          candidates -> put_candidates(analyzed, candidates)
        end
    end
  end

  # Re-home a binding macro's *whole-call* in-place mutations (a custom mutator's, attached by
  # `offer` during `analyze(:runtime)`) into `MacroPattern` candidates the tuple-export selector
  # hosts as extra branches, and return the node with them stripped (so emission doesn't *also*
  # wrap the call in a standalone selector).
  #
  # A **piped** stage carries its mutations on the `|>` RHS *child* (`[x, y] |> destructure(v)`).
  # Left in place, the child's postwalk would emit it as a selector `case`, and this node's
  # baseline (`strip_candidates/1` in `emit_macro_pattern_site/3`) would become the illegal
  # `pattern |> case …` — which also traps the macro's escaping bindings inside the branch. So
  # the stage's mutations are pulled off the child (the baseline is then the bare emitted pipe)
  # and each re-homed with `mutant_expr` the mutated stage piped back from the LHS pattern, so
  # the mutant branch runs `lhs |> <mutated stage>` and the bindings reach the export tuple.
  defp rehome_call_mutations({:|>, meta, [lhs, {form, rhs_meta, args}]}, export)
       when is_list(rhs_meta) do
    {inplace, others} =
      rhs_meta |> Keyword.get(:mutare, []) |> Enum.split_with(&match?(%Candidate.InPlace{}, &1))

    rhs = set_mutare({form, rhs_meta, args}, others)

    call_candidates =
      Enum.map(inplace, fn ip ->
        call_mutation_candidate(ip, export, {:|>, meta, [lhs, ip.mutated]})
      end)

    {{:|>, meta, [lhs, rhs]}, call_candidates}
  end

  # A directly-written call carries its mutations on its own meta — re-home them with
  # `mutant_expr` the mutated call itself.
  defp rehome_call_mutations({form, meta, args}, export) when is_list(meta) do
    {inplace, others} =
      meta |> Keyword.get(:mutare, []) |> Enum.split_with(&match?(%Candidate.InPlace{}, &1))

    call_candidates = Enum.map(inplace, &call_mutation_candidate(&1, export, &1.mutated))
    {set_mutare({form, meta, args}, others), call_candidates}
  end

  defp rehome_call_mutations(node, _export), do: {node, []}

  # Convert one whole-call in-place mutation into a `MacroPattern` branch: the diff
  # (`original`/`mutated`/`range`) stays the call/stage the mutator changed, while `mutant_expr`
  # is what the branch *runs* — the (possibly piped) mutated call, before the export tuple.
  defp call_mutation_candidate(%Candidate.InPlace{} = ip, export, mutant_expr) do
    %Candidate.MacroPattern{
      mutator: ip.mutator,
      original: ip.original,
      mutated: ip.mutated,
      export: export,
      mutant_expr: mutant_expr,
      range: ip.range
    }
  end

  # Re-set the node's `:mutare` to whatever candidates we are *not* re-homing (normally none — a
  # macro call's own meta carries only its whole-call mutations), deleting the key when empty so
  # `put_candidates/2` cons-es a single fresh entry.
  defp set_mutare({form, meta, args}, []), do: {form, Keyword.delete(meta, :mutare), args}

  defp set_mutare({form, meta, args}, others),
    do: {form, Keyword.put(meta, :mutare, others), args}

  # The structural pattern mutants (swap/wildcard) for an already-discovered escaping pattern,
  # given its shared `export`/`range`/`used` (from `pattern_export_base/1`). Empty when no
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
  defp pattern_export(_raw_pattern, []), do: nil

  defp pattern_export(raw_pattern, structural) do
    case pattern_export_base(raw_pattern) do
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
  defp pattern_export_base(raw_pattern) do
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
  defp export_tuple([a, b]), do: {a, b}
  defp export_tuple(vars), do: {:{}, [], vars}

  # === return-value mutation =================================================

  # Attach return-value candidates to the *tail expression(s)* of the clause's
  # return-path blocks — the positions a `def`/`defp` clause returns from. This is
  # structural (a tail is a position no node-level mutator can match), so it runs
  # only when some enabled mutator implements `return_replacements/1` (the built-in
  # `Mutare.Mutators.ReturnValue`, or a custom one). The `:do` block
  # returns from its body tail; a `rescue`/`catch`/`else` block returns from
  # *every* clause body's tail (a rescued/caught error or an `else` match is a
  # return path too). `:after` is excluded — `try` discards its value.
  #
  # `analyzed_kw` carries the already-attached operator candidates; `raw_kw` is the
  # pre-analysis copy, used only to build each candidate's clean `original`/`range`
  # (so the diff renders the author's tail, un-annotated). The two are structurally
  # identical — analysis only adds metadata — so `map_tail/3` can navigate them in
  # lockstep to the same tail node. `ReturnValue.replacements/1` decides the
  # constant(s) (or that the tail is ineligible).
  defp annotate_returns(analyzed_kw, raw_kw, mutators) do
    case Mutator.implementing(mutators, :return_replacements, 1) do
      [] ->
        analyzed_kw

      return_mutators ->
        [analyzed_kw, raw_kw]
        |> Enum.zip()
        |> Enum.map(fn {{key, analyzed_value}, {_key, raw_value}} ->
          {key, annotate_block_returns(key, analyzed_value, raw_value, return_mutators)}
        end)
    end
  end

  # Route one body block to its return path(s): the `:do` body tail, each
  # `rescue`/`catch`/`else` clause body tail, or — for `:after` (value discarded)
  # and any other key — nothing.
  defp annotate_block_returns(key, analyzed, raw, return_mutators) do
    cond do
      do_key?(key) -> attach_return(analyzed, raw, return_mutators)
      clause_block_key?(key) -> attach_clause_returns(analyzed, raw, return_mutators)
      true -> analyzed
    end
  end

  # rescue/catch/else: a list of `->` clauses; each clause body's tail is a return
  # path. Walk the analyzed and raw clause lists in lockstep (structurally
  # identical) and append a return candidate to each clause body's tail.
  defp attach_clause_returns(analyzed_clauses, raw_clauses, return_mutators)
       when is_list(analyzed_clauses) and is_list(raw_clauses) and
              length(analyzed_clauses) == length(raw_clauses) do
    [analyzed_clauses, raw_clauses]
    |> Enum.zip()
    |> Enum.map(fn {analyzed, raw} -> attach_clause_return(analyzed, raw, return_mutators) end)
  end

  defp attach_clause_returns(analyzed_clauses, _raw, _return_mutators), do: analyzed_clauses

  defp attach_clause_return(
         {:->, meta, [patterns, analyzed_body]},
         {:->, _rmeta, [_raw_patterns, raw_body]},
         return_mutators
       ) do
    {:->, meta, [patterns, attach_return(analyzed_body, raw_body, return_mutators)]}
  end

  defp attach_clause_return(analyzed, _raw, _return_mutators), do: analyzed

  defp do_key?(key), do: AST.key_atom(key) == :do
  defp clause_block_key?(key), do: AST.key_atom(key) in @clause_block_keys

  # Find the tail expression of a `:do` block (the last statement of a multi-
  # statement block, else the whole single-expression value) and append a
  # return-value candidate per `{spec, replacement}` (each return mutator's
  # `return_replacements/1` output, tagged with its spec). The candidates ride in
  # the tail node's own `meta[:mutare]` — *after* any operator candidates already
  # there — so emission builds one selector `case` hosting both an operator swap
  # and the return constant on the same node, ids in attachment order.
  defp attach_return(analyzed_value, raw_value, return_mutators) do
    map_tail(analyzed_value, raw_value, fn analyzed_tail, raw_tail ->
      replacements =
        Enum.flat_map(return_mutators, fn spec ->
          Enum.map(spec.module.return_replacements(raw_tail), &{spec, &1})
        end)

      case replacements do
        [] -> analyzed_tail
        _ -> append_return_candidates(analyzed_tail, raw_tail, replacements)
      end
    end)
  end

  # Apply `fun` to the tail of a (possibly block) value, in lockstep on the
  # analyzed and raw copies. A statement sequence (`>= 2` statements) returns the
  # body with its last statement mapped; anything else is itself the tail. A
  # single-statement `:__block__` (a Sourceror-wrapped literal like `{:__block__,
  # _, [:ok]}`) is intentionally *not* unwrapped — the wrapping block is the node
  # we attach to.
  defp map_tail({:__block__, meta, a_stmts}, {:__block__, _rmeta, r_stmts}, fun)
       when length(a_stmts) >= 2 and length(a_stmts) == length(r_stmts) do
    {a_init, [a_last]} = Enum.split(a_stmts, -1)
    {_r_init, [r_last]} = Enum.split(r_stmts, -1)
    {:__block__, meta, a_init ++ [fun.(a_last, r_last)]}
  end

  defp map_tail(analyzed_value, raw_value, fun), do: fun.(analyzed_value, raw_value)

  # Append a `Candidate.Return` per replacement to the tail node's metadata,
  # preserving any operator candidates already there (so operator ids precede the
  # return id at a shared node). The candidate's `original`/`range` come from the
  # *raw* tail, so the diff is clean. A tail we can't annotate (a non-`{f,m,a}`
  # node, or one Sourceror can't range) gets no return mutant.
  defp append_return_candidates({form, meta, args} = node, raw_tail, replacements)
       when is_list(meta) do
    case NodeRange.get(raw_tail) do
      %{} = range ->
        candidates =
          Enum.map(replacements, fn {spec, replacement} ->
            %Candidate.Return{
              mutator: spec,
              original: raw_tail,
              mutated: replacement,
              range: range
            }
          end)

        existing = Keyword.get(meta, :mutare, [])
        {form, Keyword.put(meta, :mutare, existing ++ candidates), args}

      _ ->
        node
    end
  end

  defp append_return_candidates(node, _raw_tail, _replacements), do: node

  # === condition analysis (if / unless / cond) ===============================

  # Analyze a `cond` clause *condition*: the generic runtime walk, plus the IfCondition
  # `true`/`false` pair — but with one wrinkle the descent can't see. A binding made
  # *inside* the condition (`(name = f()) != nil`, `lookup(x = key())`) **escapes** into
  # the clause body (`if`/`cond` conditions leak their bindings), where a later
  # expression reads it. The in-place selector that wraps a mutated node is a `case`,
  # which would scope that binding to a branch — so the body's reference to it becomes
  # unbound: a hard compile error, *independent of the active mutant* (every branch,
  # including the unmutated catch-all, binds inside the `case`).
  #
  # So `finish_condition/3` runs `prune_binding_ancestors/1`, stripping the in-place
  # candidates from every node that is an *ancestor* of an escaping binding — exactly
  # the nodes whose selector would trap it — while a sibling sub-expression with no
  # binding under it still mutates. And IfCondition (which wraps the *whole* condition)
  # is skipped whenever any binding escapes within it. (IfCondition already declines a
  # *top-level* `=`; this covers a binding nested under an operator/call, where
  # Conditional/Relational/IfCondition would otherwise wrap and trap it.)
  #
  # `cond` can only prune — its clauses are evaluated in order with short-circuit, so a
  # clause's binding can't be hoisted out without changing when it runs. `if`/`unless`
  # *can* hoist (a single unconditional condition); that richer path lives in the
  # if/unless clause above (`hoist_if?/2` + `hoist_if/6`).
  defp analyze_condition(condition, mutators) do
    analyzed = analyze(condition, :runtime, mutators)
    finish_condition(analyzed, condition, mutators)
  end

  # The short-circuit operators whose right operand is evaluated *conditionally* (so a
  # binding there is off-spine), and the nested-branch forms whose internals are also
  # conditional. Binding-isolating forms (`@binding_isolating_forms`, below) are handled
  # separately — their bindings never escape at all.
  @short_circuit_ops [:and, :or, :&&, :||]
  @branch_forms [:if, :unless, :cond, :case, :receive]

  # Forms that isolate the bindings made within them — a `=` inside a closure, a
  # comprehension, a `try`, or a `quote` does not reach the enclosing clause body, so
  # it taints nothing and its (already correctly-analyzed) internals are left intact.
  # Everything else (operators, calls, `case`/`cond`/`if`, `&&`/`||`, blocks) leaks
  # bindings outward, so the taint propagates through it.
  @binding_isolating_forms [:fn, :for, :with, :try, :quote]

  # The post-analysis step shared by `cond` and the *plain* (non-hoisted) `if`/`unless`
  # path: prune the binding-ancestors; if no binding escapes, additionally offer the
  # IfCondition decision pair on the whole condition.
  defp finish_condition(analyzed, raw_condition, mutators) do
    case prune_binding_ancestors(analyzed) do
      {pruned, true} -> pruned
      {_pruned, false} -> attach_if_condition(analyzed, raw_condition, mutators)
    end
  end

  # === if/unless condition hoisting ==========================================
  #
  # When an `if`/`unless` condition binds a variable that escapes into the body, the
  # prune path above can deliver *no* decision mutant (the selector would trap the
  # binding). But an `if` condition is evaluated **unconditionally and exactly once**,
  # so the binding can be *hoisted* out into a preceding statement — leaving a
  # binding-free condition that can host the decision selector without trapping
  # anything. `if (name = f()) != nil do use(name) …` becomes:
  #
  #     name = f()
  #     if (case <sel> do <id> -> true; <id> -> false; _ -> name != nil end) do
  #       use(name)          # `name` is bound by the hoisted statement — no trap
  #     end
  #
  # delivered as a `__block__` (which renders, compiles, and leaks `name` exactly like
  # the original `if` in every position — statement, expression RHS, call argument).
  # A **refutable** pattern (`if {:ok, v} = f() do`) keeps its `MatchError` semantics
  # by binding the match value to a temp first: `mutare_cond = f(); {:ok, v} =
  # mutare_cond; if … mutare_cond … do`. The temp is a placeholder until emit
  # substitutes the salted `cond_var` (analyze is id-/name-free).
  #
  # Scope (each a soundness or fidelity guard, the rest staying on the prune path):
  #   * The decision is delivered; everything else on a *binding-ancestor* node (an
  #     operator swap on `!=`, say) stays pruned — its mutant would still embed the
  #     binding. Safe siblings and the body mutate as always; the hoisted EXPR mutates
  #     in its new statement.
  #   * Only when **every** escaping binding is on the unconditional *spine* — not
  #     under a short-circuit (`and`/`or`/`&&`/`||`) right operand, nor inside a nested
  #     branch (`case`/`cond`/`if`) — so hoisting can't change *when* it evaluates.
  #   * Only when no binding is reordered past a side-effecting sibling (`spine_reorders?/1`):
  #     a binding hoists to *before the whole `if`*, so an expression that evaluates
  #     *before* it in the original (`check(state) == (x = f())` — `check(state)` first)
  #     would otherwise be reordered *after* it on the baseline (mutant 0 must match the
  #     original program). Vetoed when an impure expression precedes a spine binding in
  #     evaluation order — the common shapes (`if x = e`, `(x = e) != nil`, `(x = e) and
  #     g(x)`, two bindings) have the binding(s) evaluated first, so they still hoist.
  #   * At most **one** refutable spine binding (they would all need a distinct temp;
  #     bare-variable bindings reuse their own name, so any number is fine).
  #   * Gated on `IfCondition` being enabled (it owns the decision the hoist delivers).
  # The decision `Site` references the **original** condition (range and code), so the
  # report diff stays faithful (`(name = f()) != nil` → `true`), independent of the
  # rewrite emit actually delivers.
  defp hoist_if?(analyzed_condition, mutators) do
    Spec.find(mutators, Mutare.Mutators.IfCondition) != nil and
      escaping_binding?(analyzed_condition) and
      not offspine_escaping_binding?(analyzed_condition) and
      not spine_reorders?(analyzed_condition) and
      refutable_spine_count(analyzed_condition) <= 1
  end

  # Build the hoisted `__block__`: lift every spine binding into a preceding statement,
  # rewrite the condition to read the lifted value, and attach the decision pair to the
  # rewritten root (with `original`/`range` from the *raw* condition, for the report).
  defp hoist_if(form, meta, raw_condition, analyzed_condition, analyzed_body, mutators) do
    {pruned, _has} = prune_binding_ancestors(analyzed_condition)
    {rewritten, hoists} = spine_rewrite(pruned)
    rewritten = attach_decision(rewritten, raw_condition, mutators)
    if_node = {form, meta, [rewritten, analyzed_body]}
    {:__block__, [], hoists ++ [if_node]}
  end

  # Synthesize the `IfCondition` decision (`true`/`false`) on the rewritten condition
  # root, ranged on the original condition. We build it directly rather than calling
  # the `condition_replacements/1` hook, which declines a binding condition (and a
  # boolean-operator one) — the very shapes this path exists for.
  defp attach_decision(rewritten_root, raw_condition, mutators) do
    case Spec.find(mutators, Mutare.Mutators.IfCondition) do
      nil ->
        rewritten_root

      spec ->
        candidates = [{spec, AST.literal(true)}, {spec, AST.literal(false)}]
        append_condition_candidates(rewritten_root, raw_condition, candidates)
    end
  end

  # Rewrite the condition's *spine* (the unconditionally-evaluated nodes), replacing
  # each spine binding `PAT = EXPR` with a read of the lifted value and returning the
  # hoist statements, in evaluation (left-to-right) order. A bare-variable binding
  # `v = EXPR` lifts as `v = EXPR` and the condition reads `v`; a refutable `PAT =
  # EXPR` lifts as `tmp = EXPR; PAT = tmp` (the match value is `EXPR`, not the
  # pattern's bindings) and the condition reads `tmp`. The walk stops at short-circuit
  # right operands, nested branches, and binding-isolating forms — `hoist_if?/2` has
  # already verified no escaping binding hides there.
  defp spine_rewrite({op, meta, [left, right]}) when op in @short_circuit_ops do
    {left2, hoists} = spine_rewrite(left)
    {{op, meta, [left2, right]}, hoists}
  end

  defp spine_rewrite({form, _meta, _args} = node)
       when form in @branch_forms or form in @binding_isolating_forms,
       do: {node, []}

  defp spine_rewrite({:=, _meta, [lhs, rhs]}), do: hoist_one(lhs, rhs)

  defp spine_rewrite({form, meta, args}) when is_list(args) do
    {args2, hoists} = spine_rewrite_each(args)
    {{form, meta, args2}, hoists}
  end

  defp spine_rewrite({left, right}) do
    {left2, lh} = spine_rewrite(left)
    {right2, rh} = spine_rewrite(right)
    {{left2, right2}, lh ++ rh}
  end

  defp spine_rewrite(list) when is_list(list), do: spine_rewrite_each(list)

  defp spine_rewrite(other), do: {other, []}

  defp spine_rewrite_each(list) do
    {nodes, hoists} = list |> Enum.map(&spine_rewrite/1) |> Enum.unzip()
    {nodes, List.flatten(hoists)}
  end

  # One spine binding → `{read_node, [hoist_statement(s)]}`. The read node and the
  # hoist's RHS keep the *analyzed* EXPR, so its mutations are delivered in the lifted
  # statement.
  defp hoist_one(lhs, rhs) do
    if bare_var?(lhs) do
      {clean_var(lhs), [{:=, [], [lhs, rhs]}]}
    else
      placeholder = Names.hoist_placeholder()
      {placeholder, [{:=, [], [placeholder, rhs]}, {:=, [], [lhs, placeholder]}]}
    end
  end

  # The bindings on the unconditional spine (mirrors `spine_rewrite/1`'s reach).
  defp spine_bindings({op, _meta, [left, _right]}) when op in @short_circuit_ops,
    do: spine_bindings(left)

  defp spine_bindings({form, _meta, _args})
       when form in @branch_forms or form in @binding_isolating_forms,
       do: []

  defp spine_bindings({:=, _meta, _args} = node), do: [node]

  defp spine_bindings({_form, _meta, args}) when is_list(args),
    do: Enum.flat_map(args, &spine_bindings/1)

  defp spine_bindings({left, right}), do: spine_bindings(left) ++ spine_bindings(right)
  defp spine_bindings(list) when is_list(list), do: Enum.flat_map(list, &spine_bindings/1)
  defp spine_bindings(_), do: []

  defp refutable_spine_count(node) do
    node
    |> spine_bindings()
    |> Enum.count(fn {:=, _meta, [lhs, _rhs]} -> not bare_var?(lhs) end)
  end

  # Would hoisting reorder a binding past a side-effecting sibling? A spine binding is
  # lifted to *before the whole `if`*, so any expression evaluated *before* it in the
  # original condition ends up *after* it on the baseline — and the baseline (mutant 0)
  # must be behaviorally identical to the original program. `check(state) == (x = f())`
  # evaluates `check(state)` first, so hoisting `x = f()` ahead of it changes the order
  # of side effects; this vetoes that, falling back to the sound prune path.
  #
  # `eval_steps/1` flattens the condition into its left-to-right evaluation order as
  # `:binding` (a spine `=`, which rides whole), `:pure` (a literal or bare-variable
  # read — no side effect, safe to reorder around), or `:other` (anything else — a call,
  # an operator application, a short-circuit/branch/isolating subtree — conservatively
  # treated as possibly side-effecting). It is unsafe iff an `:other` precedes a
  # `:binding`. The common shapes evaluate their binding(s) first (`if x = e`,
  # `(x = e) != nil`, `(x = first(a)) != (y = first(b))`), so they stay hoistable.
  defp spine_reorders?(condition) do
    condition |> eval_steps() |> impure_before_binding?(false)
  end

  defp impure_before_binding?([], _seen_other?), do: false

  defp impure_before_binding?([:binding | rest], seen?),
    do: seen? or impure_before_binding?(rest, seen?)

  defp impure_before_binding?([:other | rest], _seen?), do: impure_before_binding?(rest, true)
  defp impure_before_binding?([:pure | rest], seen?), do: impure_before_binding?(rest, seen?)

  # A spine `=` rides into the hoist as one unit (its internals keep their relative
  # order), so it is a single `:binding` step — not descended.
  defp eval_steps({:=, _meta, _args}), do: [:binding]

  # A short-circuit: only the left operand is on the spine; the right is evaluated
  # conditionally and (by `offspine_escaping_binding?/1`) holds no binding, so it is one
  # opaque `:other` step after the left.
  defp eval_steps({op, _meta, [left, _right]}) when op in @short_circuit_ops,
    do: eval_steps(left) ++ [:other]

  # A nested branch / binding-isolating subtree holds no spine binding either; it is one
  # opaque `:other` step (so a `case`/`fn`/… *before* a binding correctly vetoes).
  defp eval_steps({form, _meta, _args})
       when form in @branch_forms or form in @binding_isolating_forms,
       do: [:other]

  # A Sourceror scalar literal (`{:__block__, meta, [value]}`) — pure.
  defp eval_steps({:__block__, _meta, [value]})
       when is_atom(value) or is_number(value) or is_binary(value),
       do: [:pure]

  # A bare variable read — pure (an atom name with an atom hygiene context).
  defp eval_steps({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: [:pure]

  # Any other call/operator (including a remote `{:., …}` call): its arguments evaluate
  # left to right, then the application itself runs — one `:other` step after the args.
  defp eval_steps({_form, _meta, args}) when is_list(args),
    do: Enum.flat_map(args, &eval_steps/1) ++ [:other]

  defp eval_steps({left, right}), do: eval_steps(left) ++ eval_steps(right)
  defp eval_steps(list) when is_list(list), do: Enum.flat_map(list, &eval_steps/1)
  defp eval_steps(leaf) when is_atom(leaf) or is_number(leaf) or is_binary(leaf), do: [:pure]
  defp eval_steps(_other), do: [:other]

  # Is there an escaping binding *off* the unconditional spine — under a short-circuit
  # right operand or inside a nested branch — that hoisting therefore can't lift?
  # (A binding-isolating form's bindings never escape, so they are not a concern; a
  # spine `=` rides into the hoist whole, so its own nested bindings are not off-spine.)
  defp offspine_escaping_binding?({op, _meta, [left, right]}) when op in @short_circuit_ops,
    do: offspine_escaping_binding?(left) or escaping_binding?(right)

  defp offspine_escaping_binding?({form, _meta, _args} = node) when form in @branch_forms,
    do: escaping_binding?(node)

  defp offspine_escaping_binding?({form, _meta, _args}) when form in @binding_isolating_forms,
    do: false

  defp offspine_escaping_binding?({:=, _meta, _args}), do: false

  defp offspine_escaping_binding?({_form, _meta, args}) when is_list(args),
    do: Enum.any?(args, &offspine_escaping_binding?/1)

  defp offspine_escaping_binding?({left, right}),
    do: offspine_escaping_binding?(left) or offspine_escaping_binding?(right)

  defp offspine_escaping_binding?(list) when is_list(list),
    do: Enum.any?(list, &offspine_escaping_binding?/1)

  defp offspine_escaping_binding?(_), do: false

  # Does the subtree contain an escaping `=` binding (one not isolated inside a
  # closure/comprehension/`try`/`quote`)? The presence counterpart of
  # `prune_binding_ancestors/1`'s taint.
  defp escaping_binding?({form, _meta, _args}) when form in @binding_isolating_forms, do: false
  defp escaping_binding?({:=, _meta, _args}), do: true

  defp escaping_binding?({_form, _meta, args}) when is_list(args),
    do: Enum.any?(args, &escaping_binding?/1)

  defp escaping_binding?({left, right}), do: escaping_binding?(left) or escaping_binding?(right)
  defp escaping_binding?(list) when is_list(list), do: Enum.any?(list, &escaping_binding?/1)
  defp escaping_binding?(_), do: false

  # A bare variable (the irrefutable, temp-free hoist case): a `{name, _, context}`
  # node with an atom name (not `_`) and an atom hygiene context. A call (`context` is
  # the arg list), an `__aliases__`, a pin, or a container is *not* a bare variable.
  defp bare_var?({name, _meta, context})
       when is_atom(name) and is_atom(context) and name != :_,
       do: true

  defp bare_var?(_), do: false

  defp clean_var({name, _meta, context}), do: {name, [], context}

  # Bottom-up over the analyzed condition: returns `{node, subtree_has_binding?}`,
  # stripping the in-place candidates (`meta[:mutare]`) from any node that is a
  # *proper ancestor* of an escaping `=` binding (a child subtree holds one). A `=`
  # node has no in-place candidate of its own, so it is never itself stripped; it only
  # reports its subtree as binding-bearing so its ancestors are pruned.
  defp prune_binding_ancestors({form, _meta, _args} = node)
       when form in @binding_isolating_forms,
       do: {node, false}

  defp prune_binding_ancestors({form, meta, args}) when is_list(args) do
    {pruned_args, child_has?} = prune_binding_ancestors_each(args)
    node = {form, meta, pruned_args}
    node = if child_has?, do: strip_inplace_candidates(node), else: node
    {node, child_has? or form == :=}
  end

  defp prune_binding_ancestors({left, right}) do
    {pruned_left, left_has?} = prune_binding_ancestors(left)
    {pruned_right, right_has?} = prune_binding_ancestors(right)
    {{pruned_left, pruned_right}, left_has? or right_has?}
  end

  # A bare list operand (`length([x = f(), y])`) — walk each element so a binding
  # nested in it still taints the call that holds it. A list carries no metadata, so
  # there is nothing of its own to strip.
  defp prune_binding_ancestors(list) when is_list(list),
    do: prune_binding_ancestors_each(list)

  defp prune_binding_ancestors(other), do: {other, false}

  defp prune_binding_ancestors_each(list) do
    {nodes, hass} = list |> Enum.map(&prune_binding_ancestors/1) |> Enum.unzip()
    {nodes, Enum.any?(hass)}
  end

  defp strip_inplace_candidates({form, meta, args}) when is_list(meta),
    do: {form, Keyword.delete(meta, :mutare), args}

  defp strip_inplace_candidates(node), do: node

  # Force an `if`/`unless`/`cond` *condition* to `true`/`false` via the in-place
  # selector. `IfCondition.replacements/1` returns the `[true, false]` pair (or `[]`
  # when the condition is a boolean operator `Conditional` already forces, a literal,
  # or a binding `x = …` whose un-binding would poison the body — see that module).
  # Gated on the family being enabled, like `annotate_returns/3`. The candidates are
  # appended to the *analyzed* condition node — after any operator candidate already
  # there, so one selector hosts both — with `original`/`range` taken from the *raw*
  # condition for a clean diff.
  defp attach_if_condition(analyzed_condition, raw_condition, mutators) do
    candidates =
      mutators
      |> Mutator.implementing(:condition_replacements, 1)
      |> Enum.flat_map(fn spec ->
        Enum.map(spec.module.condition_replacements(raw_condition), &{spec, &1})
      end)

    case candidates do
      [] -> analyzed_condition
      _ -> append_condition_candidates(analyzed_condition, raw_condition, candidates)
    end
  end

  # Append a `Candidate.InPlace` per `{spec, mutated}` (`mutator` is the producing
  # *spec* — `IfCondition` or a custom condition mutator — since `Site.in_place/6` reads
  # its `name`) to the condition node's metadata, preserving any candidates already there.
  # A condition we can't range (Sourceror returns nil) or that is not a `{f, m, a}` node
  # gets no mutant.
  defp append_condition_candidates({form, meta, args} = node, raw_condition, candidates)
       when is_list(meta) do
    case NodeRange.get(raw_condition) do
      %{} = range ->
        new =
          Enum.map(candidates, fn {spec, mutated} ->
            %Candidate.InPlace{
              mutator: spec,
              original: raw_condition,
              mutated: mutated,
              range: range
            }
          end)

        existing = Keyword.get(meta, :mutare, [])
        {form, Keyword.put(meta, :mutare, existing ++ new), args}

      _ ->
        node
    end
  end

  defp append_condition_candidates(node, _raw_condition, _candidates), do: node

  # A bitstring segment `<<value::spec>>`: the value keeps the surrounding
  # context; the spec side is excluded except for `size(expr)` args.
  defp analyze_segment({:"::", meta, [value, spec]}, context, mutators) do
    {:"::", meta, [analyze(value, context, mutators), analyze_spec(spec, context, mutators)]}
  end

  defp analyze_segment(segment, context, mutators), do: analyze(segment, context, mutators)

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
  defp offer(subject, raw, mutators, context \\ %{pipe_mode: :unpiped}) do
    case Mutator.mutations(raw, mutators, context) do
      [] -> subject
      muts -> put_candidates(subject, build_candidates(raw, muts))
    end
  end

  defp build_candidates(node, muts) do
    range = NodeRange.get(node)

    Enum.map(muts, fn {mutator, mutated} ->
      %Candidate.InPlace{mutator: mutator, original: node, mutated: mutated, range: range}
    end)
  end

  defp put_candidates({form, meta, args}, candidates),
    do: {form, [{:mutare, candidates} | meta], args}

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
