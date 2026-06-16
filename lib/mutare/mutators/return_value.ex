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

  ## Which constant

  Any bare constant compiles and is a valid signal, so the choice is about
  *contrast* — picking a value different enough from the real return that a test
  asserting on it would notice — and about *not duplicating* the node-level
  families. One replacement per tail, chosen by the tail's syntactic shape:

    * a numeric expression (`a + b`, `x * 2`, `div(a, b)`, `-n`) → `0`
    * a string concatenation (`a <> b`) → `""`
    * a list expression (`a ++ b`, `xs -- ys`) → `[]`
    * anything else whose value the tests might pin (a variable, a function call,
      a tuple, a map, an `:ok`/`:error` atom, an `if`/`case`/`with` result, …) → `nil`

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

  alias Mutare.Mutators.Conditional

  # Operators whose result is unambiguously a number — so `0` is the contrasting
  # "empty" return. Both binary (`a + b`) and unary (`-n`) forms reach here.
  @numeric_ops [:+, :-, :*, :/, :div, :rem]

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
  already mutates, or `nil`); otherwise a one-element list with the shape-directed
  constant. See the moduledoc for the rules.
  """
  @spec replacements(Macro.t()) :: [Macro.t()]
  def replacements(tail) do
    cond do
      boolean_valued?(tail) -> []
      quote_block?(tail) -> []
      redundant_literal?(tail) -> []
      nil_tail?(tail) -> []
      true -> [contrasting_constant(tail)]
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

  # --- the contrasting constant ---------------------------------------------

  defp contrasting_constant({op, _meta, args}) when op in @numeric_ops and is_list(args),
    do: const(0)

  defp contrasting_constant({:<>, _meta, [_left, _right]}), do: empty_string()

  defp contrasting_constant({op, _meta, [_left, _right]}) when op in [:++, :--],
    do: const([])

  defp contrasting_constant(_other), do: const(nil)

  # Clean metadata so Sourceror renders from the value, not a stale `:token`
  # (the same rule the literal mutators follow).
  defp const(value), do: {:__block__, [], [value]}
  defp empty_string, do: {:__block__, [delimiter: ~s(")], [""]}
end
