defmodule Mutare.Mutators.ReturnValue do
  @moduledoc """
  Replaces function return expressions with fixed constants.

  It applies to each `def` and `defp` return path. When a clause tail is a `case`/`cond`/`if`/`unless`/`with`/`try`/`receive`, each branch's tail is its own return path. The value of a `try` `after` block is excluded because it is discarded. Each clause of an anonymous function is handled in the same way.

  Each eligible return path produces two replacements based on its shape:

  | tail shape                                   | empty/zero | sentinel   |
  |----------------------------------------------|------------|------------|
  | numeric (`a + b`, `x * 2`, `div(a, b)`, `-n`)| `0`        | `1`        |
  | string concatenation (`a <> b`)              | `""`       | `"mutare"` |
  | list expression (`a ++ b`, `xs -- ys`)       | `[]`       | `[:mutare]`|
  | anything else (variable, call, tuple, map,   | `nil`      | `:mutare`  |
  | `:ok`/`:error` atom, an opaque-macro result) |            |            |

  A replacement equal to the original return is omitted.

  Two separate rules keep this family from restating another's work, and they answer different
  questions. A *literal* tail belongs to its node-level family outright, whatever the run
  enables — see Exclusions. On every tail this family does claim, the transform then compares
  *values*: when an enabled node-level family already produces the same scalar replacement at
  that return expression, it keeps the node-level mutation and drops this family's duplicate.
  So with `AtomLiteral` enabled, `:foo → :mutare` is reported as `atom` while `:foo → nil`
  stays a `return_value` mutation; disable `AtomLiteral` and both replacements come back.

  ## Exclusions

    * Boolean expressions are handled by `Mutare.Mutators.Conditional`.
    * Integer, float, string, list, and boolean literals are handed to their node-level families
      outright — unlike the value comparison above, this holds even when that family is disabled.
      On a literal tail the contrasting pair earns nothing: `nil`/`:mutare` collide with no
      replacement those families emit, so no comparison would catch them, and they are at best
      weaker restatements of one. A `do: false` tail mutated to `nil` is the clearest case — both
      are falsy, so every `refute`-style assertion lets it through, and only a strict comparison
      or a `false` pattern match kills it. Bare atoms remain eligible.
    * `nil` return expressions are not mutated.
    * `quote` blocks are compile-time code and are not mutated as a whole.

  The `empty` and `sentinel` variants can be selected independently in an ignore directive, for example `# mutare:ignore[return_value:empty]`. This family is enabled by default.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

  alias Mutare.AST
  alias Mutare.Mutators.Conditional

  # Operators whose result is unambiguously a number — so `0`/`1` are the
  # contrasting pair. Both binary (`a + b`) and unary (`-n`) forms reach here.
  @numeric_ops [:+, :-, :*, :/, :div, :rem]

  # The non-nil/non-empty sentinel word, shared across the shapes (`:mutare`,
  # `[:mutare]`, `"mutare"`) — the same recognizable marker `StringLiteral` uses,
  # so a surviving sentinel reads unambiguously in a report as "the value is not
  # pinned, only its presence". Numeric tails use `1` (no string sentinel fits).
  @sentinel AST.sentinel_string()
  @sentinel_atom AST.sentinel_atom()

  @impl Mutare.Mutator
  def name, do: :return_value

  # Variant labels for `# mutare:ignore[return_value:<label>]`: which half of the contrasting
  # pair — `empty` (the shape's `0`/`""`/`[]`/`nil`) or `sentinel` (its `1`/`"mutare"`/
  # `[:mutare]`/`:mutare`). Named, not derived, so `empty` works where the raw result `[]`
  # could not be written. Classified by recomputing the pair for the tail and value-matching
  # the mutated half against it.
  @impl Mutare.Mutator
  def variants, do: ~w(empty sentinel)

  # Value-match the stored mutated half against a freshly recomputed contrasting pair,
  # meta-insensitively (`AST.unwrap_literal/1`) — the pair carries collection values like `[]`, so a
  # one-layer block unwrap, not `AST.literal_value/1`, is the right comparator.
  @impl Mutare.Mutator
  def variant(tail, mutated) do
    value = AST.unwrap_literal(mutated)

    cond do
      value === AST.unwrap_literal(empty_constant(tail)) -> "empty"
      value === AST.unwrap_literal(sentinel_constant(tail)) -> "sentinel"
      true -> nil
    end
  end

  @doc """
  Returns clean-meta constant replacements for a clause return expression.

  Eligible expressions receive an empty or zero value and a non-empty sentinel,
  excluding any replacement equal to the original. Returns `[]` for expressions
  handled by another value family, boolean expressions, `nil`, and quoted code.
  """
  @impl Mutare.Mutator.Structural
  @spec return_replacements(Macro.t()) :: [Macro.t()]
  def return_replacements(tail) do
    cond do
      boolean_valued?(tail) -> []
      quote_block?(tail) -> []
      redundant_literal?(tail) -> []
      AST.nil_literal?(tail) -> []
      true -> contrasting_constants(tail)
    end
  end

  # --- eligibility ----------------------------------------------------------

  # A boolean-valued operator (comparison / logical / membership): Conditional
  # already forces it to true/false, so a return mutant here is pure duplication.
  defp boolean_valued?({op, _meta, args}) when is_atom(op) and is_list(args),
    do: Conditional.boolean_op?(op)

  defp boolean_valued?(_), do: false

  # A literal a value-family mutator already rewrites at the node: an integer,
  # float, string, list literal, or boolean. Sourceror wraps every literal in a
  # single-child `:__block__`. (Atoms other than true/false are *not* here.)
  defp redundant_literal?({:__block__, _meta, [v]}),
    do: is_integer(v) or is_float(v) or is_binary(v) or is_list(v) or is_boolean(v)

  defp redundant_literal?(v) when is_integer(v) or is_float(v) or is_binary(v) or is_list(v),
    do: true

  defp redundant_literal?(_), do: false

  # A `quote` block builds macro AST — compile-time territory the transform leaves
  # whole (see the moduledoc). Keep return-value off it too.
  defp quote_block?({:quote, _meta, args}) when is_list(args), do: true
  defp quote_block?(_), do: false

  # --- the contrasting pair -------------------------------------------------

  # The empty/zero half and the sentinel half, with any half equal to the
  # original tail dropped (reachable only for a bare-atom tail — numeric/string/
  # list literals are excluded upstream by `redundant_literal?/1`).
  defp contrasting_constants(tail) do
    [empty_constant(tail), sentinel_constant(tail)]
    |> Enum.reject(&equivalent_to?(&1, tail))
  end

  defp empty_constant({op, _meta, args}) when op in @numeric_ops and is_list(args),
    do: AST.literal(0)

  defp empty_constant({:<>, _meta, [_left, _right]}), do: AST.literal("")
  defp empty_constant({op, _meta, [_left, _right]}) when op in [:++, :--], do: AST.literal([])
  defp empty_constant(_other), do: AST.literal(nil)

  defp sentinel_constant({op, _meta, args}) when op in @numeric_ops and is_list(args),
    do: AST.literal(1)

  defp sentinel_constant({:<>, _meta, [_left, _right]}), do: AST.literal(@sentinel)

  defp sentinel_constant({op, _meta, [_left, _right]}) when op in [:++, :--],
    do: AST.literal([@sentinel_atom])

  defp sentinel_constant(_other), do: AST.literal(@sentinel_atom)

  # True when a replacement constant carries the same value as the tail. Only
  # bare atoms can collide (every other constant differs from its pair by
  # construction, and literal tails never reach here), so it suffices to compare
  # atom values.
  defp equivalent_to?(replacement, tail) do
    case {atom_value(replacement), atom_value(tail)} do
      {{:atom, v}, {:atom, v}} -> true
      _ -> false
    end
  end

  defp atom_value(node) do
    case AST.literal_value(node) do
      {:ok, v} when is_atom(v) -> {:atom, v}
      _ -> nil
    end
  end
end
