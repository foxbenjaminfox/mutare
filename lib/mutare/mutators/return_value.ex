defmodule Mutare.Mutators.ReturnValue do
  @moduledoc """
  Replace a function clause's **return value** — the tail expression of its body —
  with a fixed constant. The highest-signal question in mutation testing, asked
  directly: *does any test pin what this function returns?* If the suite never
  constrains a function's result, every constant survives, and the survivor is a
  precisely located gap.

  It fires at each `def`/`defp` **return tail**. Tail position is transitive: when a
  clause tail is a `case`/`cond`/`if`/`unless`/`with`/`try`/`receive`, each branch's tail
  is its own return path, so a branchy function gets one return mutant per branch rather
  than one coarse mutant on the whole construct (`try`'s `:after` is excluded — its value
  is discarded). The same applies inside an **anonymous function** — each `fn` clause
  body tail is a return path. On by default, named in reports, selectable via
  `:mutators`, filterable by `# mutare:ignore[return_value]`.

  ## Which constants (a contrasting *pair*)

  Any bare constant compiles and is a valid signal, so the choice is about
  *contrast* — picking values different enough from the real return that a test
  asserting on it would notice — and about *not duplicating* the node-level
  families. Like `Mutare.Mutators.StringLiteral`'s `""`+`"mutare"` pair, each
  eligible tail yields **two** replacements, shape-directed:

    | tail shape                                   | empty/zero | sentinel   |
    |----------------------------------------------|------------|------------|
    | numeric (`a + b`, `x * 2`, `div(a, b)`, `-n`)| `0`        | `1`        |
    | string concatenation (`a <> b`)              | `""`       | `"mutare"` |
    | list expression (`a ++ b`, `xs -- ys`)       | `[]`       | `[:mutare]`|
    | anything else (variable, call, tuple, map,   | `nil`      | `:mutare`  |
    | `:ok`/`:error` atom, an opaque-macro result) |            |            |

  The two halves catch *opposite* weak assertions. The **empty/zero** value is
  killed by a test that asserts the result is present/non-empty/non-nil but
  survives one that pins the exact value; the **non-empty/non-nil sentinel** is
  the mirror — it is killed by a test pinning the value but survives one that only
  checks `!= nil` (or truthiness, or "the list is non-empty"). A function whose
  result the suite never constrains leaves *both* alive, a doubly-loud survivor.
  (A sentinel that would equal the original tail — only possible when the tail is
  itself a bare atom, e.g. `def f, do: :mutare` — is dropped as an equivalent
  no-op, exactly as `StringLiteral` drops the half equal to its source string.)

  ## What it deliberately leaves alone (no redundant mutant)

    * **Boolean-valued tails** (a comparison/logical operator) — already covered by
      `Mutare.Mutators.Conditional`, which forces the result to `true`/`false`.
      Mutating them here too would just duplicate that. (Detected via
      `Conditional.boolean_op?/1`.)
    * **Bare literals already mutated by a value family** — an integer/float/string
      literal, a list literal, a boolean. `Literal`/`FloatLiteral`/`StringLiteral`/
      `List` already replace these *at the node*, so a whole-tail constant would
      reproduce their work. (A bare *atom* like `:ok` is **not** in this set — no
      family mutates arbitrary atoms — so `def save(_), do: :ok` does get a
      `:ok → nil` return mutant.)
    * **A `nil` tail** — replacing `nil` with `nil` is equivalent, and with anything
      else is low-signal (a `nil`-returning function is usually side-effecting).
    * **A `quote` block** — a function whose tail is a `quote` builds macro AST,
      which Mutare treats as compile-time code and leaves whole.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to
  suppress just one kind (`c:Mutare.Mutator.variants/0`): `empty`, `sentinel`.
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
  The constant replacements for one clause-tail expression, as clean-meta AST
  nodes ready to splice into a selector clause. Returns `[]` when the tail should
  get no return mutant (a boolean-valued expression, a literal a value family
  already mutates, or `nil`); otherwise the contrasting *pair* — the shape's
  empty/zero value and its non-empty/non-nil sentinel — minus any half that would
  equal the original tail. See the moduledoc for the rules.

  This is the `c:Mutare.Mutator.Structural.return_replacements/1` hook: the transform discovers it
  by export and calls it at each return-path tail.
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
