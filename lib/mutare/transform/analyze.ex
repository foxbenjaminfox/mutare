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
  alias Mutare.Transform.{Candidate, NodeRange, PatternStructure, Tag}

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
  #   * `:owned` — a call argument a mutator has *claimed* (its optional
  #     `owned_args/2`): like `:pattern` it never mutates in place but keeps
  #     descending. Routed by `recurse_runtime/3` so a leaf the claimant already
  #     covers via the whole call (a ModeSwap unit/mode atom) isn't *also* mutated
  #     in place by another mutator (AtomLiteral → a redundant, raising `:mutare`).
  #     When the owned argument is a keyword list (a `shift` duration), only its
  #     keys go `:owned`; the values stay `:runtime` (`analyze_owned_keywords/2`).
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
  # as runtime, then has its IfCondition candidate appended (`attach_if_condition/3`);
  # the body keyword (`do:`/`else:` values) is analyzed exactly as the generic
  # runtime clause would, and the whole node is still offered to mutators for parity
  # (a custom mutator matching an `if`; the built-ins match none). Only `:runtime` —
  # a module-level (`:scaffold`) `if` runs once at compile time, so its condition is
  # inert and falls through to the non-mutating catch-all.
  defp analyze({form, meta, [condition, body_kw]} = node, :runtime, mutators)
       when form in [:if, :unless] and is_list(body_kw) do
    analyzed_condition =
      condition
      |> analyze(:runtime, mutators)
      |> attach_if_condition(condition, mutators)

    rebuilt = {form, meta, [analyzed_condition, analyze(body_kw, :runtime, mutators)]}

    offer(rebuilt, node, mutators)
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
      node |> offer(node, mutators) |> recurse_runtime(mutators, false)
    end
  end

  # `not in`: `x not in y` parses as `not(x in y)` — a `:not` wrapping an `:in`.
  # Both nodes are boolean-valued, so the inner `in` would otherwise be offered to
  # mutators and produce only *redundant* mutants: Conditional forcing it to
  # `true`/`false` yields `not true`/`not false`, exactly the outer `not` forced to
  # `false`/`true`; and Relational's `in` → `not in` yields `not(x not in y)` ≡
  # `x in y`, exactly Logical's strip of the outer `not`. So the inner `in` node is
  # not offered to any mutator (only its operands descend); the outer `not` is
  # offered normally (Logical strips it → `x in y`, the strongest membership
  # mutation, and Conditional forces it `true`/`false`). The only families matching
  # an `in` node are Conditional and Relational — both redundant under a `not` — so
  # this drops exactly the redundant mutants and nothing of value.
  defp analyze({:not, meta, [{:in, in_meta, [left, right]}]} = node, :runtime, mutators) do
    inner =
      {:in, in_meta, [analyze(left, :runtime, mutators), analyze(right, :runtime, mutators)]}

    rebuilt = {:not, meta, [inner]}

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
          else: recurse_runtime(node, mutators, false)

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
        node = offer(node, node, mutators, %{piped: true})
        recurse_runtime(node, mutators, true)

      routing ->
        analyze_known_macro(node, routing, mutators, %{piped: true})
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
  defp analyze_known_macro(node, routing, mutators, context \\ %{piped: false}) do
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

  # Recurse a runtime call's arguments, but route any positions a mutator has *claimed*
  # (its optional `owned_args/2`) through the non-mutating `:owned` context — so a leaf
  # the claimant already covers via the *whole call* (a ModeSwap unit/mode atom) isn't
  # *also* offered to another mutator in place (AtomLiteral turning `:second` into a
  # redundant, always-raising `:mutare`). With no claimant the owned set is empty and
  # this is exactly `recurse(node, :runtime, …)` — so non-owning calls are unaffected.
  # `piped?` is threaded because ownership, like arity, depends on the pipe position.
  #
  # An owned argument that is a **keyword list** (a `DateTime.shift(dt, minute: 10)`
  # duration) is special-cased: the claimant owns the option *names*, so only the keys go
  # `:owned` (AtomLiteral leaves `minute:` alone) while each value stays `:runtime` (Literal
  # still mutates the amount) — see `analyze_owned_keywords/2`.
  defp recurse_runtime({form, meta, args} = node, mutators, piped?) when is_list(args) do
    analyzed =
      case owned_arg_indices(node, mutators, %{piped: piped?}) do
        [] ->
          recurse(node, :runtime, mutators)

        owned ->
          args =
            args
            |> Enum.with_index()
            |> Enum.map(fn {arg, i} ->
              cond do
                i not in owned -> analyze(arg, :runtime, mutators)
                owned_keyword_list?(arg) -> analyze_owned_keywords(arg, mutators)
                true -> analyze(arg, :owned, mutators)
              end
            end)

          {form, meta, args}
      end

    mark_call_option_keys(analyzed)
  end

  defp recurse_runtime(node, mutators, _piped?), do: recurse(node, :runtime, mutators)

  # Whether an owned argument is a keyword list — bare (trailing-keyword sugar) or an
  # explicit `[…]` (a `:__block__`-wrapped list), so the key/value split below applies.
  defp owned_keyword_list?({:__block__, _meta, [inner]}), do: keyword_list_shaped?(inner)
  defp owned_keyword_list?(arg), do: keyword_list_shaped?(arg)

  # Analyze an *owned* keyword-list argument: route each key through `:owned` (so the
  # claimant — ModeSwap, for a `shift` duration unit — keeps it from being offered to
  # AtomLiteral) while each value stays ordinary `:runtime` data, so the other mutators
  # (notably Literal on a shift amount) still fire on it. The general reading of "a mutator
  # claims a keyword-list argument": it owns the option names, not the values.
  defp analyze_owned_keywords({:__block__, meta, [inner]}, mutators) when is_list(inner) do
    {:__block__, meta, [analyze_owned_keywords(inner, mutators)]}
  end

  defp analyze_owned_keywords(list, mutators) when is_list(list) do
    Enum.map(list, fn
      {key, value} -> {analyze(key, :owned, mutators), analyze(value, :runtime, mutators)}
      other -> analyze(other, :runtime, mutators)
    end)
  end

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

  # The visible argument indices some active mutator claims exclusive ownership of at this
  # call (via the optional `owned_args/2` callback), unioned. Cheap when nobody implements
  # it — the `function_exported?/2` filter short-circuits before any call.
  defp owned_arg_indices(node, mutators, context) do
    for %Spec{module: module, opts: opts} <- mutators,
        function_exported?(module, :owned_args, 2),
        i <- module.owned_args(node, Map.put(context, :opts, opts)),
        uniq: true,
        do: i
  end

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
        analyzed = analyze(cond_node, context, mutators)

        # Force the condition to true/false (IfCondition) only when it is live —
        # a `:scaffold` cond (module-level metaprogramming) runs once at compile
        # time with mutant 0, so a selector on its condition could never activate.
        if context == :runtime,
          do: attach_if_condition(analyzed, cond_node, mutators),
          else: analyzed
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

    tagged_targets(targets, fn tag, original, mutator, mutated ->
      %Candidate.CaseClause{
        clause_index: index,
        mutator: mutator,
        mutant_pattern: pattern,
        mutant_guard: Tag.replace_tag(tagged_guard, tag, mutated),
        raw_body: body,
        original: original,
        mutated: mutated,
        range: NodeRange.get(original)
      }
    end)
  end

  defp literal_clause_candidates(index, pattern, guard, body, mutators) do
    {tagged_pattern, {_next, targets}} = Tag.pattern_literal_targets(pattern, {0, []}, mutators)

    tagged_targets(targets, fn tag, original, mutator, mutated ->
      %Candidate.CaseClause{
        clause_index: index,
        mutator: mutator,
        mutant_pattern: Tag.replace_tag(tagged_pattern, tag, mutated),
        mutant_guard: guard,
        raw_body: body,
        original: original,
        mutated: mutated,
        range: NodeRange.get(original)
      }
    end)
  end

  defp structural_clause_candidates(_index, _pattern, _guard, _body, _used, []), do: []

  defp structural_clause_candidates(index, pattern, guard, body, used, structural) do
    case NodeRange.get(pattern) do
      %{} = range ->
        pattern
        |> PatternStructure.node_mutations(used, structural)
        |> Enum.map(fn {mutator, mutated} ->
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

      _ ->
        []
    end
  end

  # Walk `Tag` targets (accumulated in reverse post-order; reverse to source order), calling
  # `build.(tag, original_node, mutator, mutated)` for each mutation — `tag` to `replace_tag`
  # the tagged copy, `original_node` for the diff/range.
  defp tagged_targets(targets, build) do
    targets
    |> Enum.reverse()
    |> Enum.flat_map(fn {tag, original, muts} ->
      Enum.map(muts, fn {mutator, mutated} -> build.(tag, original, mutator, mutated) end)
    end)
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
    case NodeRange.get(pattern) do
      %{} = range ->
        pattern
        |> PatternStructure.node_mutations(used, structural)
        |> Enum.map(fn {mutator, mutated} ->
          %Candidate.CasePattern{
            mutator: mutator,
            original: pattern,
            mutated: mutated,
            replacement: replace_clause.(put_clause_pattern_at(clause, pos, mutated)),
            range: range
          }
        end)

      _ ->
        []
    end
  end

  defp literal_position_candidates(pattern, pos, clause, replace_clause, mutators) do
    {tagged_pattern, {_next, targets}} = Tag.pattern_literal_targets(pattern, {0, []}, mutators)

    tagged_targets_ranged(targets, fn tag, original, mutator, mutated, range ->
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

        tagged_targets_ranged(targets, fn tag, original, mutator, mutated, range ->
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

  # Walk `Tag` targets in source order, dropping any whose original node Sourceror can't
  # range (the whole-construct path needs a focused-diff range), calling `build` with the
  # tag, the raw original node, the swap, and the range.
  defp tagged_targets_ranged(targets, build) do
    targets
    |> Enum.reverse()
    |> Enum.flat_map(fn {tag, original, muts} ->
      case NodeRange.get(original) do
        %{} = range ->
          Enum.map(muts, fn {mutator, mutated} ->
            build.(tag, original, mutator, mutated, range)
          end)

        _ ->
          []
      end
    end)
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
  # only when the `Mutare.Mutators.ReturnValue` family is enabled. The `:do` block
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
    if Spec.find(mutators, Mutare.Mutators.ReturnValue) do
      [analyzed_kw, raw_kw]
      |> Enum.zip()
      |> Enum.map(fn {{key, analyzed_value}, {_key, raw_value}} ->
        {key, annotate_block_returns(key, analyzed_value, raw_value)}
      end)
    else
      analyzed_kw
    end
  end

  # Route one body block to its return path(s): the `:do` body tail, each
  # `rescue`/`catch`/`else` clause body tail, or — for `:after` (value discarded)
  # and any other key — nothing.
  defp annotate_block_returns(key, analyzed, raw) do
    cond do
      do_key?(key) -> attach_return(analyzed, raw)
      clause_block_key?(key) -> attach_clause_returns(analyzed, raw)
      true -> analyzed
    end
  end

  # rescue/catch/else: a list of `->` clauses; each clause body's tail is a return
  # path. Walk the analyzed and raw clause lists in lockstep (structurally
  # identical) and append a return candidate to each clause body's tail.
  defp attach_clause_returns(analyzed_clauses, raw_clauses)
       when is_list(analyzed_clauses) and is_list(raw_clauses) and
              length(analyzed_clauses) == length(raw_clauses) do
    [analyzed_clauses, raw_clauses]
    |> Enum.zip()
    |> Enum.map(fn {analyzed, raw} -> attach_clause_return(analyzed, raw) end)
  end

  defp attach_clause_returns(analyzed_clauses, _raw), do: analyzed_clauses

  defp attach_clause_return(
         {:->, meta, [patterns, analyzed_body]},
         {:->, _rmeta, [_raw_patterns, raw_body]}
       ) do
    {:->, meta, [patterns, attach_return(analyzed_body, raw_body)]}
  end

  defp attach_clause_return(analyzed, _raw), do: analyzed

  defp do_key?(key), do: AST.key_atom(key) == :do
  defp clause_block_key?(key), do: AST.key_atom(key) in @clause_block_keys

  # Find the tail expression of a `:do` block (the last statement of a multi-
  # statement block, else the whole single-expression value) and append a
  # return-value candidate per `ReturnValue.replacement`. The candidates ride in
  # the tail node's own `meta[:mutare]` — *after* any operator candidates already
  # there — so emission builds one selector `case` hosting both an operator swap
  # and the return constant on the same node, ids in attachment order.
  defp attach_return(analyzed_value, raw_value) do
    map_tail(analyzed_value, raw_value, fn analyzed_tail, raw_tail ->
      case Mutare.Mutators.ReturnValue.replacements(raw_tail) do
        [] -> analyzed_tail
        replacements -> append_return_candidates(analyzed_tail, raw_tail, replacements)
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
          Enum.map(replacements, fn replacement ->
            %Candidate.Return{original: raw_tail, mutated: replacement, range: range}
          end)

        existing = Keyword.get(meta, :mutare, [])
        {form, Keyword.put(meta, :mutare, existing ++ candidates), args}

      _ ->
        node
    end
  end

  defp append_return_candidates(node, _raw_tail, _replacements), do: node

  # Force an `if`/`unless`/`cond` *condition* to `true`/`false` via the in-place
  # selector. `IfCondition.replacements/1` returns the `[true, false]` pair (or `[]`
  # when the condition is a boolean operator `Conditional` already forces, a literal,
  # or a binding `x = …` whose un-binding would poison the body — see that module).
  # Gated on the family being enabled, like `annotate_returns/3`. The candidates are
  # appended to the *analyzed* condition node — after any operator candidate already
  # there, so one selector hosts both — with `original`/`range` taken from the *raw*
  # condition for a clean diff.
  defp attach_if_condition(analyzed_condition, raw_condition, mutators) do
    case Spec.find(mutators, Mutare.Mutators.IfCondition) do
      nil ->
        analyzed_condition

      spec ->
        case Mutare.Mutators.IfCondition.replacements(raw_condition) do
          [] ->
            analyzed_condition

          replacements ->
            append_condition_candidates(analyzed_condition, raw_condition, replacements, spec)
        end
    end
  end

  # Append a `Candidate.InPlace` per replacement (`mutator` is the IfCondition
  # *spec*, since `Site.in_place/6` reads its `name`) to the condition node's
  # metadata, preserving any candidates already there. A condition we can't range
  # (Sourceror returns nil) or that is not a `{f, m, a}` node gets no mutant.
  defp append_condition_candidates({form, meta, args} = node, raw_condition, replacements, spec)
       when is_list(meta) do
    case NodeRange.get(raw_condition) do
      %{} = range ->
        candidates =
          Enum.map(replacements, fn mutated ->
            %Candidate.InPlace{
              mutator: spec,
              original: raw_condition,
              mutated: mutated,
              range: range
            }
          end)

        existing = Keyword.get(meta, :mutare, [])
        {form, Keyword.put(meta, :mutare, existing ++ candidates), args}

      _ ->
        node
    end
  end

  defp append_condition_candidates(node, _raw_condition, _replacements, _spec), do: node

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
  defp offer(subject, raw, mutators, context \\ %{piped: false}) do
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
