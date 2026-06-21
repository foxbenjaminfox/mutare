defmodule Mutare.TransformPropertyTest do
  @moduledoc """
  A property-based companion to `transform_test.exs` / `transform_corpus_test.exs`.

  Those check intended and adversarial examples one assertion at a time. This file
  instead asserts the single invariant the whole tool rides on — **the transform
  always renders syntactically valid Elixir** — over a stream of *randomly
  generated* modules, so a rendering bug in a syntactic corner no hand-written
  example happened to hit still gets caught.

  The bet (`CLAUDE.md`, `DESIGN.md`): the metamutant is compiled exactly once, so a
  single un-renderable / un-parseable mutant would sink the whole run. The property
  is therefore the strongest cheap check we can make of the renderer:

      for every valid Elixir module `m`,
        `Mutare.transform_string(m)` produces source that parses as valid Elixir.

  ## Generating the input

  A property test is only meaningful if its *input* is valid Elixir — a generated
  program that doesn't parse would make the transform raise for a reason unrelated
  to rendering. So we generate a small Elixir **AST** from building blocks that are
  valid by construction (integer/float arithmetic, comparisons, boolean logic,
  `if`/`case`, pipes into stdlib calls, list/tuple/map literals, string/atom
  literals, guards, destructuring heads) and turn it into source with
  **`Macro.to_string/1`**.

  Two deliberate choices keep this robust and the test honest:

    * **`Macro.to_string`, not `Sourceror.to_string`, for the input.** The tool's
      real entry point is `transform_string(source)`, which runs
      `Sourceror.parse_string!` *itself* — so the input path is text, not a tree we
      pre-render. `Macro.to_string` needs no token metadata and parenthesizes
      correctly, sidestepping Sourceror's clean-meta `:token` footgun (the very
      thing a hand-built literal node trips). The transform's *own* renderer
      (`Sourceror.to_string`, the thing under test) is still exercised on its
      output.
    * **Bare AST values, never `{:__block__, _, [literal]}` wrappers.** Plain
      integers/floats/strings/atoms in the tree render cleanly under
      `Macro.to_string`; the wrapper shapes are a Sourceror-parse artifact the
      generator has no reason to fake.

  Every leaf is a bound parameter or a literal and the generated calls are total, so
  the module is valid by construction — which keeps shrinking honest: a shrunk
  counterexample is still valid Elixir you can paste straight into
  `transform_test.exs`. The generator favours the constructs the mutators target
  (operators, comparisons, conditionals, pipes, patterns, guards, literals) over
  breadth, so a modest `numtests` budget spends its randomness where the renderer is
  most likely to trip.
  """
  use ExUnit.Case, async: true
  use PropCheck

  # The property only renders and parses strings — it flips no global state and
  # defines no modules (each generated module is parsed, never compiled, so there
  # are no name collisions) — so it is pure and runs async. `numtests` is kept
  # modest because each run renders + parses a whole module; the ExUnit `timeout` is
  # raised because a handful of those whole-module renders (`Sourceror.to_string` on
  # the metamutant) are individually slow, and the default 60s cap can clip a run.
  @numtests 300
  @moduletag timeout: 300_000

  property "the metamutant always renders syntactically valid Elixir", numtests: @numtests do
    forall module_ast <- module_gen() do
      source = Macro.to_string(module_ast)

      # Premise: the generated *input* must itself parse, or a transform failure
      # would be the generator's fault, not the renderer's. This is valid by
      # construction, so a failure here is a generator bug — surfaced loudly rather
      # than mistaken for a rendering bug.
      case Code.string_to_quoted(source) do
        {:error, reason} ->
          report_failure("generated input did not parse", reason, source, nil)
          false

        {:ok, _} ->
          {metamutant, _sites, _next_id} = Mutare.transform_string(source, file: "prop.ex")

          case Code.string_to_quoted(metamutant) do
            {:ok, _} ->
              true

            {:error, reason} ->
              report_failure("metamutant did not parse", reason, source, metamutant)
              false
          end
      end
    end
  end

  # Surface the seed and the offending output on a counterexample, so it is
  # actionable straight from the test log (PropCheck also records the shrunk seed in
  # its `.ctex` file).
  defp report_failure(what, reason, source, metamutant) do
    IO.puts("""

    PROPERTY FAILURE: #{what}: #{inspect(reason)}
    === source ===
    #{source}
    === metamutant ===
    #{metamutant || "(transform not reached)"}
    """)
  end

  # === generators ===========================================================

  # A whole module wrapping a handful of generated functions, so the transform's
  # module-planning / lifting / dispatcher paths are exercised, not just in-place
  # body selectors. The module name is irrelevant (the source is parsed, never
  # compiled), so a fixed name is fine.
  defp module_gen do
    let functions <- non_empty(list(function_gen())) do
      {:defmodule, [], [{:__aliases__, [], [:Prop]}, [do: block(functions)]]}
    end
  end

  # One function definition. Parameters are drawn from a fixed ordered pool
  # (`a`/`b`/`c`), so every variable a body or guard references is in scope and the
  # head has no duplicate binding. Three shapes, weighted toward plain bodies:
  #
  #   * a plain `def f(a, b), do: <expr>`
  #   * a guarded clause `def f(a) when <guard>, do: <expr>` (exercises lifting)
  #   * a `def f({x, y}, ...), do: <expr>` with a destructuring head
  defp function_gen do
    frequency([
      {3, plain_function_gen()},
      {2, guarded_function_gen()},
      {1, pattern_function_gen()}
    ])
  end

  defp plain_function_gen do
    let {fname, params} <- {fun_name(), params_gen()} do
      {:def, [], [{fname, [], Enum.map(params, &var/1)}, [do: expr_gen(params)]]}
    end
  end

  defp guarded_function_gen do
    let {fname, params} <- {fun_name(), non_empty_params_gen()} do
      head = {fname, [], Enum.map(params, &var/1)}
      guarded = {:when, [], [head, guard_gen(params)]}
      {:def, [], [guarded, [do: expr_gen(params)]]}
    end
  end

  defp pattern_function_gen do
    let {fname, params} <- {fun_name(), non_empty_params_gen()} do
      [_first | rest] = params
      # Destructure the head's first slot into a 2-tuple `{x, y}`, binding fresh
      # names the body may use; the remaining params stay plain. The body sees the
      # tuple's bindings plus the plain tail.
      head_args = [{:{}, [], [var(:x), var(:y)]} | Enum.map(rest, &var/1)]
      {:def, [], [{fname, [], head_args}, [do: expr_gen([:x, :y | rest])]]}
    end
  end

  # A runtime expression over the in-scope variable names `vars`. `sized` bounds the
  # recursion depth so generation terminates; the leaves are literals and in-scope
  # variables (always valid, total), weighted high so the shrinker collapses toward
  # a bare leaf. The depth is capped low (4): each generated `def` is rendered to
  # source *twice* (the input, then the transform's metamutant), and `Sourceror`'s
  # formatter is super-linear in nesting depth — a deeper tree mostly buys rendering
  # time, not extra coverage of the syntactic corners the mutators care about.
  defp expr_gen(vars) do
    sized(size, expr_sized(min(size, 4), vars))
  end

  defp expr_sized(0, vars), do: leaf_gen(vars)

  defp expr_sized(size, vars) do
    smaller = expr_sized(div(size, 2), vars)

    frequency([
      {4, leaf_gen(vars)},
      {3, binary_op_gen(smaller)},
      {2, comparison_gen(smaller)},
      {2, boolean_op_gen(smaller)},
      {2, if_gen(smaller)},
      {2, case_gen(smaller)},
      {2, pipe_gen(smaller)},
      {1, collection_gen(smaller)}
    ])
  end

  # A leaf: an in-scope variable or a literal. With no variables in scope (a 0-arity
  # function), only literals are offered.
  defp leaf_gen([]), do: literal_gen()
  defp leaf_gen(vars), do: oneof([literal_gen(), let(name <- oneof(vars), do: var(name))])

  defp literal_gen do
    oneof([
      integer(),
      float(),
      let(s <- ascii_string(), do: s),
      atom_gen(),
      bool_gen()
    ])
  end

  # Arithmetic over two sub-expressions. `+`/`-`/`*` only — division/`rem` are left
  # out so generation never has to reason about a zero divisor; the rendering
  # property is indifferent to runtime values anyway, but this keeps generated
  # modules tidy.
  defp binary_op_gen(sub) do
    let({op, l, r} <- {oneof([:+, :-, :*]), sub, sub}, do: {op, [], [l, r]})
  end

  defp comparison_gen(sub) do
    let(
      {op, l, r} <- {oneof([:==, :!=, :<, :>, :<=, :>=, :===, :!==]), sub, sub},
      do: {op, [], [l, r]}
    )
  end

  defp boolean_op_gen(sub) do
    oneof([
      let({op, l, r} <- {oneof([:and, :or, :&&, :||]), sub, sub}, do: {op, [], [l, r]}),
      let(e <- sub, do: {:!, [], [e]}),
      let(e <- sub, do: {:not, [], [e]})
    ])
  end

  defp if_gen(sub) do
    let {cond_e, then_e, else_e} <- {sub, sub, sub} do
      {:if, [], [cond_e, [do: then_e, else: else_e]]}
    end
  end

  # A `case` over a generated subject with a literal-matching clause and an
  # irrefutable catch-all, so it is always exhaustive and total.
  defp case_gen(sub) do
    let {subject, lit, body1, body2} <- {sub, literal_gen(), sub, sub} do
      clauses = [{:->, [], [[lit], body1]}, {:->, [], [[var(:_)], body2]}]
      {:case, [], [subject, [do: clauses]]}
    end
  end

  # A pipe into a stdlib call the call-matching mutators target. The stage is total
  # for any term (`to_string`, `inspect`), or the value is wrapped in a list first so
  # the `Enum` call is valid.
  defp pipe_gen(sub) do
    oneof([
      let(e <- sub, do: {:|>, [], [e, {:to_string, [], []}]}),
      let(
        e <- sub,
        do: {:|>, [], [e, {{:., [], [{:__aliases__, [], [:Kernel]}, :inspect]}, [], []}]}
      ),
      let(
        e <- sub,
        do: {:|>, [], [[e], {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], []}]}
      )
    ])
  end

  # A small list, tuple, or keyword-syntax map literal of sub-expressions —
  # exercises the collection-literal families and key/value routing.
  defp collection_gen(sub) do
    oneof([
      let({a, b} <- {sub, sub}, do: [a, b]),
      let({l, r} <- {sub, sub}, do: {:{}, [], [l, r]}),
      let({k, v} <- {atom_gen(), sub}, do: {:%{}, [], [{k, v}]})
    ])
  end

  # A guard over the in-scope params: a comparison against a literal or an `is_*`
  # check, optionally AND/OR-combined. Every operand is a bound variable or a
  # literal, so the guard is always guard-legal.
  defp guard_gen(params) do
    sized(size, guard_sized(min(size, 4), params))
  end

  defp guard_sized(0, params), do: guard_leaf(params)

  defp guard_sized(size, params) do
    smaller = guard_sized(div(size, 2), params)

    frequency([
      {3, guard_leaf(params)},
      {1, let({op, l, r} <- {oneof([:and, :or]), smaller, smaller}, do: {op, [], [l, r]})}
    ])
  end

  defp guard_leaf(params) do
    oneof([
      let {op, p, n} <- {oneof([:>, :<, :>=, :<=, :==, :!=]), oneof(params), integer()} do
        {op, [], [var(p), n]}
      end,
      let {check, p} <- {oneof([:is_integer, :is_atom, :is_binary, :is_list]), oneof(params)} do
        {check, [], [var(p)]}
      end
    ])
  end

  # === small AST + value helpers ============================================

  # A function name from a small fixed pool. The `?`/`!` names exercise the
  # lifted-base name sanitization; all are valid identifiers.
  defp fun_name, do: oneof([:run, :calc, :handle, :value, :ok?, :go!, :compute])

  # 0–3 parameters drawn from the fixed pool, in order and without repeats, so every
  # head is a legal pattern and bodies can reference any of them.
  defp params_gen, do: let(count <- integer(0, 3), do: Enum.take([:a, :b, :c], count))
  defp non_empty_params_gen, do: let(count <- integer(1, 3), do: Enum.take([:a, :b, :c], count))

  defp atom_gen, do: oneof([:ok, :error, :pending, :alpha, :beta])
  defp bool_gen, do: oneof([true, false])

  # A short printable ASCII string (letters/spaces only, no escapes/quotes/newlines),
  # so it stays a single static binary that renders unambiguously.
  defp ascii_string do
    let chars <- list(oneof(Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z) ++ [?\s])) do
      List.to_string(Enum.take(chars, 12))
    end
  end

  defp var(name), do: {name, [], nil}

  # Wrap a list of statements in a block so a module body renders cleanly.
  defp block([single]), do: single
  defp block(statements), do: {:__block__, [], statements}
end
