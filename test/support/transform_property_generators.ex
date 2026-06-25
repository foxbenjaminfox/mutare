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
  — operators, comparisons, conditionals (`if`/`case`/`cond`), single- and **multi-stage
  pipes** (the latter driving `hoist_pipe`'s closure nesting down a chain of mutated stages),
  `with`/`fn`/`try` binding scopes, multi-clause heads, literal head patterns (incl.
  negatives), default args (lifting + dispatcher forwarding), guards, multi-statement blocks
  with value-discarded `=` matches (the `MatchPattern` swap/wildcard routing), `if`-condition
  binding **hoisting** (`if (v = …) != nil do … v …`), sigils (`~r`/`~w`/`~c`/`~D`…) and
  bitstrings, and literal/collection families — over raw breadth, so a modest `numtests`
  budget spends its randomness where rendering / compilation is most likely to trip.

  It also emits **stdlib calls the call-matching families target** (`Enum`/`String`/`Map`/
  `Keyword`/bare-`Kernel`), in two shapes. *Direct* calls (`String.upcase(s)`,
  `Enum.filter(l, f)`) sprinkle through the expression trees, so Collection / StringCall /
  StringByte / CallRemoval / CollectionArity / DefaultDrop / MapKeyword / Numeric all fire under the
  stream rather than only in hand-written examples. A dedicated `resolved_call_function_gen/0`
  then exercises the lexical name-resolution pre-pass (`Transform.Resolve` + `Aliases`/
  `Imports`) and the families' *rebuild* paths: a function body opens with `alias`/`import`
  directives and calls in the matching aliased / bare form — aliased (`alias String, as: S;
  S.upcase`), selective-import (qualify-on-rebuild), whole-import (keep-bare-on-rebuild),
  interleaved (`alias …; import …`), and even import *through* an alias (`alias Enum, as: E;
  import E`). Every call is total for any probe-pool term (or deterministically raises
  identically in original and baseline) and pure, so baseline-equivalence stays deterministic.

  Finally, about a quarter of modules carry a **module-level `use`** of a real, loadable
  Phoenix/Ecto-style bundle (`Mutare.Test.ControllerUsing` / its nested `NestedUsing`) plus one
  function calling the `import`/`alias` it injects — the only generator that drives the
  `use`-expansion pre-pass (`Transform.Uses`) under the stream. The directives (`import Enum,
  only: [reject: 2]` + `alias String, as: S`) arrive from *behind* a `use` rather than written
  inline, so the whole expand → harvest → stamp → resolve → rebuild path is exercised end to end
  (and the metamutant still parses / compiles / matches baseline). See `use_part_gen/0`.
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
    let {function_lists, use_part} <- {non_empty(list(function_gen())), use_part_gen()} do
      functions =
        function_lists
        |> Enum.with_index()
        |> Enum.flat_map(fn {clauses, i} -> rename_group(clauses, i) end)

      {:defmodule, [], [{:__aliases__, [], [:Prop]}, [do: block(use_part ++ functions)]]}
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
      {1, one(default_args_function_gen())},
      {2, one(resolved_call_function_gen())}
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

  # A function whose body opens with `alias`/`import` directives and then calls a stdlib
  # function in the matching aliased / bare form — the only generator that exercises the
  # name-resolution pre-pass (`Transform.Resolve` + `Aliases`/`Imports`) and the
  # call-matching families' rebuild paths (alias-preserving, qualify-on-selective-import,
  # keep-bare-on-whole-import). The directives sit at the top of the function body — a
  # nested lexical scope — so a child scope's additions never leak; see `resolved_body_gen/1`
  # for the forms (aliased / selective / whole / interleaved / import-through-alias).
  defp resolved_call_function_gen do
    let params <- non_empty_params_gen() do
      let {fname, body} <- {fun_name(), resolved_body_gen(params)} do
        {:def, [], [{fname, [], Enum.map(params, &var/1)}, [do: body]]}
      end
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
      {2, remote_call_gen(vars)},
      {1, sigil_gen()},
      {1, interp_string_gen(vars)},
      {1, bitstring_gen()},
      {1, utf_bitstring_gen()},
      {1, with_gen(size, vars)},
      {1, fn_gen(size, vars)},
      {1, try_gen(smaller)},
      {1, block_gen(size, vars)},
      {1, if_binding_gen(size, vars)}
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
  # `Enum` call is valid. The last branch is a **multi-stage** chain (see `pipe_chain_gen/1`).
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
      ),
      pipe_chain_gen(sub)
    ])
  end

  # A **multi-stage** `Enum` pipe chain `[<e>] |> Enum.reverse() |> Enum.sort() |> Enum.uniq()`
  # — 2–4 unary, list→list stages, each a call the call-matching families mutate (Collection /
  # CallRemoval / CollectionArity). Because several stages mutate at once, the metamutant nests
  # `hoist_pipe`'s one-shot closures *down* the chain (`lhs |> (fn p -> case … end).() |> (fn p
  # -> case … end).()`) — the only generator that drives that nesting at depth, the rewrite that
  # keeps a chain of mutated stages **linear** in depth instead of the ≈`(mutants+1)^depth` blowup
  # of distributing `lhs` into every selector branch. Total: the leaf is wrapped in a one-element
  # list so the first stage always gets an enumerable, and every stage is list→list for any
  # element terms (Elixir's total term ordering makes `sort` total across mixed types).
  defp pipe_chain_gen(sub) do
    let {e, count} <- {sub, integer(2, 4)} do
      let stages <- vector(count, pipe_stage_gen()) do
        Enum.reduce(stages, [e], fn stage, acc -> {:|>, [], [acc, stage]} end)
      end
    end
  end

  # One unary, list→list `Enum` stage, written piped (no args — the piped value is the `|>` LHS).
  defp pipe_stage_gen do
    let(
      fun <- oneof([:reverse, :sort, :uniq, :dedup]),
      do: {{:., [], [aliases([:Enum]), fun]}, [], []}
    )
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

  # A two-statement block `(<lhs> = <rhs>; <body>)` whose first statement is a
  # **value-discarded** `=` match binding fresh name(s) the block's value (the second
  # statement) uses. The simple form binds a bare variable; the destructuring form binds a
  # 2-tuple, which is what earns the non-final match its `MatchPattern` swap/wildcard
  # mutants (the tuple-re-export rewrite). Both are total: a bare match always succeeds and
  # the destructured RHS is a literal 2-tuple, so the pattern never fails. The match's RHS
  # is a *leaf* (the routing under test depends on the bound pattern, not on RHS depth) so
  # only the binding-using body recurses — keeping the added construct shallow, since
  # Sourceror's render is super-linear in nesting depth.
  defp block_gen(size, vars) do
    half = div(size, 2)

    oneof([
      let {rhs, body} <- {leaf_gen(vars), expr_sized(half, [:t | vars])} do
        {:__block__, [], [{:=, [], [var(:t), rhs]}, body]}
      end,
      let {e1, e2, body} <- {leaf_gen(vars), leaf_gen(vars), expr_sized(half, [:p, :q | vars])} do
        pat = {:{}, [], [var(:p), var(:q)]}
        match = {:=, [], [pat, {:{}, [], [e1, e2]}]}
        {:__block__, [], [match, body]}
      end
    ])
  end

  # `if (v = <rhs>) != nil do <body using v> else <alt> end` — the condition binds `v`,
  # which **escapes** into the `do` branch, exercising the if-condition binding hoisting /
  # pruning path (one of the transform's subtlest rewrites: the binding is lifted out of the
  # forced condition so the body's reference stays bound). Total: `v` is in scope only for
  # the `do` branch, and every branch returns a generated expression. Only the binding-using
  # body recurses (the RHS and `else` arm are leaves), so the construct stays shallow.
  defp if_binding_gen(size, vars) do
    half = div(size, 2)

    let {rhs, body, alt} <- {leaf_gen(vars), expr_sized(half, [:v | vars]), leaf_gen(vars)} do
      cond_e = {:!=, [], [{:=, [], [var(:v), rhs]}, nil]}
      {:if, [], [cond_e, [do: body, else: alt]]}
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

  # === remote calls =========================================================

  # A direct call into a stdlib module the call-matching families target. The direct
  # (written-out module) form needs no directive, so it nests anywhere an expression does;
  # the aliased / imported forms are `resolved_call_function_gen/0`'s job. Args are leaves
  # (so the call adds no rendering depth) shaped to keep each call total over the probe pool
  # — a list where a list is wanted, a binary where a binary is wanted — or, where any term
  # is legal (`Map.get`, `min`/`max`), a bare leaf. Anything that can still raise (a non-int
  # to `Integer`, etc.) is deterministic, so the baseline matches the original on the raise.
  defp remote_call_gen(vars) do
    oneof([
      # Enum over a list + predicate closure — Collection (filter↔reject, take/drop_while).
      let {fun, l, f} <-
            {oneof([:filter, :reject, :take_while, :drop_while]), list_arg(vars),
             pred_fun_gen(vars)} do
        remote(:Enum, fun, [l, f])
      end,
      # Enum over a list — CallRemoval / CollectionArity / Collection (sort total across types).
      let(
        {fun, l} <- {oneof([:reverse, :sort, :uniq, :dedup]), list_arg(vars)},
        do: remote(:Enum, fun, [l])
      ),
      # String unary — StringCall (case/direction pairs) / CallRemoval.
      let(
        {fun, s} <- {oneof([:upcase, :downcase, :trim, :reverse, :capitalize]), str_arg(vars)},
        do: remote(:String, fun, [s])
      ),
      # String predicate — StringCall (starts_with?↔ends_with?).
      let(
        {fun, s, p} <- {oneof([:starts_with?, :ends_with?]), str_arg(vars), ascii_string()},
        do: remote(:String, fun, [s, p])
      ),
      # String byte-narrowing — StringByte (length→Elixir.Kernel.byte_size).
      let(s <- str_arg(vars), do: remote(:String, :length, [s])),
      # Map lookup with a default — DefaultDrop (drop the trailing fallback).
      let({k, d} <- {leaf_gen(vars), leaf_gen(vars)}, do: remote(:Map, :get, [map_arg(), k, d])),
      # Map conditional write — MapKeyword (put↔put_new↔replace).
      let({k, v} <- {leaf_gen(vars), leaf_gen(vars)}, do: remote(:Map, :put, [map_arg(), k, v])),
      # Keyword lookup with a default — DefaultDrop.
      let(
        {k, d} <- {atom_gen(), leaf_gen(vars)},
        do: remote(:Keyword, :get, [keyword_arg(), k, d])
      ),
      # Bare-Kernel min/max — Numeric (the effective-arity bare-Kernel path; total ordering).
      let(
        {fun, l, r} <- {oneof([:min, :max]), leaf_gen(vars), leaf_gen(vars)},
        do: bare_call(fun, [l, r])
      )
    ])
  end

  # The `alias`/`import` body forms used by `resolved_call_function_gen/0`. Each yields a
  # `{:__block__, [], [<directives…>, <call>]}` whose directives sit at the function-body
  # scope and whose call uses the matching aliased / bare form, so the call-matching family
  # resolves and rebuilds it. Names are chosen to never clash with `Kernel` (so a whole
  # import and its bare call always compile).
  defp resolved_body_gen(vars) do
    oneof([
      alias_form_gen(vars),
      import_selective_form_gen(vars),
      import_whole_form_gen(vars),
      interleaved_form_gen(vars)
    ])
  end

  # `alias String, as: S; S.upcase(s)` — alias-preserving rebuild (the swap stays `S.`).
  defp alias_form_gen(vars) do
    oneof([
      let(
        s <- str_arg(vars),
        do: resolved_block([alias_directive(:String, :S)], aliased_call([:S], :upcase, [s]))
      ),
      let {l, f} <- {list_arg(vars), pred_fun_gen(vars)} do
        resolved_block([alias_directive(:Enum, :E)], aliased_call([:E], :reject, [l, f]))
      end
    ])
  end

  # `import String, only: [downcase: 1]; downcase(s)` — a selective import, so a swap
  # qualifies on rebuild (`Elixir.String.upcase(...)`).
  defp import_selective_form_gen(vars) do
    oneof([
      let(
        s <- str_arg(vars),
        do:
          resolved_block([import_only_directive(:String, downcase: 1)], bare_call(:downcase, [s]))
      ),
      let {l, f} <- {list_arg(vars), pred_fun_gen(vars)} do
        resolved_block([import_only_directive(:Enum, filter: 2)], bare_call(:filter, [l, f]))
      end
    ])
  end

  # `import String; upcase(s)` — a sole whole import (with `Kernel` unmanipulated), so a
  # swap stays bare on rebuild. The bare names never overlap `Kernel`.
  defp import_whole_form_gen(vars) do
    oneof([
      let(
        s <- str_arg(vars),
        do: resolved_block([import_whole_directive(:String)], bare_call(:upcase, [s]))
      ),
      let {l, f} <- {list_arg(vars), pred_fun_gen(vars)} do
        resolved_block([import_whole_directive(:Enum)], bare_call(:reject, [l, f]))
      end
    ])
  end

  # Two interleaved directives in one body — `alias …; import …` folded together in source
  # order, and an `import` resolved *through* an alias in force (`alias Enum, as: E; import E`).
  defp interleaved_form_gen(vars) do
    oneof([
      let {s, f} <- {str_arg(vars), pred_fun_gen(vars)} do
        directives = [alias_directive(:String, :S), import_only_directive(:Enum, reject: 2)]
        resolved_block(directives, bare_call(:reject, [aliased_call([:S], :graphemes, [s]), f]))
      end,
      let {l, f} <- {list_arg(vars), pred_fun_gen(vars)} do
        directives = [alias_directive(:Enum, :E), import_only_directive(:E, filter: 2)]
        resolved_block(directives, bare_call(:filter, [l, f]))
      end
    ])
  end

  # --- call/arg/directive builders ---

  defp remote(mod, fun, args), do: {{:., [], [aliases([mod]), fun]}, [], args}
  defp aliased_call(mod_path, fun, args), do: {{:., [], [aliases(mod_path), fun]}, [], args}
  defp bare_call(fun, args), do: {fun, [], args}

  defp alias_directive(mod, as_atom), do: {:alias, [], [aliases([mod]), [as: aliases([as_atom])]]}
  defp import_only_directive(mod, kw), do: {:import, [], [aliases([mod]), [only: kw]]}
  defp import_whole_directive(mod), do: {:import, [], [aliases([mod])]}
  defp aliases(path), do: {:__aliases__, [], path}
  defp resolved_block(directives, call), do: {:__block__, [], directives ++ [call]}

  # A two-element list of leaves — always an enumerable for the `Enum` calls.
  defp list_arg(vars), do: let({a, b} <- {leaf_gen(vars), leaf_gen(vars)}, do: [a, b])

  # Always a binary: a literal string, or `to_string/1` of any leaf (total for every term in
  # the probe pool — integers/atoms/booleans/nil/strings).
  defp str_arg(vars),
    do: oneof([ascii_string(), let(x <- leaf_gen(vars), do: {:to_string, [], [x]})])

  # A predicate closure `fn z -> <leaf over [z | vars]> end` — any returned term is a legal
  # filter/reject predicate (truthiness selects), so it is total.
  defp pred_fun_gen(vars),
    do: let(body <- leaf_gen([:z | vars]), do: {:fn, [], [{:->, [], [[var(:z)], body]}]})

  defp map_arg, do: oneof([{:%{}, [], []}, {:%{}, [], [{:a, 1}]}])
  defp keyword_arg, do: oneof([[], [ok: 1], [a: 1, b: 2]])

  # === sigils + bitstrings ==================================================

  # A sigil literal as a runtime **value** — `~r//` (RegexLiteral), `~w[]` (WordListLiteral),
  # `~c""` (CharlistLiteral), `~s()`/`~S()` (StringSigilLiteral), and the `~D`/`~T`/`~N`/`~U`
  # date-time sigils (DateTimeLiteral) — the only generator that exercises those six literal
  # families. Built with `quote` (the cleanest route to a faithful sigil AST that
  # `Macro.to_string` re-renders) and chosen via an **atom** `oneof`, since a literal sigil
  # tuple in a generator position would be read as a PropEr tuple-type combinator. Placed only
  # in runtime positions, never a pattern: a `~r//` expands to a `Regex.compile!` call and is
  # not pattern-legal, and `literal_gen/0` (which *does* feed head/clause patterns) is left
  # untouched. Contents are fixed and valid (a real date, a parseable regex), so the compile-time
  # sigil evaluation — and each family's mutant, which stays compile-safe by construction — compile
  # cleanly.
  defp sigil_gen do
    let choice <- oneof([:regex, :words, :charlist, :str, :str_raw, :date, :time, :naive, :utc]) do
      case choice do
        :regex -> quote(do: ~r/ab/)
        :words -> quote(do: ~w[a b c])
        :charlist -> quote(do: ~c"abc")
        :str -> quote(do: ~s(abc))
        :str_raw -> quote(do: ~S(abc))
        :date -> quote(do: ~D[2020-01-15])
        :time -> quote(do: ~T[12:30:00])
        :naive -> quote(do: ~N[2020-01-15 12:30:00])
        :utc -> quote(do: ~U[2020-01-15 12:30:00Z])
      end
    end
  end

  # An **interpolated** string / `~s` sigil as a runtime value — the only generator that
  # exercises the interpolation path of StringLiteral / StringSigilLiteral, where the whole
  # string mutates to `""`/`"mutare"` *and* the interpolated sub-expression mutates
  # independently underneath (nested selectors). The inner expression is a leaf (a bound var
  # or literal), kept shallow. Runtime-only: an interpolation is illegal in a pattern, and
  # `leaf_gen` (which feeds patterns) never produces one. `~S`/charlists never interpolate,
  # so only the `~s` and double-quoted forms are generated.
  defp interp_string_gen(vars) do
    let {shape, inner} <- {oneof([:string, :sigil]), leaf_gen(vars)} do
      case shape do
        :string -> quote(do: "a#{unquote(inner)}b")
        :sigil -> quote(do: ~s(a#{unquote(inner)}b))
      end
    end
  end

  # A `<<seg0, seg1, …>>` bitstring of 1–3 segments — a byte int (Literal) or a **string
  # literal** segment (StringLiteral). The string segment is the key case: untyped, it
  # defaults to a `binary` segment only as a literal, so a mutation's selector must be
  # type-pinned `::binary` or construction reverts to the integer default and raises (the
  # transform handles this — this generator exercises that path). BitstringLiteral also
  # collapses the whole `<<…>>` to `<<>>`. A runtime value, total for any input. Segments are
  # valid bytes (0–255) / binaries, and the `<<>>` carries no `:delimiter` meta, so it reads as
  # a bitstring literal rather than an interpolated string (which BitstringLiteral skips).
  defp bitstring_gen do
    let count <- integer(1, 3) do
      let segments <- vector(count, oneof([integer(0, 255), let(s <- ascii_string(), do: s)])) do
        {:<<>>, [], segments}
      end
    end
  end

  # A `<<cp::utfN>>` constructor (utf16/utf32 optionally `-big`/`-little`/`-native`) — the one
  # generator driving `Mutare.Mutators.BitstringSpec`'s Unicode encoding (`utf8 ↔ utf16 ↔ utf32`)
  # and byte-order (`big ↔ little`) swaps through the soaks, alongside Literal on the codepoint.
  # `cp ∈ 0..255` is a valid Unicode scalar under *every* encoding, so the constructor and all of
  # BitstringSpec's mutants (which share that validity domain) are total — baseline-equivalence
  # stays deterministic. A runtime constructor, so the whole `<<>>` is offered in a body and the
  # mutants ride the in-place selector (the same path BitstringLiteral takes).
  defp utf_bitstring_gen do
    let [cp <- integer(0, 255), spec <- utf_spec_gen()] do
      {:<<>>, [], [{:"::", [], [cp, spec]}]}
    end
  end

  # A utf type-specifier: a bare encoding, or (utf16/utf32 only) the encoding with a byte-order
  # modifier. utf8 is byte-oriented, so it carries none.
  defp utf_spec_gen do
    let enc <- oneof([:utf8, :utf16, :utf32]) do
      case enc do
        :utf8 ->
          exactly({:utf8, [], nil})

        _ ->
          oneof([
            {enc, [], nil},
            {:-, [], [{enc, [], nil}, {:big, [], nil}]},
            {:-, [], [{enc, [], nil}, {:little, [], nil}]},
            {:-, [], [{enc, [], nil}, {:native, [], nil}]}
          ])
      end
    end
  end

  # === module-level `use` ===================================================

  # Most modules carry no `use`; about a quarter prepend a **module-level** `use` of a real,
  # loadable Phoenix/Ecto-style bundle plus one function that calls the `import`/`alias` the
  # bundle injects — the only generator that drives the `use`-expansion pre-pass
  # (`Transform.Uses`) through the soaks. The bundle (`Mutare.Test.ControllerUsing`, and its
  # one-hop re-dispatch `NestedUsing`, which transitively yields the same directives) injects
  # `import Enum, only: [reject: 2]` + `alias String, as: S` at **module** scope, so the using
  # function calls a bare `reject(l, f)` (a selective import → *qualify-on-rebuild*) and an
  # aliased `S.upcase(s)` (*alias-preserving* rebuild) — the very resolution + rebuild paths
  # `resolved_call_function_gen/0` covers for *written* directives, now surfaced from behind a
  # `use`. The fixtures live in `test/support/using_fixtures.ex` (compiled in `:test`, where the
  # soaks run), so the `use` expands in-process; the calls stay total over the probe pool, so
  # baseline-equivalence stays deterministic. Returns `[]` or `[use_directive, using_function]`,
  # spliced ahead of the generated functions by `module_gen/0`.
  defp use_part_gen do
    frequency([
      {3, exactly([])},
      {1, let({use_dir, fun} <- use_with_function_gen(), do: [use_dir, fun])}
    ])
  end

  # A module-level `use` directive paired with a `def via_use(...)` whose body exercises the
  # directives it injects. The fixed name (`via_use`, outside the `fun<i>` space `rename_group/2`
  # mints) can't collide with a renamed generated function, and there is only ever one, so it
  # needs no renaming itself.
  defp use_with_function_gen do
    let params <- non_empty_params_gen() do
      let {use_dir, body} <- {use_directive_gen(), use_body_gen(params)} do
        {use_dir, {:def, [], [{:via_use, [], Enum.map(params, &var/1)}, [do: body]]}}
      end
    end
  end

  # One of the loadable `__using__` bundles, optionally with a static opt (`use Foo, :controller`,
  # exercising the opts-carrying expansion path). All three inject the same module-level `import
  # Enum, only: [reject: 2]` + `alias String, as: S`, so a single `use_body_gen/1` matches any of
  # them. The directive AST is built in the `let` body (plain code), not as a `oneof` element —
  # a literal tuple in a generator position would be read as a PropEr tuple-type combinator.
  defp use_directive_gen do
    let choice <- oneof([:controller, :controller_opt, :nested]) do
      case choice do
        :controller -> {:use, [], [aliases([:Mutare, :Test, :ControllerUsing])]}
        :controller_opt -> {:use, [], [aliases([:Mutare, :Test, :ControllerUsing]), :controller]}
        :nested -> {:use, [], [aliases([:Mutare, :Test, :NestedUsing])]}
      end
    end
  end

  # The using function's body: a call into the import/alias the module-level `use` injected, in
  # the bare (`reject`) / aliased (`S.upcase`) form, or both in a value-discarded block. Reuses
  # the same total arg builders as `remote_call_gen/1`.
  defp use_body_gen(vars) do
    oneof([
      let(s <- str_arg(vars), do: aliased_call([:S], :upcase, [s])),
      let({l, f} <- {list_arg(vars), pred_fun_gen(vars)}, do: bare_call(:reject, [l, f])),
      let {l, f, s} <- {list_arg(vars), pred_fun_gen(vars), str_arg(vars)} do
        {:__block__, [], [bare_call(:reject, [l, f]), aliased_call([:S], :upcase, [s])]}
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
