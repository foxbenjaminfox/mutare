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
  alias Mutare.Transform.{Candidate, PatternStructure}

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
  #   * `:owned` — a call argument a mutator has *claimed* (its optional
  #     `owned_args/2`): like `:pattern` it never mutates in place but keeps
  #     descending. Routed by `recurse_runtime/3` so a leaf the claimant already
  #     covers via the whole call (a ModeSwap unit/mode atom) isn't *also* mutated
  #     in place by another mutator (AtomLiteral → a redundant, raising `:mutare`).
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
  # `annotate_returns/3`).
  defp analyze({vis, meta, [head, body_kw]}, _context, mutators)
       when vis in [:def, :defp] and is_list(body_kw) do
    head = analyze(head, :pattern, mutators)
    analyzed_kw = analyze_do_blocks(body_kw, mutators)
    {vis, meta, [head, annotate_returns(analyzed_kw, body_kw, mutators)]}
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

  # match `=`: the left side is a pattern, the right keeps the context.
  defp analyze({:=, meta, [lhs, rhs]}, context, mutators) do
    {:=, meta, [analyze(lhs, :pattern, mutators), analyze(rhs, context, mutators)]}
  end

  # `<-` generator/with-clause: the left is a pattern (matched against each value
  # in `for x <- …`, or the right's result in `with {:ok, x} <- …`), the right keeps
  # the context. Mirrors `=` — without it a literal in the LHS would be mutated.
  defp analyze({:<-, meta, [lhs, rhs]}, context, mutators) do
    {:<-, meta, [analyze(lhs, :pattern, mutators), analyze(rhs, context, mutators)]}
  end

  # `match?(pattern, expr)`: a macro whose *first* argument is a match context, not
  # a runtime value — it expands to `case expr do pattern -> true; _ -> false end`.
  # So route it like `=`: the pattern side is `:pattern` (never mutated in place — a
  # selector `case` spliced there is "case not allowed in matches", and a literal
  # swap rewrites a pattern, not a value), the matched expression keeps the context.
  # Without this, mutating a string/tuple/atom literal inside the pattern poisons the
  # single build. Matches only the bare `match?/2` call (how it is always written);
  # a qualified `Kernel.match?/2` is rare enough to leave to the poison fallback.
  defp analyze({:match?, meta, [pattern, expr]}, context, mutators) do
    {:match?, meta, [analyze(pattern, :pattern, mutators), analyze(expr, context, mutators)]}
  end

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

  # `case`/`receive`/`fn`: runtime expressions whose *clause patterns* are additionally
  # mutatable by the structural pattern families (`PatternSwap`/`PatternWildcard`). None can
  # host a selector inside a pattern, and none is a liftable function clause group, so each
  # pattern mutant is delivered by wrapping the **whole** construct in an in-place selector
  # whose mutant branch is a copy with one clause's pattern restructured — sound because the
  # clause bindings of all three are local to a clause body and never escape. Each is still
  # analyzed normally (subject/bodies mutate; the `->` routing keeps patterns in `:pattern`),
  # and the `Candidate.CasePattern`s are attached so emission hosts them in the same selector.
  # The three differ only in *where the clauses live* and *how to rebuild the whole node*,
  # captured by the clause list + `rebuild_fn` passed to `attach_clause_pattern_candidates/4`.
  defp analyze({:case, meta, [subject, [{do_key, clauses}]]} = node, :runtime, mutators)
       when is_list(clauses) do
    rebuild = fn new -> {:case, meta, [subject, [{do_key, new}]]} end
    attach_clause_pattern_candidates(node, clauses, rebuild, mutators)
  end

  defp analyze({:receive, meta, [blocks]} = node, :runtime, mutators) when is_list(blocks) do
    {clauses, rebuild} = receive_do_clauses(blocks, meta)
    attach_clause_pattern_candidates(node, clauses, rebuild, mutators)
  end

  defp analyze({:fn, meta, clauses} = node, :runtime, mutators) when is_list(clauses) do
    rebuild = fn new -> {:fn, meta, new} end
    attach_clause_pattern_candidates(node, clauses, rebuild, mutators)
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
  # and sees the true arity; the LHS is an ordinary runtime expression. (Arity-blind
  # mutators are unaffected — they ignore the flag.)
  defp analyze({:|>, meta, [lhs, rhs]}, :runtime, mutators) do
    {:|>, meta, [analyze(lhs, :runtime, mutators), analyze_pipe_stage(rhs, mutators)]}
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
  defp analyze({form, _meta, _args} = node, :runtime, mutators) do
    node = offer(node, node, mutators)

    if sigil?(form),
      do: descend_sigil(node, mutators),
      else: recurse_runtime(node, mutators, false)
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
  # `hoist_pipe/1` lifts the pipe in — a mutated 0-arg `Enum.reverse()` stage becomes
  # `lhs |> Enum.reverse()`. A non-call RHS (rare) is analyzed normally.
  defp analyze_pipe_stage({_form, _meta, args} = node, mutators) when is_list(args) do
    node = offer(node, node, mutators, %{piped: true})
    recurse_runtime(node, mutators, true)
  end

  defp analyze_pipe_stage(other, mutators), do: analyze(other, :runtime, mutators)

  # One argument of a `for`: a generator/filter is descended as ordinary runtime,
  # while the trailing options/body keyword list keeps every option *key* raw —
  # `:into`/`:reduce`/`:uniq`/`:do` are `for`-special-form keywords, so mutating a key
  # is a compile error (`unsupported option :mutare given to for`), unlike a free-form
  # map/keyword key. The `:uniq` *value* must also be a literal boolean (a selector
  # there would poison the build), so it is held back; every other value (`:into`/
  # `:reduce` and the `:do`/`:reduce` body) descends as ordinary runtime.
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

  defp analyze_for_arg(arg, mutators), do: analyze(arg, :runtime, mutators)

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
  defp recurse_runtime({form, meta, args} = node, mutators, piped?) when is_list(args) do
    case owned_arg_indices(node, mutators, %{piped: piped?}) do
      [] ->
        recurse(node, :runtime, mutators)

      owned ->
        args =
          args
          |> Enum.with_index()
          |> Enum.map(fn {arg, i} ->
            analyze(arg, if(i in owned, do: :owned, else: :runtime), mutators)
          end)

        {form, meta, args}
    end
  end

  defp recurse_runtime(node, mutators, _piped?), do: recurse(node, :runtime, mutators)

  # The visible argument indices some active mutator claims exclusive ownership of at this
  # call (via the optional `owned_args/2` callback), unioned. Cheap when nobody implements
  # it — the `function_exported?/2` filter short-circuits before any call.
  defp owned_arg_indices(node, mutators, context) do
    for mutator <- mutators,
        function_exported?(mutator, :owned_args, 2),
        i <- mutator.owned_args(node, context),
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

  # === clause-list pattern structure mutation (case / receive / fn) ==========

  # Analyze the construct normally (bodies/subject mutate), then attach the structural
  # clause-pattern candidates so emission hosts them in the same in-place selector that
  # wraps the whole node. `clauses` is the construct's `->` clause list; `rebuild_fn`
  # rebuilds the whole node from a mutated clause list (the only thing that differs across
  # case/receive/fn). The node-level mutator offer is preserved for parity with the generic
  # runtime clause (a custom mutator matching the whole node; built-ins match none).
  defp attach_clause_pattern_candidates(node, clauses, rebuild_fn, mutators) do
    analyzed = recurse(node, :runtime, mutators)

    candidates =
      build_candidates(node, Mutator.mutations(node, mutators)) ++
        clause_list_candidates(clauses, rebuild_fn, PatternStructure.mutators(mutators))

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

  # For each clause and each *pattern position* in its head, run the structural mutators and
  # build a `Candidate.CasePattern` whose `replacement` is the whole construct with just that
  # one position restructured (raw clauses → first-order, no nested selectors, like a lifted
  # mutant clause). The diff stays focused on the single changed pattern (always rangeable —
  # Sourceror block-wraps a clause pattern).
  defp clause_list_candidates(_clauses, _rebuild_fn, []), do: []

  defp clause_list_candidates(clauses, rebuild_fn, structural) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      replace_clause = fn new_clause ->
        rebuild_fn.(List.replace_at(clauses, index, new_clause))
      end

      clause_pattern_candidates(clause, replace_clause, structural)
    end)
  end

  defp clause_pattern_candidates(clause, replace_clause, structural) do
    case clause_patterns(clause) do
      nil ->
        []

      {patterns, used} ->
        patterns
        |> Enum.with_index()
        |> Enum.flat_map(&position_candidates(&1, clause, replace_clause, used, structural))
    end
  end

  defp position_candidates({pattern, pos}, clause, replace_clause, used, structural) do
    case Sourceror.get_range(pattern) do
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
    if Mutare.Mutators.ReturnValue in mutators do
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
    case Sourceror.get_range(raw_tail) do
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
    if Mutare.Mutators.IfCondition in mutators do
      case Mutare.Mutators.IfCondition.replacements(raw_condition) do
        [] ->
          analyzed_condition

        replacements ->
          append_condition_candidates(analyzed_condition, raw_condition, replacements)
      end
    else
      analyzed_condition
    end
  end

  # Append a `Candidate.InPlace` per replacement (`mutator` is the IfCondition
  # *module*, since `Site.in_place/6` calls `.name()` on it) to the condition node's
  # metadata, preserving any candidates already there. A condition we can't range
  # (Sourceror returns nil) or that is not a `{f, m, a}` node gets no mutant.
  defp append_condition_candidates({form, meta, args} = node, raw_condition, replacements)
       when is_list(meta) do
    case Sourceror.get_range(raw_condition) do
      %{} = range ->
        candidates =
          Enum.map(replacements, fn mutated ->
            %Candidate.InPlace{
              mutator: Mutare.Mutators.IfCondition,
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

  defp append_condition_candidates(node, _raw_condition, _replacements), do: node

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
    range = Sourceror.get_range(node)

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

  def analyze_module_macro_block({form, meta, args}, mutators) do
    {init, [last]} = Enum.split(args, -1)
    init = Enum.map(init, &analyze(&1, :scaffold, mutators))
    {form, meta, init ++ [analyze_module_macro_block_arg(last, mutators)]}
  end

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
