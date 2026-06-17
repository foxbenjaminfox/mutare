defmodule Mutare.Mutators.ReturnValue do
  @moduledoc """
  Replace a function clause's **return value** — the tail expression of its body —
  with a fixed constant. The highest-signal question in mutation testing, asked
  directly: *does any test pin what this function returns?* If the suite never
  constrains a function's result, every constant survives, and the survivor is a
  precisely located gap.

  ## Why this is structural, not a node-level `mutate/1`

  Every other built-in family is a `Mutare.Mutator` whose `mutate/1` rewrites a
  node *wherever it occurs*. A return-value mutation can't be expressed that way:
  it targets the *tail expression of a clause body* — a position a bare node knows
  nothing about. So `mutate/1` here is intentionally `:skip` (it never fires as a
  node mutator), and the real work lives in `replacements/1`, which
  `Mutare.Transform` calls once per `def`/`defp` clause tail it discovers. This
  module still implements the behaviour so it can sit in the `Mutare.Mutators`
  registry — be on by default, be named in reports, be selected/validated via
  `:mutators`, and be filtered by `# mutare:ignore[return_value]` — exactly like
  every other family. (Its delivery is the *in-place selector*, not lifting: the
  tail is a body position, so a `case` is legal there. `clause_drop` is the other
  structural built-in, but it is lifted.)

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
    | `:ok`/`:error` atom, `if`/`case`/`with`, …)  |            |            |

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
      `Conditional.boolean_op?/1`, the single definition of "boolean-valued op".)
    * **Bare literals already mutated by a value family** — an integer/float/string
      literal, a list literal, a boolean. `Literal`/`FloatLiteral`/`StringLiteral`/
      `List` already replace these *at the node*, so a whole-tail constant would
      reproduce their work. (A bare *atom* like `:ok` is **not** in this set — no
      family mutates arbitrary atoms — so `def save(_), do: :ok` does get a
      `:ok → nil` return mutant.)
    * **A `nil` tail** — replacing `nil` with `nil` is equivalent, and with anything
      else is low-signal (a `nil`-returning function is usually side-effecting).
    * **A `quote` block** — a function whose tail is a `quote` builds macro AST,
      which `Mutare.Transform` already classifies as compile-time and leaves whole
      (PHILOSOPHY: "macro-generated code is a different tool"). Replacing its return
      would be safe, but keeping `quote` uniformly hands-off is the simpler, more
      consistent boundary.

  Compile-safety is free: a bare constant is legal in any tail position, and the
  original tail is retained in the selector's catch-all, so variables bound by the
  clause stay used (no unused-variable warning).
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.Conditional

  # Operators whose result is unambiguously a number — so `0`/`1` are the
  # contrasting pair. Both binary (`a + b`) and unary (`-n`) forms reach here.
  @numeric_ops [:+, :-, :*, :/, :div, :rem]

  # The non-nil/non-empty sentinel word, shared across the shapes (`:mutare`,
  # `[:mutare]`, `"mutare"`) — the same recognizable marker `StringLiteral` uses,
  # so a surviving sentinel reads unambiguously in a report as "the value is not
  # pinned, only its presence". Numeric tails use `1` (no string sentinel fits).
  @sentinel "mutare"
  @sentinel_atom :mutare

  @impl Mutare.Mutator
  def name, do: :return_value

  # Structural, not node-level: placement (a clause tail) is invisible to a node
  # mutator, so this never fires here. `replacements/1` is the real entry point,
  # driven by the transform. See the moduledoc.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @doc """
  The constant replacements for one clause-tail expression, as clean-meta AST
  nodes ready to splice into a selector clause. Returns `[]` when the tail should
  get no return mutant (a boolean-valued expression, a literal a value family
  already mutates, or `nil`); otherwise the contrasting *pair* — the shape's
  empty/zero value and its non-empty/non-nil sentinel — minus any half that would
  equal the original tail. See the moduledoc for the rules.
  """
  @spec replacements(Macro.t()) :: [Macro.t()]
  def replacements(tail) do
    cond do
      boolean_valued?(tail) -> []
      quote_block?(tail) -> []
      redundant_literal?(tail) -> []
      nil_tail?(tail) -> []
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

  defp nil_tail?({:__block__, _meta, [nil]}), do: true
  defp nil_tail?(nil), do: true
  defp nil_tail?(_), do: false

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

  defp atom_value({:__block__, _meta, [v]}) when is_atom(v), do: {:atom, v}
  defp atom_value(v) when is_atom(v), do: {:atom, v}
  defp atom_value(_), do: nil
end
