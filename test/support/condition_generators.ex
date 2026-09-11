defmodule Mutare.Test.ConditionGen do
  @moduledoc """
  PropCheck generators for `if`/`unless` *conditions* that bind variables — the input to the
  `Mutare.Transform.Analyze.Conditions` spine-walk properties (`conditions_property_test.exs`).

  A generated condition is a total expression over two pre-bound integer variables
  (`bindings_env/0`), built in three sorts so it always evaluates without raising:

    * a **num** — an integer (Sourceror-wrapped or bare), a variable read, `+`/`-`/`*`, an
      `effect/1` call, a bare binding `b = num`, or a `case`/`if`/`try … after` yielding a num;
    * a **bool** — `==`/`!=` over terms, an ordering over nums, `and`/`or` over bools,
      `!term`, `not bool`, a bare binding `b = bool`, or a branch yielding a bool;
    * a **term** — any of the above, a 2-tuple, a `{:{}, …}` tuple, a list, a `&&`/`||`
      (whose value is either operand), a refutable binding `{:ok, b} = {:ok, term}`, or a
      `for` comprehension (a binding-isolating form).

  So bindings land on the unconditional *spine* (an operand, the left of a short-circuit),
  *off* it (a short-circuit's right operand, a `case`/`if` branch or subject), or *isolated*
  (inside `for`/`try`), and `Effects.effect(n)` — sends `{:effect, n}` to the caller, returns
  `n` — makes evaluation order observable in the mailbox. A post-pass renames every binding
  to a unique `b1`, `b2`, … (no expression reads a binding, so order of binding never matters
  for validity), and the placeholder a refutable hoist introduces is a real variable name the
  generator never uses.
  """

  use PropCheck

  defmodule Effects do
    @moduledoc false
    def effect(n) do
      send(self(), {:effect, n})
      n
    end
  end

  @doc "The variable environment every generated condition evaluates in."
  def bindings_env, do: [x: 3, y: -2]

  @doc "A condition: a bool or a term, with bindings renamed uniquely."
  def condition do
    sized(size, let(c <- oneof([bool(min(size, 4)), term(min(size, 4))]), do: number_bindings(c)))
  end

  # === sorts ================================================================

  defp num(0), do: num_leaf()

  defp num(size) do
    sub = num(div(size, 2))

    frequency([
      {3, num_leaf()},
      {3, let({op, l, r} <- {oneof([:+, :-, :*]), sub, sub}, do: {op, [], [l, r]})},
      {3, let(n <- sub, do: effect(n))},
      {3, let(n <- sub, do: bind(n))},
      {1, branch(term(div(size, 2)), bool(div(size, 2)), sub)}
    ])
  end

  defp bool(0), do: bool_leaf()

  defp bool(size) do
    half = div(size, 2)
    nsub = num(half)
    bsub = bool(half)
    tsub = term(half)

    frequency([
      {2, bool_leaf()},
      {3, let({op, l, r} <- {oneof([:==, :!=]), tsub, tsub}, do: {op, [], [l, r]})},
      {3, let({op, l, r} <- {oneof([:<, :>, :<=, :>=]), nsub, nsub}, do: {op, [], [l, r]})},
      {3, let({op, l, r} <- {oneof([:and, :or]), bsub, bsub}, do: {op, [], [l, r]})},
      {1, let(t <- tsub, do: {:!, [], [t]})},
      {1, let(b <- bsub, do: {:not, [], [b]})},
      {2, let(b <- bsub, do: bind(b))},
      {1, branch(tsub, bsub, bsub)}
    ])
  end

  defp term(0), do: oneof([num_leaf(), bool_leaf(), atom_leaf()])

  defp term(size) do
    half = div(size, 2)
    sub = term(half)

    frequency([
      {3, num(size)},
      {3, bool(size)},
      {1, atom_leaf()},
      {2, let({l, r} <- {sub, sub}, do: {l, r})},
      {1, let({a, b, c} <- {sub, sub, sub}, do: {:{}, [], [a, b, c]})},
      {1, let(es <- oneof([vector(1, sub), vector(2, sub), vector(3, sub)]), do: es)},
      {2, let({op, l, r} <- {oneof([:&&, :||]), sub, sub}, do: {op, [], [l, r]})},
      {2, let(t <- sub, do: {:=, [], [{:ok, var(:b)}, {:ok, t}]})},
      {1, let(t <- sub, do: {:for, [], [{:<-, [], [{:_, [], nil}, [1]]}, [do: t]]})}
    ])
  end

  # A `case` (single always-matching clause), an `if`, or a `try` — the branch and isolating
  # forms the walks stop at — yielding `sub`.
  defp branch(subject, condition, sub) do
    oneof([
      let(
        {s, body} <- {subject, sub},
        do: {:case, [], [s, [do: [{:->, [], [[{:_, [], nil}], body]}]]]}
      ),
      let({c, a, b} <- {condition, sub, sub}, do: {:if, [], [c, [do: a, else: b]]}),
      let(body <- sub, do: {:try, [], [[do: body, after: :ok]]})
    ])
  end

  # === leaves ===============================================================

  defp num_leaf do
    oneof([
      let(i <- integer(-5, 5), do: i),
      let(i <- integer(-5, 5), do: {:__block__, [], [i]}),
      let(v <- oneof([:x, :y]), do: var(v))
    ])
  end

  defp bool_leaf, do: oneof([boolean(), let(b <- boolean(), do: {:__block__, [], [b]})])

  defp atom_leaf,
    do: oneof([oneof([:a, :b]), let(a <- oneof([:a, :b]), do: {:__block__, [], [a]})])

  defp var(name), do: {name, [], nil}
  defp bind(rhs), do: {:=, [], [var(:b), rhs]}
  defp effect(n), do: {{:., [], [Effects, :effect]}, [], [n]}

  # === post-pass ============================================================

  # Rename each binding's `b` to `b1`, `b2`, … in prewalk order, so names are unique.
  defp number_bindings(condition) do
    {renamed, _n} =
      Macro.prewalk(condition, 1, fn
        {:=, meta, [lhs, rhs]}, n -> {{:=, meta, [rename(lhs, n), rhs]}, n + 1}
        node, n -> {node, n}
      end)

    renamed
  end

  defp rename({:b, meta, ctx}, n), do: {:"b#{n}", meta, ctx}
  defp rename({:ok, v}, n), do: {:ok, rename(v, n)}
end
