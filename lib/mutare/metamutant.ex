defmodule Mutare.Metamutant do
  @moduledoc """
  The shape of a selector `case` in the metamutant.

  This is the one piece of generated structure that `Mutare.Transform` writes
  and that both `Mutare.Coverage` and `Mutare.Poison` read back. Owning it in a
  single module keeps the producer from hand-building the same AST literal twice
  and keeps the two consumers from re-implementing the same metamutant walk.

  A selector `case` looks like:

      case :persistent_term.get(:mutare_active, 0) do
        17 -> <mutated>     # one clause per mutant id hosted here
        18 -> <mutated>
        _  -> <original>    # the catch-all: baseline + every inactive mutant
      end

  The subject (`:persistent_term.get(...)`) is the same whether the `case` is an
  in-place selector or a lifted dispatcher — only the clause bodies differ — so
  recognising the subject is enough to find every selector.

    * `subject_ast/0` builds the subject `Transform` splices in,
    * `subject?/1` recognises it (the predicate Coverage and Poison share),
    * `selector_clauses/1` re-parses a rendered metamutant and yields one
      descriptor per mutant clause, carrying both the lines its readers need.

  `Mutare.Selector` owns the runtime constants (the `:persistent_term` key and
  the baseline id); this module owns their AST.
  """

  @key Mutare.Selector.key()
  @baseline Mutare.Selector.baseline()

  @typedoc """
  One mutant clause of a selector `case`, located in metamutant-line space.

    * `:id` — the mutant id (the clause's integer pattern)
    * `:module` — the enclosing module (`nil` if the clause sits outside one)
    * `:clause_line` — the line of *this* clause's own body; what `Mutare.Poison`
      matches a compile error's line against (the poison is always in a mutant
      clause — the catch-all is the original, which compiled)
    * `:catch_all_line` — the line of the `case`'s catch-all body, taken at
      baseline whenever the code runs; what `Mutare.Coverage` intersects with
      `:cover`'s per-line hits
  """
  @type selector_clause :: %{
          id: pos_integer(),
          module: module() | nil,
          clause_line: pos_integer() | nil,
          catch_all_line: pos_integer() | nil
        }

  @doc """
  The selector subject `Transform` splices into every selector/dispatcher `case`:
  `:persistent_term.get(<key>, <baseline>)`.
  """
  @spec subject_ast() :: Macro.t()
  def subject_ast, do: {{:., [], [:persistent_term, :get]}, [], [@key, @baseline]}

  @doc "Whether `node` is a selector subject — the predicate Coverage and Poison share."
  @spec subject?(Macro.t()) :: boolean()
  def subject?({{:., _, [:persistent_term, :get]}, _, [key | _]}), do: key == @key
  def subject?(_), do: false

  @doc """
  Re-parse a rendered metamutant and yield one `t:selector_clause/0` per mutant
  clause across every selector `case`, in source order.

  A module stack (pushed/popped via `Macro.traverse/4`) attributes each clause to
  its enclosing module. A single traversal carries both lines its callers need,
  so Coverage and Poison share one walk rather than two near-identical re-parsers.
  """
  @spec selector_clauses(String.t()) :: [selector_clause()]
  def selector_clauses(metamutant_source) do
    ast = Code.string_to_quoted!(metamutant_source, columns: true)

    {_ast, {_stack, clauses}} = Macro.traverse(ast, {[], []}, &enter/2, &leave/2)

    Enum.reverse(clauses)
  end

  # --- traversal -----------------------------------------------------------

  defp enter({:defmodule, _meta, [alias_node | _]} = node, {stack, clauses}) do
    {node, {[module_name(alias_node) | stack], clauses}}
  end

  defp enter({:case, _meta, [subject, [do: do_clauses]]} = node, {stack, clauses}) do
    if subject?(subject) do
      module = List.first(stack)
      catch_all = catch_all_line(do_clauses)

      found =
        for {:->, _, [[id], body]} <- do_clauses, is_integer(id) do
          %{id: id, module: module, clause_line: node_line(body), catch_all_line: catch_all}
        end

      {node, {stack, Enum.reverse(found, clauses)}}
    else
      {node, {stack, clauses}}
    end
  end

  defp enter(node, acc), do: {node, acc}

  defp leave({:defmodule, _meta, _args} = node, {stack, clauses}) do
    {node, {tl(stack), clauses}}
  end

  defp leave(node, acc), do: {node, acc}

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

  defp module_name({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_name(_), do: nil
end
