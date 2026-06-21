defmodule Mutare.TransformPropertyGenerators do
  @moduledoc """
  Shared PropCheck generators for the transform property tests
  (`transform_property_test.exs` — renders valid Elixir, no equivalent mutant — and
  `transform_compile_property_test.exs` — the metamutant compiles).

  The generators emit a small Elixir **AST** from building blocks that are valid *and
  compilable* by construction, turned into source with `Macro.to_string/1` (no token
  metadata, so it sidesteps Sourceror's clean-meta `:token` footgun; the transform's
  own `Sourceror.to_string` renderer is what's under test). Every leaf is a bound
  parameter or a literal and the generated calls/clauses are total, so a generated
  module both parses and compiles — which keeps shrinking honest (a shrunk
  counterexample is real, paste-able Elixir) and lets the compile property attribute a
  failure to the transform, not the generator.

  The construct set favours what the mutators and the transform's trickier paths target
  — operators, comparisons, conditionals (`if`/`case`/`cond`), pipes, `with`/`fn`/`try`
  binding scopes, multi-clause heads, literal head patterns (incl. negatives), default
  args (lifting + dispatcher forwarding), guards, and literal/collection families — over
  raw breadth, so a modest `numtests` budget spends its randomness where rendering /
  compilation is most likely to trip.
  """
  use PropCheck

  # === top level ============================================================

  @doc """
  A whole module wrapping a handful of generated functions, so module-planning /
  lifting / dispatcher paths are exercised, not just in-place body selectors. The
  module name is fixed (`Prop`); a caller that *compiles* the result purges the module
  between runs (it is parsed, never linked against) so the fixed name doesn't clash.
  """
  def module_gen do
    let function_lists <- non_empty(list(function_gen())) do
      functions =
        function_lists
        |> Enum.with_index()
        |> Enum.flat_map(fn {clauses, i} -> rename_group(clauses, i) end)

      {:defmodule, [], [{:__aliases__, [], [:Prop]}, [do: block(functions)]]}
    end
  end

  # Give each function *group* a module-unique name so independently-generated functions
  # never collide on name+arity. The fixed name pool means two functions routinely share a
  # name — harmless for plain clauses (Elixir just warns about non-consecutive clauses),
  # but a **default arg** makes it a hard error: `f(a \\ 0)` defines `f/0` *and* `f/1`, so a
  # sibling `f/0` or `f/1` clashes and the *input* won't compile (a generator bug, not the
  # transform's). Renaming per group sidesteps it. Clauses within a group keep the *same*
  # new name, so a multi-clause group stays one liftable function; the original name's
  # `?`/`!` flavour is preserved (it must stay trailing) to keep exercising lifted-base
  # name sanitisation.
  defp rename_group(clauses, index) do
    name = :"fun#{index}#{name_suffix(clauses)}"
    Enum.map(clauses, &rename_clause(&1, name))
  end

  defp name_suffix([clause | _]) do
    base = clause |> clause_name() |> Atom.to_string()

    cond do
      String.ends_with?(base, "?") -> "?"
      String.ends_with?(base, "!") -> "!"
      true -> ""
    end
  end

  defp clause_name({:def, _, [head, _body]}), do: head_name(head)
  defp head_name({:when, _, [call, _guard]}), do: head_name(call)
  defp head_name({name, _, _args}), do: name

  defp rename_clause({:def, m, [head, body]}, name),
    do: {:def, m, [rename_head(head, name), body]}

  defp rename_head({:when, m, [call, guard]}, name),
    do: {:when, m, [rename_call(call, name), guard]}

  defp rename_head(call, name), do: rename_call(call, name)
  defp rename_call({_old, m, args}, name), do: {name, m, args}

  # === functions ============================================================

  # One function, weighted toward plain bodies. Each generator yields a *list* of `def`
  # clauses (most a single clause; the multi-clause head returns two), flattened into
  # the module body by `module_gen/0` — so a 2-clause group renders as two top-level
  # `def`s, never a parenthesised block.
  defp function_gen do
    frequency([
      {4, one(plain_function_gen())},
      {2, one(guarded_function_gen())},
      {1, one(pattern_function_gen())},
      {2, literal_clause_function_gen()},
      {1, one(default_args_function_gen())}
    ])
  end

  defp one(gen), do: let(clause <- gen, do: [clause])

  defp plain_function_gen do
    let {fname, params} <- {fun_name(), params_gen()} do
      {:def, [], [{fname, [], Enum.map(params, &var/1)}, [do: expr_gen(params)]]}
    end
  end

  # A guarded clause `def f(a) when <guard>, do: <expr>` — exercises lifting.
  defp guarded_function_gen do
    let {fname, params} <- {fun_name(), non_empty_params_gen()} do
      head = {fname, [], Enum.map(params, &var/1)}
      guarded = {:when, [], [head, guard_gen(params)]}
      {:def, [], [guarded, [do: expr_gen(params)]]}
    end
  end

  # A destructuring head `def f({x, y}, ...), do: <expr>` — the first slot is a 2-tuple
  # binding fresh names the body may use; the rest stay plain.
  defp pattern_function_gen do
    let {fname, params} <- {fun_name(), non_empty_params_gen()} do
      [_first | rest] = params
      head_args = [{:{}, [], [var(:x), var(:y)]} | Enum.map(rest, &var/1)]
      {:def, [], [{fname, [], head_args}, [do: expr_gen([:x, :y | rest])]]}
    end
  end

  # A two-clause function whose first clause matches a **literal** in its first slot
  # (incl. a negative number — the literal-head lift, and the match-position fix) and
  # whose second clause is an irreducible catch-all (so it always compiles and the
  # group is exhaustive). Exercises head-pattern literal lifting *and* clause drop.
  defp literal_clause_function_gen do
    let {fname, params} <- {fun_name(), non_empty_params_gen()} do
      [_first | rest] = params
      lit_head = [literal_gen() | Enum.map(rest, &var/1)]
      lit_clause = {:def, [], [{fname, [], lit_head}, [do: expr_gen(rest)]]}
      catch_clause = {:def, [], [{fname, [], Enum.map(params, &var/1)}, [do: expr_gen(params)]]}
      [lit_clause, catch_clause]
    end
  end

  # A function with a trailing default arg `def f(a, b \\ <literal>), do: <expr>` — the
  # `\\` rides the public dispatcher, exercising default-arg lifting + forwarding.
  defp default_args_function_gen do
    let {fname, params} <- {fun_name(), non_empty_params_gen()} do
      {init, [last]} = Enum.split(params, length(params) - 1)
      head = Enum.map(init, &var/1) ++ [{:\\, [], [var(last), literal_gen()]}]
      {:def, [], [{fname, [], head}, [do: expr_gen(params)]]}
    end
  end

  # === expressions ==========================================================

  # A runtime expression over the in-scope names `vars`. Depth is capped low (4): each
  # generated `def` is rendered to source twice (input, then metamutant) and Sourceror's
  # formatter is super-linear in nesting depth, so a deeper tree mostly buys rendering
  # time, not coverage of the syntactic corners the mutators care about.
  def expr_gen(vars), do: sized(size, expr_sized(min(size, 4), vars))

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
      {2, cond_gen(smaller)},
      {2, pipe_gen(smaller)},
      {1, collection_gen(smaller)},
      {1, with_gen(size, vars)},
      {1, fn_gen(size, vars)},
      {1, try_gen(smaller)}
    ])
  end

  # A leaf: an in-scope variable or a literal. With no variables in scope (a 0-arity
  # function), only literals are offered.
  defp leaf_gen([]), do: literal_gen()
  defp leaf_gen(vars), do: oneof([literal_gen(), let(name <- oneof(vars), do: var(name))])

  # `integer()`/`float()` produce negatives, so negative literals flow into every
  # position (incl. case-clause and head patterns) for free — the corner the
  # double-negative / match-position fixes live in.
  defp literal_gen do
    oneof([integer(), float(), let(s <- ascii_string(), do: s), atom_gen(), bool_gen()])
  end

  # Arithmetic over two sub-expressions. `+`/`-`/`*` only — division/`rem` are left out
  # so generation never reasons about a zero divisor (the rendering/compile properties
  # are indifferent to runtime values, but this keeps generated modules total).
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

  # A `case` over a generated subject with a literal-matching clause and an irrefutable
  # catch-all, so it is always exhaustive and total. The literal clause exercises
  # `case`-clause pattern mutation (tuple-the-scrutinee), incl. a negative literal.
  defp case_gen(sub) do
    let {subject, lit, body1, body2} <- {sub, literal_gen(), sub, sub} do
      clauses = [{:->, [], [[lit], body1]}, {:->, [], [[var(:_)], body2]}]
      {:case, [], [subject, [do: clauses]]}
    end
  end

  # A `cond` with a generated condition and a `true ->` catch-all (so it never raises a
  # `CondClauseError`). Exercises the `cond`-condition routing (IfCondition).
  defp cond_gen(sub) do
    let {cond_e, body1, body2} <- {sub, sub, sub} do
      {:cond, [], [[do: [{:->, [], [[cond_e], body1]}, {:->, [], [[true], body2]}]]]}
    end
  end

  # A pipe into a stdlib call the call-matching mutators target. Each stage is total for
  # any term (`to_string`, `inspect`), or the value is wrapped in a list first so the
  # `Enum` call is valid.
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

  # A small list, tuple, or keyword-syntax map literal of sub-expressions — exercises
  # the collection-literal families and key/value routing.
  defp collection_gen(sub) do
    oneof([
      let({a, b} <- {sub, sub}, do: [a, b]),
      let({l, r} <- {sub, sub}, do: {:{}, [], [l, r]}),
      let({k, v} <- {atom_gen(), sub}, do: {:%{}, [], [{k, v}]})
    ])
  end

  # `with w <- <src> do <body> else (_ -> <alt>) end` — `w` is in scope for the body, so
  # the bound value *escapes* the `<-` clause into the `do` block, exercising the
  # value-discarded-match / with-clause routing. The else arm keeps it total.
  defp with_gen(size, vars) do
    half = div(size, 2)

    let {src, body, alt} <-
          {expr_sized(half, vars), expr_sized(half, [:w | vars]), expr_sized(half, vars)} do
      clause = {:<-, [], [var(:w), src]}
      {:with, [], [clause, [do: body, else: [{:->, [], [[var(:_)], alt]}]]]}
    end
  end

  # An immediately-applied closure `(fn f -> <body> end).(<arg>)` — `f` is in scope for
  # the body. Total (a closure applied to a value), exercising `fn`-clause routing.
  defp fn_gen(size, vars) do
    half = div(size, 2)

    let {body, arg} <- {expr_sized(half, [:f | vars]), expr_sized(half, vars)} do
      fun = {:fn, [], [{:->, [], [[var(:f)], body]}]}
      {{:., [], [fun]}, [], [arg]}
    end
  end

  # `try do <body> rescue _e -> <alt> end` — always total (the rescue catches), exercising
  # the rescue routing (RescueType) and the `try` body's return-tail mutation.
  defp try_gen(sub) do
    let {body, alt} <- {sub, sub} do
      {:try, [], [[do: body, rescue: [{:->, [], [[var(:_e)], alt]}]]]}
    end
  end

  # === guards ===============================================================

  # A guard over the in-scope params: a comparison against a literal or an `is_*` check,
  # optionally AND/OR-combined. Every operand is a bound variable or a literal, so the
  # guard is always guard-legal.
  defp guard_gen(params), do: sized(size, guard_sized(min(size, 4), params))

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

  # A function name from a small fixed pool. The `?`/`!` names exercise the lifted-base
  # name sanitization; all are valid identifiers.
  defp fun_name, do: oneof([:run, :calc, :handle, :value, :ok?, :go!, :compute])

  # 0–3 (or 1–3) parameters drawn from a fixed pool, in order and without repeats, so
  # every head is a legal pattern and bodies can reference any of them.
  defp params_gen, do: let(count <- integer(0, 3), do: Enum.take([:a, :b, :c], count))
  defp non_empty_params_gen, do: let(count <- integer(1, 3), do: Enum.take([:a, :b, :c], count))

  defp atom_gen, do: oneof([:ok, :error, :pending, :alpha, :beta])
  defp bool_gen, do: oneof([true, false])

  # A short printable ASCII string (letters/spaces only, no escapes/quotes/newlines), so
  # it stays a single static binary that renders unambiguously.
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
