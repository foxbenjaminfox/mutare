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
  `Mutare.Metamutant.subject?/1`.

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
  alias Mutare.Metamutant

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
  """
  @spec from_source(String.t()) :: t()
  def from_source(metamutant_source) do
    ast = parse(metamutant_source)

    {_ast, regions} = Macro.traverse(ast, [], &enter/2, &leave/2)

    %__MODULE__{regions: Enum.reverse(regions)}
  end

  # Parse the rendered metamutant into an AST `Sourceror.get_range/1` can range.
  # `Code.string_to_quoted!` with `:token_metadata`/`:columns` gives `get_range`
  # everything it reads, far faster than `Sourceror.parse_string!` (whose extra
  # comment-merging pass is quadratic on a megabyte-scale lifted file). The
  # `:literal_encoder` mirrors Sourceror's `{:__block__, meta, [literal]}` wrapping
  # so the recognisers (`Metamutant.subject?/1`, `clause_id/1`, `AST.key_atom/1`) see
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

  # A selector `case` (in-place selector or lifted dispatcher). Record each mutant
  # clause's body range, plus a whole-`case` fallback range.
  defp enter({:case, _meta, [subject, kw]} = node, regions) do
    with true <- Metamutant.subject?(subject),
         clauses when is_list(clauses) <- do_block(kw) do
      mutants = for {:->, _, [[patt], body]} <- clauses, id = clause_id(patt), do: {id, body}

      # Each mutant clause body (catches in-place mutants, multiline included),
      # then the whole-`case` fallback (every id it hosts) as a coarse backstop.
      regions =
        Enum.reduce(mutants, regions, fn {id, body}, acc ->
          push(range_region([id], body), acc)
        end)

      {node, push(case_fallback(node, mutants), regions)}
    else
      _ -> {node, regions}
    end
  end

  # A lifted mutant clause (`defp <base>(mutare_active, …) when mutare_active ===
  # <id> …`): its whole definition is that mutant's generated code — where a guard /
  # head-pattern poison lives. Original clauses (gated `mutare_active !== …`) and the
  # dispatcher carry no gate, so `mutant_id/1` returns `nil` and they're skipped.
  defp enter({vis, _meta, [head | _]} = node, regions) when vis in [:def, :defp] do
    regions =
      case mutant_id(head) do
        nil -> regions
        id -> push(range_region([id], node), regions)
      end

    {node, regions}
  end

  defp enter(node, regions), do: {node, regions}

  defp leave(node, regions), do: {node, regions}

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

  # The mutant id a *lifted mutant clause* carries in its `when mutare_active ===
  # <id> …` gate (the leftmost conjunct `Transform.lifted_mutant/3` emits), or `nil`
  # for everything else: a lifted *original* clause (gated `mutare_active !== …`),
  # the public dispatcher, and user code. This is how a poison inside a generated
  # guard/head maps back to its mutant now that each lifted mutant is a single gated
  # clause rather than a `_m<id>`-named full copy.
  defp mutant_id({:when, _meta, [_call | guards]}), do: Enum.find_value(guards, &gate_id/1)
  defp mutant_id(_), do: nil

  # Find a `mutare_active === <id>` gate anywhere in a guard, returning `<id>`. Only
  # the gate's `===` against the `mutare_active` var matches — a source guard's own
  # `===` (LHS some other var) is skipped, and the originals' `!==` exclusions never
  # match — so a clause is a mutant iff this finds an id.
  defp gate_id({:===, _meta, [{:mutare_active, _, _}, id_node]}), do: literal_int(id_node)
  defp gate_id({_form, _meta, args}) when is_list(args), do: Enum.find_value(args, &gate_id/1)
  defp gate_id(list) when is_list(list), do: Enum.find_value(list, &gate_id/1)
  defp gate_id({left, right}), do: gate_id(left) || gate_id(right)
  defp gate_id(_), do: nil

  defp literal_int({:__block__, _meta, [id]}) when is_integer(id), do: id
  defp literal_int(id) when is_integer(id), do: id
  defp literal_int(_), do: nil
end
