defmodule Mutare.Manifest do
  @moduledoc """
  A per-mutant map of where each mutant lives in its rendered metamutant.

  `Mutare.Transform` writes the metamutant; this is what `Mutare.Poison` reads
  back. It is built **lazily** (`from_source/1`), by `Mutare.Poison` on a failed
  compile, only for the file(s) the error names — not eagerly during the scan,
  where re-parsing every rendered metamutant was the scan's dominant cost yet is
  read only when a compile actually fails (rare — built-in mutators are
  compile-safe). `Poison` memoizes it within one recovery so a file faulting on
  several lines is walked once.

  **`Mutare.Poison`** wants each mutant's *generated ranges* — the metamutant line
  spans of the code that exists only because of that mutant, so a compile error's
  line maps back to the mutant id that owns it.

  (Coverage no longer lives here: the metamutant self-records coverage at runtime
  — see `Mutare.Coverage.Recorder` — keyed by mutant id directly, so there is no
  metamutant `{module, line}` location to precompute.)

  ## Why ranges, not a single line

  Poison recovery used to match a compile error's line against the *start line of
  a selector clause body* only. That missed every poison whose bad code isn't on
  that exact line:

    * **lifted mutations** — a guard/head-pattern mutant's code lives in a generated
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
      guard/head-pattern poison, whose code lives away from the dispatcher;
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
  `Mutare.Metamutant.subject?/2`.

  The re-parse uses Elixir's own `Code.string_to_quoted!` (with `:token_metadata`
  + `:columns`), **not** `Sourceror.parse_string!`. `get_range/1` only needs that
  token metadata (`:line`/`:column`/`:closing`/`:end`/`:end_of_expression`), which
  the stdlib parser already produces; what `Sourceror.parse_string!` *adds* is a
  comment-merging pass that is quadratic on a large metamutant (a lifted 1.8 MB
  file re-parses in ~0.6 s here, versus minutes for Sourceror) and that the
  manifest never reads. A `:literal_encoder` reproduces Sourceror's
  `{:__block__, meta, [literal]}` wrapping so the recognisers — already tolerant of
  both shapes — see exactly what they did before; the two parses yield identical
  ranges. (Sourceror is still the *renderer*; only this readback parse changed.)
  """

  alias Mutare.AST
  alias Mutare.Coverage.Recorder
  alias Mutare.Metamutant
  alias Mutare.Transform.Names

  @typedoc "A generated line range and the mutant ids whose code occupies it."
  @type region :: %{ids: [pos_integer()], lo: pos_integer(), hi: pos_integer()}

  @typedoc """
  One file's manifest:

    * `:regions` — generated line ranges, for mapping a compile error back to a mutant.
  """
  @type t :: %__MODULE__{regions: [region()]}

  defstruct regions: []

  @doc """
  Build a manifest from one file's rendered metamutant source.

  Re-parses (for `Sourceror.get_range/1`) and walks the tree once, attributing
  every selector clause, lifted private definition, and selector `case` to the
  mutant id(s) it belongs to.

  ## Examples

      iex> source = "defmodule Demo do\\n  def add(a, b), do: a + b\\nend\\n"
      iex> result = Mutare.transform_string(source, mutators: [:arithmetic])
      iex> %Mutare.Manifest{regions: regions} = Mutare.Manifest.from_source(result.metamutant)
      iex> regions == []
      false
  """
  @spec from_source(String.t()) :: t()
  def from_source(metamutant_source) do
    ast = parse(metamutant_source)

    # The gate clauses read the dispatch variable by name (`<var> === <id>`), and
    # `Mutare.Transform.Names` *salts* that name (`mutare_active` → `mutare_active_0`,
    # …) when the source already uses it — so we recover the actual name from this
    # metamutant rather than assume the canonical one (`active_var/1`).
    var = active_var(ast)

    {_ast, regions} = Macro.traverse(ast, [], &enter(&1, &2, var), &leave/2)

    %__MODULE__{regions: Enum.reverse(regions)}
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
  # variable. The (per-file, possibly salted) variable name is recovered once from the
  # metamutant (`active_var/1`) and threaded in, so both the subject recognisers (a
  # hoisted bare-variable subject) and the tupled-clause gate matcher (`pattern_mutant`)
  # see it. A user `case some_var do …` is never mistaken for a selector: the dispatch
  # name is salted away from every identifier the source uses, so it can't equal a user
  # scrutinee's name.
  defp enter({:case, _meta, [subject, kw]} = node, regions, var) do
    cond do
      Metamutant.subject?(subject, var) ->
        {node, record_case(do_block(kw), node, regions, &selector_mutant/1)}

      Metamutant.pattern_subject?(subject, var) ->
        {node, record_case(do_block(kw), node, regions, &pattern_mutant(&1, var))}

      true ->
        {node, regions}
    end
  end

  # A lifted mutant clause (`defp <base>(mutare_active, …) when mutare_active ===
  # <id> …`): its whole definition is that mutant's generated code — where a guard /
  # head-pattern poison lives. Original clauses (gated `mutare_active !== …`) and the
  # dispatcher carry no gate, so `mutant_id/1` returns `nil` and they're skipped.
  defp enter({vis, _meta, [head | _]} = node, regions, var) when vis in [:def, :defp] do
    regions =
      case mutant_id(head, var) do
        nil -> regions
        id -> push(range_region([id], node), regions)
      end

    {node, regions}
  end

  defp enter(node, regions, _var), do: {node, regions}

  defp leave(node, regions), do: {node, regions}

  # Record a `case`'s mutant clauses: `extract.(clause)` yields `{id, region_node}` (the node
  # whose range is that mutant's generated code) or `{nil, _}` for a non-mutant clause
  # (catch-all, gated original). Each mutant's region, then the whole-`case` fallback over all
  # of them.
  defp record_case(clauses, case_node, regions, extract) when is_list(clauses) do
    mutants = for clause <- clauses, {id, region} = extract.(clause), id != nil, do: {id, region}

    regions =
      Enum.reduce(mutants, regions, fn {id, region}, acc ->
        push(range_region([id], region), acc)
      end)

    push(case_fallback(case_node, mutants), regions)
  end

  defp record_case(_not_list, _case_node, regions, _extract), do: regions

  # A selector-`case` mutant clause `<id> -> <body>`: the id is its integer pattern; its
  # generated code is the body. A catch-all (`mutare_active -> …`) yields `{nil, nil}`.
  defp selector_mutant({:->, _, [[patt], body]}), do: {clause_id(patt), body}
  defp selector_mutant(_), do: {nil, nil}

  # A tupled-`case` mutant clause `{mutare_active, <pat>} when mutare_active === <id> … ->
  # <body>`: the id is in the `when` gate, and its generated code (the mutated pattern/guard)
  # is in the head, so the whole clause is the region. A gated original (`!==`) / unguarded
  # original yields `{nil, nil}`.
  defp pattern_mutant({:->, _, [[{:when, _wm, when_args}], _body]} = clause, var)
       when length(when_args) >= 2 do
    {_patterns, [guard]} = Enum.split(when_args, -1)
    {gate_id(guard, var), clause}
  end

  defp pattern_mutant(_, _), do: {nil, nil}

  # --- regions -------------------------------------------------------------

  # The whole `case`, attributed to every mutant id it hosts: the coarse fallback
  # for a structural error pointing at the `case` rather than a clause body.
  defp case_fallback(_case_node, []), do: nil

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
  defp clause_id({:__block__, _meta, [id]}) when is_integer(id), do: id
  defp clause_id(id) when is_integer(id), do: id
  defp clause_id(_), do: nil

  # The mutant id a *lifted mutant clause* carries in its `when <var> === <id> …`
  # gate (the leftmost conjunct `Transform.lifted_mutant/3` emits), or `nil` for
  # everything else: a lifted *original* clause (gated `<var> !== …`), the public
  # dispatcher, and user code. This is how a poison inside a generated guard/head
  # maps back to its mutant now that each lifted mutant is a single gated clause
  # rather than a `_m<id>`-named full copy. `var` is the (possibly salted) dispatch
  # variable name — see `active_var/1`.
  defp mutant_id({:when, _meta, [_call | guards]}, var),
    do: Enum.find_value(guards, &gate_id(&1, var))

  defp mutant_id(_, _), do: nil

  # Find a `<var> === <id>` gate anywhere in a guard, returning `<id>`. Only the
  # gate's `===` against the dispatch variable `var` matches — a source guard's own
  # `===` (LHS some other var) is skipped, and the originals' `!==` exclusions never
  # match — so a clause is a mutant iff this finds an id. The first clause pins the
  # LHS atom to `var` by repeating the binding name in the head (an equality match),
  # so a mismatching `===` falls through to the recursive descent rather than matching.
  defp gate_id({:===, _meta, [{var, _, _}, id_node]}, var), do: literal_int(id_node)

  defp gate_id({_form, _meta, args}, var) when is_list(args),
    do: Enum.find_value(args, &gate_id(&1, var))

  defp gate_id(list, var) when is_list(list), do: Enum.find_value(list, &gate_id(&1, var))
  defp gate_id({left, right}, var), do: gate_id(left, var) || gate_id(right, var)
  defp gate_id(_, _), do: nil

  defp literal_int({:__block__, _meta, [id]}) when is_integer(id), do: id
  defp literal_int(id) when is_integer(id), do: id
  defp literal_int(_), do: nil

  # --- dispatch variable ---------------------------------------------------

  # The dispatch variable's name in *this* metamutant. Canonically `mutare_active`,
  # but `Mutare.Transform.Names` salts it (`mutare_active_0`, …) when the source
  # already uses that identifier, so the gates read e.g. `mutare_active_0 === <id>`.
  # The name is one per file, so we recover it from generated code rather than assume
  # the canonical one.
  #
  # The authoritative anchor is a **coverage record** (`Recorder.record_var/1`): every
  # selector catch-all / lifted dispatcher carries `<var> == 0 and
  # :persistent_term.get(:mutare_track, false) and …`, whose embedded internal
  # `:mutare_track` read a target's own source cannot forge — so it names the real
  # (possibly salted) dispatch variable unambiguously, present wherever a hoisted
  # selector or gate uses it.
  #
  # A `<var> = :persistent_term.get(<key>, 0)` binding is a *weaker* anchor, because a
  # target file can write that very shape itself: reading the same key into a variable
  # of its own — even, pathologically, a reserved-family name like `mutare_active` —
  # which then *masks* the real (now-salted) generated binding. So the binding/tupled
  # anchors are only a family-filtered fallback for the (theoretical) shape lacking a
  # record; the canonical name covers a file with neither (then no gate exists, so the
  # name is never consulted).
  defp active_var(ast) do
    first_match(ast, &Recorder.record_var/1) ||
      first_match(ast, &anchor_var/1) ||
      Recorder.var_name()
  end

  # The first non-`nil` `recognize.(node)` over the tree, in prewalk order.
  defp first_match(ast, recognize) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        node, nil -> {node, recognize.(node)}
        node, found -> {node, found}
      end)

    found
  end

  # A generated construct that binds the dispatch variable, yielding its name:
  #   * a lifted dispatcher's `<var> = :persistent_term.get(<key>, 0)`
  #   * a non-lifted function's `:do`-block prologue `<var> = :persistent_term.get(<key>, 0)`
  #   * a tupled-`case` clause whose pattern is `{<var>, <pat>}`
  #
  # The recovered name is kept only when it is in the *generated* dispatch-variable
  # family (`dispatch_name/1`): `Metamutant.subject?/1` recognises the inline
  # `:persistent_term` read by shape alone, but a target file may bind that same key
  # into a variable of its own (`foo = :persistent_term.get(:mutare_active, 0)`), and
  # that user assignment is shape-identical. Filtering by name lets the prewalk skip
  # such a binding and keep searching for the real anchor.
  defp anchor_var({:=, _meta, [lhs, rhs]}) do
    if Metamutant.subject?(rhs), do: dispatch_name(var_atom(lhs))
  end

  defp anchor_var({:case, _meta, [subject, kw]}) do
    if Metamutant.pattern_subject?(subject), do: dispatch_name(tupled_clause_var(do_block(kw)))
  end

  defp anchor_var(_), do: nil

  # Keep a candidate name only when it is in the generated dispatch-variable family
  # — the canonical `Recorder.var_name()` (`mutare_active`) or a salted `mutare_active_<n>`
  # (`Mutare.Transform.Names.salted/2` appends `_0`, `_1`, … only when the source already
  # binds the canonical name; `Names.salted_name?/2` is its inverse, so the convention lives
  # in one place). A user variable that merely reads the same `:persistent_term` key
  # (`foo = …`) carries a name outside this family, so returning `nil` for it makes the
  # prewalk keep looking rather than lock onto user code — which would recover the wrong name
  # (`:foo`) and then fail to recognise the real `case mutare_active do …` hoisted selector,
  # leaving the in-place mutant without a region (a poison there would map to `[]` → recovery
  # aborts).
  defp dispatch_name(name) when is_atom(name) do
    if Names.salted_name?(Recorder.var_name(), name), do: name
  end

  defp dispatch_name(_), do: nil

  defp tupled_clause_var(clauses) when is_list(clauses),
    do: Enum.find_value(clauses, &clause_tuple_var/1)

  defp tupled_clause_var(_), do: nil

  defp clause_tuple_var({:->, _, [[{:when, _, [pattern | _]}], _body]}),
    do: tuple_first_var(pattern)

  defp clause_tuple_var({:->, _, [[pattern], _body]}), do: tuple_first_var(pattern)
  defp clause_tuple_var(_), do: nil

  defp tuple_first_var({first, _second}), do: var_atom(first)
  defp tuple_first_var(_), do: nil

  # The variable name of a var node `{name, meta, context}` (context an atom/`nil`),
  # or `nil` for anything else (a call has a list in the context slot).
  defp var_atom({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: name
  defp var_atom(_), do: nil
end
