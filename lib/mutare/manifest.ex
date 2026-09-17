defmodule Mutare.Manifest do
  @moduledoc """
  A map from mutant ids to their generated line ranges in a rendered metamutant,
  and a list of every place the generated code names a mutant id.

  `Mutare.Transform` writes the metamutant; this is what `Mutare.Poison` reads
  back. It is built **lazily** (`from_source/2`), by `Mutare.Poison` on a failed
  compile, only for the file(s) the error names — not eagerly during the scan,
  where re-parsing every rendered metamutant was the scan's dominant cost yet is
  read only when a compile actually fails (rare — built-in mutators are
  compile-safe). `Poison` memoizes it within one recovery so a file faulting on
  several lines is walked once.

  The one exception is `verify_invariants: true` (`mix mutare --verify-invariants`):
  the transform then builds a manifest for every file it renders and compares its
  `:mentions` with the mutants it recorded, raising `Mutare.InvariantError` on a
  mismatch.

  **`Mutare.Poison`** uses each mutant's *generated ranges* — the metamutant line
  spans of the code that exists only because of that mutant, so a compile error's
  line maps back to the corresponding mutant id.

  (Coverage is recorded separately: the metamutant self-records coverage at runtime
  — see `Mutare.Coverage.Recorder` — keyed by mutant id directly, so there is no
  metamutant `{module, line}` location to precompute.)

  ## Why ranges, not a single line

  Poison recovery used to match a compile error's line against the *start line of
  a selector clause body* only. That missed every poison whose bad code isn't on
  that exact line:

    * **lifted mutations** — a guard/head-pattern mutant's code appears in a generated
      `defp <base>(mutare_active, …) when mutare_active === <id> …` clause, not in
      the dispatcher (which only forwards). The error points into that gated clause,
      away from the dispatcher;
    * **multiline bodies** — an in-place mutant whose body spans several lines can
      fault on any of them, not just the first;
    * **structural errors** — the compiler sometimes points at the surrounding
      `case` rather than a clause body.

  So we record, per mutant, the *full* line ranges of its generated code:

    * each selector clause body (`<id> -> <mutated>`) — catches in-place mutants,
      including multiline bodies;
    * each lifted mutant clause (gated `when mutare_active === <id>`) — catches a
      guard/head-pattern poison, whose code is outside the dispatcher;
    * the whole selector `case`, attributed to *all* the mutant ids it hosts — the
      coarse fallback for a structural error that points at the `case` itself.

  `ids_at_line/2` resolves an error line by **narrowest containing range**: a line
  inside a specific clause/def range maps to that one mutant; only when nothing
  narrower contains it does the whole-`case` fallback fire (dropping every mutant
  the `case` hosts — a bounded over-drop that still recovers the build, never the
  old "couldn't map it → abort").

  Ranges are in **metamutant line space**, which only exists after rendering, so
  the manifest is built by re-parsing the rendered metamutant and ranging its
  generated nodes with `Sourceror.get_range/1`, recognising selectors via
  `Mutare.Metamutant.subject?/2`. A selector inside a function body reads the
  file's **dispatch variable** rather than `:persistent_term` directly, and a
  lifted or tupled mutant clause is gated on it (`<var> === <id>`) — so that name
  must be supplied to the reader. It is per file (`:mutare_active`, or a salted variant
  when the source already uses that identifier), chosen by the transform and
  handed out with the metamutant (`Mutare.Transform.Result.dispatch_var`,
  `Mutare.Schema`'s `:dispatch_vars`); `from_source/2` takes it alongside the source.

  The re-parse uses Elixir's own `Code.string_to_quoted!` (with `:token_metadata`
  + `:columns`), **not** `Sourceror.parse_string!`. `get_range/1` only needs that
  token metadata (`:line`/`:column`/`:closing`/`:end`/`:end_of_expression`), which
  the stdlib parser already produces; what `Sourceror.parse_string!` *adds* is a
  comment-merging pass that is quadratic on a large metamutant (a lifted 1.8 MB
  file re-parses in ~0.6 s here, versus minutes for Sourceror) and that the
  manifest never reads. A `:literal_encoder` reproduces Sourceror's
  `{:__block__, meta, [literal]}` wrapping so the recognisers — already tolerant of
  both shapes — accept the resulting nodes; the two parses yield identical
  ranges. (Sourceror is still the *renderer*; only this readback parse changed.)
  """

  alias Mutare.AST
  alias Mutare.Coverage.Recorder
  alias Mutare.Metamutant

  @typedoc "A generated line range and the mutant ids whose code occupies it."
  @type region :: %{ids: [pos_integer()], lo: pos_integer(), hi: pos_integer()}

  @typedoc """
  One place where the generated code names a mutant id:

    * `:branch` — code that runs only while `id` is active: a selector clause body, a gated
      clause (lifted, tupled, `fn`, `receive`), or a gated guard alternative;
    * `:exclusion` — an original clause stepping aside while `id` is active (`<var> =/= <id>`,
      or the range form for a run of ids). A dropped clause leaves only this trace;
    * `:record` — a coverage record listing `id`.

  `within` is the id of the innermost mutant branch enclosing the mention, or `nil` outside
  every branch. Code inside mutant `k`'s branch runs only while `k` is active, so a run that
  activates `id` alone reaches the mention only when `within` is `nil` or `id`.
  """
  @type mention :: %{
          kind: :branch | :exclusion | :record,
          id: pos_integer(),
          within: pos_integer() | nil
        }

  @typedoc """
  One file's manifest:

    * `:regions` — generated line ranges, for mapping a compile error back to a mutant.
    * `:mentions` — every generated mention of a mutant id, in source order, for
      `Mutare.Transform.Invariants` to check against the mutants the transform recorded.
    * `:ast` — the parsed metamutant the regions were ranged over, retained so the
      macro-expansion fallback (`ids_in_named_calls/2`) can range a blamed macro's calls in
      the same tree rather than parse the file a second time. `nil` on a hand-built manifest.
  """
  @type t :: %__MODULE__{regions: [region()], mentions: [mention()], ast: Macro.t() | nil}

  defstruct regions: [], mentions: [], ast: nil

  @doc """
  Build a manifest from one file's rendered metamutant source and its dispatch variable.

  Re-parses (for `Sourceror.get_range/1`) and walks the tree once, attributing
  every selector clause, lifted private definition, and selector `case` to the
  mutant id(s) it belongs to, and collecting every mention of an id (`t:mention/0`). `dispatch_var` is the name the transform chose for this
  file (`Mutare.Transform.Result.dispatch_var`): the hoisted selectors read it as their
  subject and the gated mutant clauses compare it, so it is what makes them recognisable.
  The parse is kept on the manifest (`:ast`): one failed compile can need both
  attributions of the same file, and `Mutare.Poison` holds one manifest per file for the
  round.

  ## Examples

      iex> source = "defmodule Demo do\\n  def add(a, b), do: a + b\\nend\\n"
      iex> result = Mutare.transform_string(source, mutators: [:arithmetic])
      iex> %Mutare.Manifest{regions: regions} =
      ...>   Mutare.Manifest.from_source(result.metamutant, result.dispatch_var)
      iex> regions == []
      false
  """
  @spec from_source(String.t(), atom()) :: t()
  def from_source(metamutant_source, dispatch_var) when is_atom(dispatch_var) do
    ast = parse(metamutant_source)
    %{build(ast, dispatch_var) | ast: ast}
  end

  # Region and mention build over an already-parsed metamutant AST, threading the dispatch
  # variable to the recognisers (a hoisted selector's bare-variable subject, a mutant clause's
  # gate). Both accumulate reversed; the walk starts outside every mutant branch.
  defp build(ast, var) do
    {regions, mentions} = walk(ast, nil, var, {[], []})
    %__MODULE__{regions: Enum.reverse(regions), mentions: Enum.reverse(mentions)}
  end

  @doc """
  Mutant ids inside a call to one of `names`, grouped by that call's function name.

  The **macro-expansion fallback**'s attribution (`Mutare.Poison.macro_poison/4`): when a
  mutation splices a selector `case` into an argument a macro rewrites at compile time, the
  macro raises during expansion and the compiler reports the macro *call* line — which no
  region covers — so `ids_at_line/2` finds nothing. Given the macro name from the compiler's
  `expanding macro:` frame, this instead finds every call of that name in the rendered
  metamutant, takes its **full** line range (`Sourceror.get_range/1`, to the closing
  delimiter — so a literal argument on its own line is still spanned), and collects the ids of
  every region contained in it.

  Works in **metamutant space**: the rendered source is what the compiler read, so the ids
  found inside a blamed macro's span are exactly the ones that could have poisoned it — no
  mapping back to original-source coordinates is needed, or possible. Reads the manifest's
  retained `:ast` (a `from_source/2` manifest, whose regions were ranged with the file's
  dispatch variable), so the file is parsed once for both attributions. Returns
  `%{fun_atom => MapSet.t()}`, empty when nothing matched.
  """
  @spec ids_in_named_calls(t(), MapSet.t(atom())) :: %{optional(atom()) => MapSet.t()}
  def ids_in_named_calls(%__MODULE__{ast: ast, regions: regions}, names) when not is_nil(ast) do
    ast
    |> named_call_ranges(names)
    |> Enum.reduce(%{}, fn {name, lo, hi}, acc ->
      ids = ids_in_range(regions, lo, hi)
      if Enum.empty?(ids), do: acc, else: Map.update(acc, name, ids, &MapSet.union(&1, ids))
    end)
  end

  # `{fun_name, lo, hi}` for every call — bare (`foo(a)`) or qualified (`Mod.foo(a)`) — whose
  # name is in `names`, ranged to its closing delimiter. A call Sourceror can't range is
  # dropped (nothing to attribute).
  #
  # A `def`/`defmacro` *head* is shaped exactly like a call (`def query(a \\ 1)` parses to
  # `{:query, _, [...]}`), so a function merely sharing the blamed macro's name would have its
  # head matched and its default/guard mutations dropped as poison. We *neutralise* just the
  # head's outer call node — replace it with a `:__block__` of its arguments — so the head name
  # can't match, yet its default and guard expressions are still traversed: a literal-only macro
  # inside a default (`def limit(n \\ Size.megabytes(5))`) poisons there too and must be found.
  # `Macro.traverse` (not `prewalk`) so the pre-hook can hand back the rewritten node to keep
  # walking.
  defp named_call_ranges(ast, names) do
    {_ast, calls} =
      Macro.traverse(ast, [], &enter_named_call(&1, &2, names), fn node, acc -> {node, acc} end)

    calls
  end

  defp enter_named_call({kw, meta, [head | body]}, acc, _names)
       when kw in [:def, :defp, :defmacro, :defmacrop] and is_list(body),
       do: {{kw, meta, [neutralize_head(head) | body]}, acc}

  defp enter_named_call(node, acc, names) do
    case named_call(node, names) do
      nil -> {node, acc}
      call -> {node, [call | acc]}
    end
  end

  # Open a definition head's outer call node (`f(args)` → a `:__block__` of `args`) so the head
  # name is no longer a call to match, while its arguments — defaults, patterns — stay in the
  # walk. A guarded head (`f(args) when g`) keeps the `when` so the guard is walked too; a
  # non-call head shape (a no-arg `def f`) is left as-is (it can't match a call anyway).
  defp neutralize_head({:when, meta, [call, guard]}), do: {:when, meta, [open_head(call), guard]}
  defp neutralize_head(head), do: open_head(head)

  defp open_head({_name, meta, args}) when is_list(args), do: {:__block__, meta, args}
  defp open_head(other), do: other

  # A piped call `lhs |> fun(...)`: after pipe expansion `lhs` is `fun`'s *first* argument, so a
  # mutation in `lhs` renders as a selector `case` on the pipe's left — *before* the RHS call
  # node's own range. Range the whole `|>` node (its LHS-through-RHS span, via `Sourceror`)
  # under the RHS call's name, so the piped value and every earlier stage feeding this macro are
  # covered. Must precede the generic call clause below: `{:|>, meta, [lhs, rhs]}` also matches
  # `{fun, _, args}` with `fun` = `:|>`, which would (harmlessly, but uselessly) range nothing.
  defp named_call({:|>, _meta, [_lhs, rhs]} = node, names) do
    case piped_name(rhs) do
      nil -> nil
      fun -> if MapSet.member?(names, fun), do: call_range(fun, node)
    end
  end

  defp named_call({fun, _meta, args} = node, names) when is_atom(fun) and is_list(args),
    do: if(MapSet.member?(names, fun), do: call_range(fun, node))

  defp named_call({{:., _, [_module, fun]}, _meta, args} = node, names)
       when is_atom(fun) and is_list(args),
       do: if(MapSet.member?(names, fun), do: call_range(fun, node))

  defp named_call(_node, _names), do: nil

  # The function name of a `|>`'s right-hand stage — a call `fun(...)`, a bare `fun` (no parens,
  # the piped value is its only argument), or a qualified `Mod.fun`. `nil` for anything that
  # isn't a call in pipe position.
  defp piped_name({fun, _meta, args}) when is_atom(fun) and is_list(args), do: fun
  defp piped_name({fun, _meta, ctx}) when is_atom(fun) and is_atom(ctx), do: fun
  defp piped_name({{:., _, [_module, fun]}, _meta, _args}) when is_atom(fun), do: fun
  defp piped_name(_), do: nil

  defp call_range(name, node) do
    case Sourceror.get_range(node) do
      %{start: start, end: stop} ->
        lo = start[:line]
        hi = stop[:line]
        if is_integer(lo) and is_integer(hi), do: {name, lo, hi}

      _ ->
        nil
    end
  end

  # Every mutant id whose region is contained in `[lo, hi]` — the mutants living inside a
  # macro call's span. Containment (not overlap): a selector `case` spliced into an argument
  # sits wholly within the call, and dropping every mutant inside a macro that poisons is the
  # intended wholesale skip.
  defp ids_in_range(regions, lo, hi) do
    for r <- regions, lo <= r.lo, r.hi <= hi, id <- r.ids, into: MapSet.new(), do: id
  end

  # Parse the rendered metamutant into an AST `Sourceror.get_range/1` can range.
  # `Code.string_to_quoted!` with `:token_metadata`/`:columns` gives `get_range`
  # everything it reads, far faster than `Sourceror.parse_string!` (whose extra
  # comment-merging pass is quadratic on a megabyte-scale lifted file). The
  # `:literal_encoder` mirrors Sourceror's `{:__block__, meta, [literal]}` wrapping
  # so the recognisers (`Metamutant.subject?/2`, `clause_id/1`, `AST.key_atom/1`) see
  # the shape they already handle — the two parses produce identical ranges.
  defp parse(source) do
    Code.string_to_quoted!(source,
      columns: true,
      token_metadata: true,
      literal_encoder: fn literal, meta -> {:ok, {:__block__, meta, [literal]}} end
    )
  end

  @doc """
  Mutant ids whose generated code occupies `line`.

  Resolved by **narrowest containing range**: a specific clause/def range beats the
  coarse whole-`case` fallback, so a precise error drops exactly the offending
  mutant; a structural error that only the `case` range contains drops every mutant
  it hosts. Returns `[]` when no generated code spans `line`.

  ## Examples

      iex> manifest = %Mutare.Manifest{
      ...>   regions: [
      ...>     %{ids: [1, 2], lo: 3, hi: 8},
      ...>     %{ids: [1], lo: 5, hi: 5}
      ...>   ]
      ...> }
      iex> Mutare.Manifest.ids_at_line(manifest, 5)
      [1]
      iex> Mutare.Manifest.ids_at_line(manifest, 4)
      [1, 2]
      iex> Mutare.Manifest.ids_at_line(manifest, 99)
      []
  """
  @spec ids_at_line(t(), pos_integer()) :: [pos_integer()]
  def ids_at_line(%__MODULE__{regions: regions}, line) do
    case Enum.filter(regions, fn r -> r.lo <= line and line <= r.hi end) do
      [] ->
        []

      containing ->
        min_span = containing |> Enum.map(&(&1.hi - &1.lo)) |> Enum.min()

        containing
        |> Enum.filter(&(&1.hi - &1.lo == min_span))
        |> Enum.flat_map(& &1.ids)
        |> Enum.uniq()
    end
  end

  # --- traversal -----------------------------------------------------------

  # One pre-order walk over the parsed metamutant, threading `within`: the id of the innermost
  # mutant branch enclosing the current node (`nil` outside every branch). A recognised
  # construct records its regions and mentions *before* its children are walked, and walks the
  # children itself, entering each mutant branch with that mutant's id; every other node is
  # descended generically, in `Macro.traverse/4`'s child order. The accumulator is
  # `{regions, mentions}`, both reversed.
  #
  # A coverage record is recognised first: it names ids but holds no mutant code, so the walk
  # does not enter it.
  defp walk(node, within, var, acc) do
    case Recorder.recorded_ids(node) do
      {:ok, ids} -> mention(acc, :record, ids, within)
      :error -> walk_node(node, within, var, acc)
    end
  end

  # A `case` selector. Two shapes:
  #
  #   * a *selector subject* `case` (in-place selector or lifted dispatcher) — each mutant
  #     clause is `<id> -> <mutated>`, so the id is its clause *pattern*; record each mutant
  #     clause's body range.
  #   * a *tupled* subject `case` (the tuple-the-scrutinee path) — each mutant clause is
  #     `{mutare_active, <pat>} when mutare_active === <id> … -> <body>`, so the id is in its
  #     `when` gate and the mutated code (pattern/guard) lives in the *head*; record the whole
  #     mutant clause range.
  #
  # Both add a whole-`case` fallback (every id the `case` hosts) as a coarse backstop.
  #
  # A selector's subject is either the inline `:persistent_term` read or — once the read
  # is hoisted (a selector inside a function body) — a bare reference to the dispatch
  # variable. The (per-file, possibly salted) variable name is the `var` the caller supplied
  # (`from_source/2`), threaded to both the subject recognisers (a hoisted bare-variable
  # subject) and the tupled-clause gate matcher (`pattern_mutant`). A user `case some_var do …`
  # is never mistaken for a selector: the dispatch name is salted away from every identifier
  # the source uses, so it can't equal a user scrutinee's name.
  #
  # A plain selector's subject (the active-id read, or its namespace projection) names no
  # mutant, so only its clauses are walked; a tupled subject holds the construct's coverage
  # record, so it is walked first.
  defp walk_node({:case, _meta, [subject, kw]} = node, within, var, acc) do
    cond do
      Metamutant.subject?(subject, var) ->
        walk_clauses(node, [], do_block(kw), within, var, acc, &selector_mutant/1)

      Metamutant.pattern_subject?(subject, var) ->
        walk_clauses(node, [subject], do_block(kw), within, var, acc, &pattern_mutant(&1, var))

      true ->
        descend(node, within, var, acc)
    end
  end

  # A lifted mutant clause (`defp <base>(mutare_active, …) when mutare_active ===
  # <id> …`): its whole definition is that mutant's generated code — where a guard /
  # head-pattern poison lives. Original clauses (gated `mutare_active !== …`) and the
  # dispatcher carry no gate, so `mutant_id/1` returns `nil`; an original's exclusions are
  # mentioned, which is how a dropped clause shows up at all.
  defp walk_node({vis, _meta, [head | _]} = node, within, var, acc) when vis in [:def, :defp] do
    case mutant_id(head, var) do
      nil ->
        acc
        |> mention(:exclusion, guard_exclusions(head, var), within)
        |> then(&descend(node, within, var, &1))

      id ->
        acc
        |> record_branches([{id, node}], nil, within)
        |> then(&descend(node, id, var, &1))
    end
  end

  # Per-clause fn delivery uses the same activation guard as tupled cases. Attribute
  # each entire mutant clause (including its head), plus the whole fn as a fallback
  # for structural errors. Ungated source fns and gated originals produce no regions.
  defp walk_node({:fn, _meta, clauses} = node, within, var, acc),
    do: walk_clauses(node, [], clauses, within, var, acc, &pattern_mutant(&1, var))

  # Receive message clauses carry the same per-clause activation gates. The after block
  # is not a message clause; its own body selectors are visited normally by the walk.
  defp walk_node({:receive, _meta, [blocks]} = node, within, var, acc) do
    case do_block(blocks) do
      clauses when is_list(clauses) ->
        acc = walk_clauses(node, [], clauses, within, var, acc, &pattern_mutant(&1, var))
        after_blocks = for {key, value} <- blocks, AST.key_atom(key) != :do, do: value
        walk(after_blocks, within, var, acc)

      _ ->
        descend(node, within, var, acc)
    end
  end

  # A guard-sequence construct (`ClauseGuardEmit`): a `with`/`for` `<-` clause or a
  # `with`/`try` `else`, `try` `catch`, `for … reduce:` `do` arrow clause whose guard carries
  # one `<var> === <id> and …` alternative per mutant. Each alternative is that mutant's
  # generated code; the whole construct is the fallback. Only the construct's *own* clause
  # heads are read — a nested construct is entered on its own. The clause bodies are shared by
  # the mutant and original alternatives, so no branch scope is entered here.
  defp walk_node({form, _meta, [_ | _] = args} = node, within, var, acc)
       # mutare:ignore[conditional:true] equivalent — every other call this admits has no gated arrow clause: `case`, `fn` and `receive` are matched above, so nothing is found and nothing is recorded
       when form in [:with, :for, :try] do
    heads = clause_heads(args)
    mutants = for head <- heads, {id, alt} <- sequence_mutants(head, var), do: {id, alt}
    exclusions = Enum.flat_map(heads, &guard_exclusions(&1, var))

    acc
    |> record_branches(mutants, node, within)
    |> mention(:exclusion, exclusions, within)
    |> then(&descend(node, within, var, &1))
  end

  defp walk_node(node, within, var, acc), do: descend(node, within, var, acc)

  # The children of an unrecognised node, in `Macro.traverse/4` order: a call's callee, then its
  # arguments (an atom in either place — a local call's name, a variable's context — is a leaf);
  # a list's elements; a two-tuple's halves.
  defp descend({form, _meta, args}, within, var, acc),
    do: walk(args, within, var, walk(form, within, var, acc))

  defp descend(list, within, var, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, within, var, &2))

  defp descend({left, right}, within, var, acc),
    do: walk(right, within, var, walk(left, within, var, acc))

  defp descend(_leaf, _within, _var, acc), do: acc

  # Record a construct's mutant clauses, then walk its `leading` children (a `case` subject)
  # and its clauses. `extract.(clause)` yields `{id, region_node}` (the node whose range is that
  # mutant's generated code, and which runs only while `id` is active) or `{nil, _}` for a
  # non-mutant clause (catch-all, gated original), whose exclusions are mentioned instead.
  defp walk_clauses(node, leading, clauses, within, var, acc, extract) do
    extracted = Enum.map(clauses, &{&1, extract.(&1)})
    mutants = for {_clause, {id, region}} <- extracted, id != nil, do: {id, region}

    acc =
      acc
      |> record_branches(mutants, node, within)
      |> then(&walk(leading, within, var, &1))

    Enum.reduce(extracted, acc, fn
      {clause, {nil, _region}}, acc ->
        acc
        |> mention(:exclusion, clause_exclusions(clause, var), within)
        |> then(&walk(clause, within, var, &1))

      {_clause, {id, region}}, acc ->
        walk(region, id, var, acc)
    end)
  end

  # Each mutant's region and `:branch` mention, then the whole-construct fallback region
  # over all of them (`nil` construct: no fallback, as for a lifted clause).
  defp record_branches({regions, mentions}, mutants, construct, within) do
    {regions, mentions} =
      Enum.reduce(mutants, {regions, mentions}, fn {id, region}, {regions, mentions} ->
        {push(range_region([id], region), regions),
         [%{kind: :branch, id: id, within: within} | mentions]}
      end)

    {push(case_fallback(construct, mutants), regions), mentions}
  end

  defp mention({regions, mentions}, kind, ids, within) do
    {regions, Enum.reduce(ids, mentions, &[%{kind: kind, id: &1, within: within} | &2])}
  end

  # A selector-`case` mutant clause `<id> -> <body>`: the id is its integer pattern; its
  # generated code is the body. A catch-all (`mutare_active -> …`) yields `{nil, nil}`.
  defp selector_mutant({:->, _, [[patt], body]}), do: {clause_id(patt), body}

  # A tupled-`case` mutant clause `{mutare_active, <pat>} when mutare_active === <id> … ->
  # <body>`: the id is in the `when` gate, and its generated code (the mutated pattern/guard)
  # is in the head, so the whole clause is the region. A gated original (`!==`) / unguarded
  # original yields `{nil, nil}`.
  defp pattern_mutant({:->, _, [[{:when, _wm, when_args}], _body]} = clause, var) do
    case when_args |> List.last() |> gate_id(var) do
      nil -> {nil, nil}
      id -> {id, clause}
    end
  end

  defp pattern_mutant(_, _), do: {nil, nil}

  # The `when` heads of a `with`/`for`/`try`'s own clauses: its leading `<-` arguments plus
  # the arrow clauses of every block in its trailing keyword list.
  defp clause_heads(args) do
    {leading, trailing} = Enum.split(args, -1)

    generator_heads = for {:<-, _, [{:when, _, _} = head, _rhs]} <- leading, do: head

    arrow_heads =
      for blocks when is_list(blocks) <- trailing,
          {_key, clauses} <- blocks,
          {:->, _, [[{:when, _, _} = head], _body]} <- List.wrap(unwrap_clauses(clauses)),
          do: head

    generator_heads ++ arrow_heads
  end

  defp unwrap_clauses({:__block__, _meta, [clauses]}) when is_list(clauses), do: clauses
  defp unwrap_clauses(clauses), do: clauses

  # The `{id, alternative}` pairs of a guard sequence: the trailing guard's `when`
  # alternatives (right-nested, as parsed) that carry a gate. A gated original (`=/=`
  # exclusion) and an unmutated guard yield nothing.
  defp sequence_mutants({:when, _meta, when_args}, var) do
    # The match is a filter: an ungated alternative's `nil` gate drops it.
    for alt <- when_args |> List.last() |> alternatives(), id = gate_id(alt, var), do: {id, alt}
  end

  defp alternatives({:when, _meta, alts}), do: Enum.flat_map(alts, &alternatives/1)
  defp alternatives(guard), do: [guard]

  # --- exclusions ----------------------------------------------------------

  # The ids an arrow clause's guard steps aside for; a guardless clause excludes nothing.
  defp clause_exclusions({:->, _, [[{:when, _, _} = head], _body]}, var),
    do: guard_exclusions(head, var)

  defp clause_exclusions(_clause, _var), do: []

  # The ids a `when` head's guard (its last operand: a definition's `f(…) when g`, a clause's
  # `p1, p2 when g`, possibly itself a `when` sequence) steps aside for.
  defp guard_exclusions({:when, _meta, operands}, var),
    do: operands |> List.last() |> exclusions(var)

  defp guard_exclusions(_head, _var), do: []

  # Every id an exclusion guard names, in both of `Mutare.Transform.GuardBuild.exclusion/2`'s
  # forms: `<var> =/= <id>`, and `<var> < <first> orelse <var> > <last>` for a run of ids
  # (`first..last`, every id of which is excluded). Read through `AST.erlang_call_args/2`, the
  # builder's inverse; only comparisons of the dispatch variable `var` with an integer literal
  # match, so a source guard's own comparisons are skipped. A generated guard joins its
  # comparisons with `:erlang` calls alone, so the search descends through call arguments only.
  defp exclusions({_form, _meta, args} = node, var) when is_list(args) do
    case excluded(node, var) do
      {:ok, ids} -> ids
      :error -> Enum.flat_map(args, &exclusions(&1, var))
    end
  end

  defp exclusions(_leaf, _var), do: []

  defp excluded(node, var) do
    with :error <- excluded_id(node, var), do: excluded_run(node, var)
  end

  defp excluded_id(node, var) do
    with {:ok, [{^var, _, _}, id_node]} <- AST.erlang_call_args(node, :"=/="),
         id when is_integer(id) <- literal_int(id_node) do
      {:ok, [id]}
    else
      _ -> :error
    end
  end

  defp excluded_run(node, var) do
    with {:ok, [below, above]} <- AST.erlang_call_args(node, :orelse),
         {:ok, [{^var, _, _}, first_node]} <- AST.erlang_call_args(below, :<),
         {:ok, [{^var, _, _}, last_node]} <- AST.erlang_call_args(above, :>),
         first when is_integer(first) <- literal_int(first_node),
         last when is_integer(last) <- literal_int(last_node) do
      {:ok, Enum.to_list(first..last//1)}
    else
      _ -> :error
    end
  end

  # --- regions -------------------------------------------------------------

  # The whole `case`, attributed to every mutant id it hosts: the coarse fallback
  # for a structural error pointing at the `case` rather than a clause body.
  defp case_fallback(_case_node, []), do: nil
  defp case_fallback(nil, _mutants), do: nil

  defp case_fallback(case_node, mutants),
    do: range_region(Enum.map(mutants, &elem(&1, 0)), case_node)

  defp range_region(ids, node) do
    case Sourceror.get_range(node) do
      %{start: start, end: stop} ->
        lo = start[:line]
        hi = stop[:line]
        if is_integer(lo) and is_integer(hi), do: %{ids: ids, lo: lo, hi: hi}

      _ ->
        nil
    end
  end

  # Prepend a region, skipping a `nil` (a node Sourceror couldn't range).
  defp push(nil, acc), do: acc
  defp push(region, acc), do: [region | acc]

  # --- selector shape ------------------------------------------------------

  # The `do:` clause list of a `case`, tolerant of Sourceror's keyword-key wrapping.
  defp do_block(kw) when is_list(kw) do
    Enum.find_value(kw, fn
      {key, value} -> if AST.key_atom(key) == :do, do: value
      _ -> nil
    end)
  end

  defp do_block(_), do: nil

  # The integer pattern of a mutant clause (`<id> -> …`); `nil` for the catch-all.
  # Sourceror wraps the literal in a `:__block__`; a bare integer is also accepted.
  # Namespace projections also switch on the global selector but their zero
  # branch is baseline, never a mutant or a poison-attribution fallback.
  defp clause_id({:__block__, _meta, [id]}) when is_integer(id) and id > 0, do: id
  defp clause_id(id) when is_integer(id) and id > 0, do: id
  defp clause_id(_), do: nil

  # The mutant id a *lifted mutant clause* carries in its `when <var> === <id> …`
  # gate (the leftmost conjunct `Transform.lifted_mutant/3` emits), or `nil` for
  # everything else: a lifted *original* clause (gated `<var> !== …`), the public
  # dispatcher, and user code. This is how a poison inside a generated guard/head
  # maps back to its mutant now that each lifted mutant is a single gated clause
  # rather than a `_m<id>`-named full copy. `var` is the (possibly salted) dispatch
  # variable name the caller supplied.
  defp mutant_id({:when, _meta, [_call | guards]}, var),
    do: Enum.find_value(guards, &gate_id(&1, var))

  defp mutant_id(_, _), do: nil

  # Find a `<var> === <id>` gate anywhere in a guard, returning `<id>`. `Transform.GuardBuild`
  # emits it as the explicit `:erlang."=:="/2` call no target import can redirect, so that is
  # the form recognised here — the two must move together. Only a gate against the dispatch
  # variable `var` matches: a source guard's own `===` (LHS some other var) is skipped, and the
  # originals' `=/=` exclusions never match, so a clause is a mutant iff this finds an id. The
  # first clause pins the LHS atom to `var` by repeating the binding name in the head (an
  # equality match), so a mismatching gate falls through to the recursive descent instead.
  defp gate_id({_form, _meta, args} = node, var) when is_list(args) do
    with {:ok, [{^var, _, _}, id_node]} <- AST.erlang_call_args(node, :"=:="),
         id when is_integer(id) and id > 0 <- literal_int(id_node) do
      id
    else
      _ -> Enum.find_value(args, &gate_id(&1, var))
    end
  end

  defp gate_id(list, var) when is_list(list), do: Enum.find_value(list, &gate_id(&1, var))
  defp gate_id({left, right}, var), do: gate_id(left, var) || gate_id(right, var)
  defp gate_id(_, _), do: nil

  defp literal_int({:__block__, _meta, [id]}) when is_integer(id), do: id
  defp literal_int(id) when is_integer(id), do: id
  defp literal_int(_), do: nil
end
