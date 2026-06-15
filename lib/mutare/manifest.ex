defmodule Mutare.Manifest do
  @moduledoc """
  A per-mutant map of where each mutant lives in its rendered metamutant.

  `Mutare.Transform` writes the metamutant; this is what the readers read back.
  It is built **once per file** (`from_source/1`), stored on the `Mutare.Schema`,
  and shared by the two consumers so the metamutant is walked once, not per probe
  and per poison attempt:

    * **`Mutare.Coverage`** wants each mutant's *coverage location* — the
      `{module, line}` of its selector's catch-all body, the line `:cover` counts
      at baseline whenever the code runs.
    * **`Mutare.Poison`** wants each mutant's *generated ranges* — the metamutant
      line spans of the code that exists only because of that mutant, so a compile
      error's line maps back to the mutant id that owns it.

  ## Why ranges, not a single line

  Poison recovery used to match a compile error's line against the *start line of
  a selector clause body* only. That missed every poison whose bad code isn't on
  that exact line:

    * **lifted mutations** — a guard/clause-drop mutant's code lives in a generated
      private `defp __mutare_…_m<id>` definition, not in the dispatcher clause
      (which only *calls* it). The error points into the `defp`, lines away from
      the dispatcher clause;
    * **multiline bodies** — an in-place mutant whose body spans several lines can
      fault on any of them, not just the first;
    * **structural errors** — the compiler sometimes points at the surrounding
      `case` rather than a clause body.

  So we record, per mutant, the *full* line ranges of its generated code:

    * each selector clause body (`<id> -> <mutated>`) — catches in-place mutants,
      including multiline bodies;
    * each lifted private definition (`defp __mutare_…_m<id>`) — catches guard and
      clause-drop poison, whose code lives away from the dispatcher;
    * the whole selector `case`, attributed to *all* the mutant ids it hosts — the
      coarse fallback for a structural error that points at the `case` itself.

  `ids_at_line/2` resolves an error line by **narrowest containing range**: a line
  inside a specific clause/def range maps to that one mutant; only when nothing
  narrower contains it does the whole-`case` fallback fire (dropping every mutant
  the `case` hosts — a bounded over-drop that still recovers the build, never the
  old "couldn't map it → abort").

  Ranges are in **metamutant line space**, which only exists after rendering, so
  the manifest is built by re-parsing the rendered metamutant with
  `Sourceror.parse_string!` (whose metadata `Sourceror.get_range/1` needs) and
  recognising selectors via `Mutare.Metamutant.subject?/1`.
  """

  alias Mutare.Metamutant

  @typedoc "A generated line range and the mutant ids whose code occupies it."
  @type region :: %{ids: [pos_integer()], lo: pos_integer(), hi: pos_integer()}

  @typedoc """
  One file's manifest:

    * `:coverage` — `%{id => {module, line}}`, the catch-all body line `:cover` counts;
    * `:regions` — generated line ranges, for mapping a compile error back to a mutant.
  """
  @type t :: %__MODULE__{
          coverage: %{pos_integer() => {module() | nil, pos_integer()}},
          regions: [region()]
        }

  defstruct coverage: %{}, regions: []

  @mutant_def ~r/\A__mutare_.*_m(\d+)\z/

  @doc """
  Build a manifest from one file's rendered metamutant source.

  Re-parses with `Sourceror.parse_string!` (for `Sourceror.get_range/1`) and walks
  the tree once, attributing every selector clause, lifted private definition, and
  selector `case` to the mutant id(s) it belongs to.
  """
  @spec from_source(String.t()) :: t()
  def from_source(metamutant_source) do
    ast = Sourceror.parse_string!(metamutant_source)

    {_ast, {_stack, coverage, regions}} =
      Macro.traverse(ast, {[], %{}, []}, &enter/2, &leave/2)

    %__MODULE__{coverage: coverage, regions: Enum.reverse(regions)}
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

  @doc "The per-mutant coverage locations: `%{id => {module, line}}`."
  @spec coverage(t()) :: %{pos_integer() => {module() | nil, pos_integer()}}
  def coverage(%__MODULE__{coverage: coverage}), do: coverage

  # --- traversal -----------------------------------------------------------

  defp enter({:defmodule, _meta, [alias_node | _]} = node, {stack, coverage, regions}) do
    parent = List.first(stack)
    {node, {[module_name(alias_node, parent) | stack], coverage, regions}}
  end

  # A selector `case` (in-place selector or lifted dispatcher). Record each mutant
  # clause's coverage location + body range, plus a whole-`case` fallback range.
  defp enter({:case, _meta, [subject, kw]} = node, {stack, coverage, regions}) do
    with true <- Metamutant.subject?(subject),
         clauses when is_list(clauses) <- do_block(kw) do
      module = List.first(stack)
      catch_all = catch_all_line(clauses)
      mutants = for {:->, _, [[patt], body]} <- clauses, id = clause_id(patt), do: {id, body}

      coverage =
        Enum.reduce(mutants, coverage, fn {id, _body}, acc ->
          Map.put(acc, id, {module, catch_all})
        end)

      # Each mutant clause body (catches in-place mutants, multiline included),
      # then the whole-`case` fallback (every id it hosts) as a coarse backstop.
      regions =
        Enum.reduce(mutants, regions, fn {id, body}, acc ->
          push(range_region([id], body), acc)
        end)

      regions = push(case_fallback(node, mutants), regions)

      {node, {stack, coverage, regions}}
    else
      _ -> {node, {stack, coverage, regions}}
    end
  end

  # A lifted private copy (`defp __mutare_…_m<id>(…)`): its whole definition is the
  # mutant's generated code — where guard / clause-drop poison actually lives.
  defp enter({vis, _meta, [head | _]} = node, {stack, coverage, regions})
       when vis in [:def, :defp] do
    regions =
      case mutant_id(head) do
        nil -> regions
        id -> push(range_region([id], node), regions)
      end

    {node, {stack, coverage, regions}}
  end

  defp enter(node, acc), do: {node, acc}

  defp leave({:defmodule, _meta, _args} = node, {stack, coverage, regions}) do
    {node, {tl(stack), coverage, regions}}
  end

  defp leave(node, acc), do: {node, acc}

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
      {key, value} -> if key_atom(key) == :do, do: value
      _ -> nil
    end)
  end

  defp do_block(_), do: nil

  defp key_atom({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  defp key_atom(atom) when is_atom(atom), do: atom
  defp key_atom(_), do: nil

  # The integer pattern of a mutant clause (`<id> -> …`); `nil` for the catch-all.
  # Sourceror wraps the literal in a `:__block__`; a bare integer is also accepted.
  defp clause_id({:__block__, _meta, [id]}) when is_integer(id), do: id
  defp clause_id(id) when is_integer(id), do: id
  defp clause_id(_), do: nil

  # Line of the catch-all (`_ ->`) clause's body — the line cover counts when the
  # selector runs at baseline.
  defp catch_all_line(clauses) do
    Enum.find_value(clauses, fn
      {:->, _, [[{:_, _, _}], body]} -> node_line(body)
      _ -> nil
    end)
  end

  defp node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp node_line(_), do: nil

  # The mutant id encoded in a generated private copy's name (`__mutare_…_m<id>`),
  # or `nil` for any other definition (the public dispatcher, `…_orig`, user code).
  defp mutant_id({:when, _meta, [call | _guards]}), do: mutant_id(call)

  defp mutant_id({name, _meta, _args}) when is_atom(name) do
    case Regex.run(@mutant_def, Atom.to_string(name)) do
      [_, id] -> String.to_integer(id)
      nil -> nil
    end
  end

  defp mutant_id(_), do: nil

  # --- module attribution --------------------------------------------------

  defp module_name({:__aliases__, _, [Elixir | _] = parts}, _parent),
    do: Module.concat(parts)

  defp module_name({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, parent)
       when is_atom(parent),
       do: Module.concat([parent | parts])

  defp module_name({:__aliases__, _, parts}, nil), do: Module.concat(parts)

  defp module_name({:__aliases__, _, parts}, parent) when is_atom(parent),
    do: Module.concat([parent | parts])

  defp module_name(module, _parent) when is_atom(module), do: module
  defp module_name(_, _parent), do: nil
end
