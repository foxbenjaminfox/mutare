defmodule Mutare.Mutators.Bitwise do
  @moduledoc """
  Bitwise operator/function swaps — the bit-twiddling sibling of
  `Mutare.Mutators.Arithmetic`, asking: does any test actually depend on *which*
  bitwise combination this does?

    * `&&&` ↔ `|||`   (band ↔ bor)       — the AND/OR pair
    * `<<<` ↔ `>>>`   (bsl ↔ bsr)        — the shift-left/right pair
    * `~~~x` → `x`    (bnot)             — drop the complement, the bitwise twin of
      Arithmetic's unary-minus removal

  Both spellings are covered: the **operators** (`a &&& b`, `~~~x`) and the
  **function** forms (`Bitwise.band(a, b)`, `import Bitwise; bsl(x, n)`,
  `Bitwise.bnot(x)`). The function forms match aliased and imported calls too, and are
  pipe-safe (`x |> bsl(n)` → `x |> bsr(n)`).

  All bitwise operators and functions are **guard-legal**, so a swap inside a `when`
  guard is mutated too. On by default.

  ## Equivalent shifts are skipped

  A shift by a literal `0` is an identity in *both* directions (`x <<< 0 == x == x >>> 0`),
  so swapping `<<<`↔`>>>` (or `bsl`↔`bsr`) there is an equivalent no-op — skipped. The
  AND/OR pair has no such literal identity (`x &&& 0 == 0` but `x ||| 0 == x`), so those
  are always offered. `~~~x` is never equivalent to `x` (`~~~x == -x - 1`), so it is
  always offered.

  ## Scope and known gaps

  `bxor`/`^^^` are left alone — XOR has no natural complementary sibling, so swapping it to
  AND or OR would be an arbitrary mapping, trading signal for noise. `~~~` and `^^^` are the
  *deprecated* operators (the compiler nudges toward `Bitwise.bnot/1`/`bxor/2`); a `~~~`
  that compiles is still stripped, but the primary complement form is the function `bnot`.
  A `bnot` **as a pipe stage** (`x |> bnot()`) is not stripped — a rare, safe miss.
  `use Bitwise` injects its imports via macro expansion, invisible without expanding it.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to
  suppress just one kind (`c:Mutare.Mutator.variants/0`): `&&&`, `|||`, `<<<`, `>>>`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Transform.Calls

  # The bitwise pairs we swap, one row per **unordered** pair: its two operator spellings,
  # its two function-call spellings, and whether it is a shift (whose swap is an equivalent
  # no-op on a literal `0`). The operator atom (`:&&&`) and the function name (`:band`) have
  # no programmatic relationship, so both spellings are listed — but only once, here: every
  # table below is derived from this, so adding a pair is a single row, not four edits kept
  # in lockstep. (`bxor`/`^^^` is deliberately absent — XOR has no natural complementary
  # sibling — and `~~~`/`bnot` is a unary strip, handled by its own clause.)
  #
  #                op_a   op_b   fun_a  fun_b  shift?
  @bitwise_pairs [
    {:&&&, :|||, :band, :bor, false},
    {:<<<, :>>>, :bsl, :bsr, true}
  ]

  # Binary *operator* swaps (both directions), keyed on the operator atom the parser emits
  # regardless of whether `Bitwise` is imported — so an arity-blind `mutate/1` swap is sound.
  @op_swaps for {a, b, _, _, _} <- @bitwise_pairs,
                {from, to} <- [{a, b}, {b, a}],
                into: %{},
                do: {from, to}

  # Binary *function* swaps (both directions), keyed on the resolved function name (the
  # module is always `[:Bitwise]`, pinned at the match site).
  @call_swaps for {_, _, fa, fb, _} <- @bitwise_pairs,
                  {from, to} <- [{fa, fb}, {fb, fa}],
                  into: %{},
                  do: {from, to}

  # The shift operators/functions, whose swap is an equivalent no-op when the shift amount
  # is a literal `0` (both directions are identity).
  @shift_ops for {a, b, _, _, true} <- @bitwise_pairs, op <- [a, b], do: op
  @shift_calls for {_, _, fa, fb, true} <- @bitwise_pairs, fun <- [fa, fb], do: fun

  # The operator / function names with a defined swap — the dispatch guards read these.
  @swap_ops Map.keys(@op_swaps)
  @swap_calls Map.keys(@call_swaps)

  @impl Mutare.Mutator
  def name, do: :bitwise

  # `~~~x` (operator) — drop the complement.
  @impl Mutare.Mutator
  def mutate({:"~~~", _meta, [operand]}), do: [operand]

  # `&&&`/`|||`/`<<<`/`>>>` (operators) — swap for the complementary operator, skipping a
  # shift by a literal `0` (an equivalent no-op).
  def mutate({op, meta, [left, right]}) when op in @swap_ops do
    if op in @shift_ops and literal_zero?(right) do
      :skip
    else
      [{Map.fetch!(@op_swaps, op), meta, [left, right]}]
    end
  end

  # Everything else: a bitwise *function* call (`Bitwise.band`, aliased, or imported).
  def mutate(node), do: swap_or_strip_call(node)

  # Resolve the node through `Mutare.Transform.Calls` and, if it is a `Bitwise` call we
  # handle, rename it to the complementary function (or, for `bnot`, strip the complement).
  # This resolves the call inline rather than via `Helpers.swap_call/2` because the two
  # special cases — `bnot` strips (no sibling) and a shift-by-literal-`0` is an equivalent
  # no-op skipped — don't fit the plain swap-table shape.
  defp swap_or_strip_call(node) do
    case Calls.resolved_call(node) do
      {[:Bitwise], :bnot, [operand], _rebuild} ->
        [operand]

      {[:Bitwise], fun, args, rebuild} when fun in @swap_calls ->
        if fun in @shift_calls and literal_zero?(List.last(args)) do
          :skip
        else
          [rebuild.(Map.fetch!(@call_swaps, fun), args)]
        end

      _ ->
        :skip
    end
  end

  # A literal integer `0`, in raw or Sourceror-wrapped (`{:__block__, _, [0]}`) form.
  defp literal_zero?(node), do: AST.literal_value(node) === {:ok, 0}

  # Variant labels for `# mutare:ignore[bitwise:<op>]`: the resulting *operator* of a binary swap.
  # Both spellings share one vocabulary: the operator swap (`a &&& b` → `a ||| b`) is classified by
  # `op_swap_variant/3` over `@swap_ops`, and the function-call swap (`Bitwise.band(a, b)` →
  # `Bitwise.bor(a, b)`) is mapped to the *same* operator label via the resolved original — so
  # `[bitwise:|||]` suppresses the OR result in either form (matching Arithmetic, which labels its
  # `div`/`rem` call form). The `~~~`/`bnot` complement strip stays unlabeled (no operator result).
  # Derived from `@op_swaps` so the operator set is single-sourced (order is irrelevant — used only
  # for `in`/`MapSet` membership).
  @swap_ops Map.keys(@op_swaps)

  # The operator label each *resulting* bitwise function corresponds to, so a call-form swap names
  # the same variant as the operator-form swap.
  @fun_to_op %{band: "&&&", bor: "|||", bsl: "<<<", bsr: ">>>"}

  @impl Mutare.Mutator
  def variants, do: Enum.map(@swap_ops, &to_string/1)

  @impl Mutare.Mutator
  def variant(original, mutated) do
    case Mutare.Mutator.op_swap_variant(original, mutated, @swap_ops) do
      nil -> call_swap_variant(original)
      label -> label
    end
  end

  # A function-form swap names the operator its *result* corresponds to. The swap is deterministic
  # from the original function (`@call_swaps`), so only the stamped original need resolve — the
  # rebuilt mutant's (possibly `Elixir.`-qualified) form needn't. A `bnot` strip (not in
  # `@call_swaps`) and a non-`Bitwise` call yield `nil`.
  defp call_swap_variant(original) do
    with {[:Bitwise], fun, _args, _rebuild} <- Calls.resolved_call(call_ref(original)),
         result when not is_nil(result) <- Map.get(@call_swaps, fun) do
      Map.fetch!(@fun_to_op, result)
    else
      _ -> nil
    end
  end

  # A bitwise function swap reaches `variant/2` as a written call (`Bitwise.band(a, b)`) *or* as a
  # captured reference (`&Bitwise.band/2` → `&Bitwise.bor/2`, mutated by `Transform.Analyze.Captures`).
  # A capture records its `&` form, so unwrap it to the inner `Bitwise.band()` ref before resolving —
  # it carries the same alias stamp that let the synthesized call resolve, so it resolves
  # identically. A written call (any other node) passes through unchanged.
  defp call_ref({:&, _meta, [{:/, _meta2, [ref, _arity]}]}), do: ref
  defp call_ref(node), do: node
end
