defmodule Mutare.ConditionsPropertyTest do
  @moduledoc """
  Property pins for `Mutare.Transform.Analyze.Conditions`' parallel spine walks — the
  precondition NOTES sets before those walks may be collapsed into one generic
  `spine_walk(node, acc, handlers)`. Each walk is checked against an independent reference
  model written here (`escaping/1`, `spine/1`: the `=` bindings reachable without entering an
  isolating form, resp. also not a branch form or a short-circuit's right operand), and the
  hoist rewrite is checked by *evaluation*: whenever the hoist gate holds, the hoisted
  statements plus the rewritten condition must yield the same value, the same bindings, and
  the same effect sequence as the original condition. A generalisation mistake therefore
  surfaces as a behavioural difference, not as a survived equivalent.
  """
  # Pure: evaluates quoted expressions in-process (no module definitions, no selector flips),
  # so it runs async.
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.Test.ConditionGen, as: Gen
  alias Mutare.Transform.Analyze.Conditions
  alias Mutare.Transform.{Meta, Names}

  @numtests 300
  @max_size 16
  @moduletag timeout: 600_000
  @moduletag :property

  # Mirrors of the module's form classes — restated here on purpose, so a change to the
  # module's lists is checked against the model rather than absorbed by it.
  @short_circuit [:and, :or, :&&, :||]
  @branch [:if, :unless, :cond, :case, :receive]
  @isolating [:fn, :for, :with, :try, :quote]

  property "escaping / spine / off-spine agree with the reference model",
    numtests: @numtests,
    max_size: @max_size do
    forall c <- Gen.condition() do
      Conditions.spine_bindings(c) == spine(c) and
        Conditions.escaping_binding?(c) == (escaping(c) != []) and
        Conditions.offspine_escaping_binding?(c) == (escaping(c) -- spine(c) != []) and
        Conditions.refutable_spine_count(c) == Enum.count(spine(c), &refutable?/1)
    end
  end

  property "every spine binding is exactly one :binding evaluation step",
    numtests: @numtests,
    max_size: @max_size do
    forall c <- Gen.condition() do
      Enum.count(Conditions.eval_steps(c), &(&1 == :binding)) == length(spine(c))
    end
  end

  property "the rewrite lifts every spine binding and nothing else",
    numtests: @numtests,
    max_size: @max_size do
    forall c <- Gen.condition() do
      {rewritten, hoists} = Conditions.spine_rewrite(c)

      Conditions.spine_bindings(rewritten) == [] and
        length(hoists) == length(spine(c)) + Enum.count(spine(c), &refutable?/1) and
        Conditions.escaping_binding?(rewritten) == Conditions.offspine_escaping_binding?(c)
    end
  end

  property "a hoisted condition evaluates like the original: value, bindings, effect order",
    numtests: @numtests,
    max_size: @max_size do
    forall c <- Gen.condition() do
      # The hoist gate, minus the two parts that are about routing rather than the condition
      # (`Meta.skipped?/1` and an enabled condition mutator).
      hoistable? =
        Conditions.escaping_binding?(c) and
          not Conditions.offspine_escaping_binding?(c) and
          not Conditions.spine_reorders?(c) and
          Conditions.refutable_spine_count(c) <= 1

      implies hoistable? do
        {rewritten, hoists} = Conditions.spine_rewrite(c)

        hoisted =
          Names.substitute_hoist_placeholder(
            {:__block__, [], hoists ++ [rewritten]},
            :mutare_cond
          )

        {value, bindings, effects} = run(c)
        {value2, bindings2, effects2} = run(hoisted)

        value2 == value and effects2 == effects and
          Map.delete(bindings2, :mutare_cond) == bindings
      end
    end
  end

  property "pruning strips exactly the proper ancestors of an escaping binding",
    numtests: @numtests,
    max_size: @max_size do
    forall c <- Gen.condition() do
      stamped = stamp(c)
      {pruned, has?} = Conditions.prune_binding_ancestors(stamped)

      has? == (escaping(c) != []) and stripped(pruned) == expected_stripped(stamped)
    end
  end

  # === reference model ======================================================

  # Every `=` reachable without entering an isolating form; the `=` is collected, not entered.
  defp escaping(node), do: bindings_in(node, false)

  # Every `=` reachable without entering an isolating form, a branch form, or a
  # short-circuit's right operand — the bindings a hoist can lift.
  defp spine(node), do: bindings_in(node, true)

  defp bindings_in({:=, _meta, _args} = binding, _spine?), do: [binding]
  defp bindings_in({form, _meta, _args}, _spine?) when form in @isolating, do: []
  defp bindings_in({form, _meta, _args}, true) when form in @branch, do: []

  defp bindings_in({op, _meta, [left, _right]}, true) when op in @short_circuit,
    do: bindings_in(left, true)

  defp bindings_in({_form, _meta, args}, spine?) when is_list(args),
    do: Enum.flat_map(args, &bindings_in(&1, spine?))

  defp bindings_in({left, right}, spine?),
    do: bindings_in(left, spine?) ++ bindings_in(right, spine?)

  defp bindings_in(list, spine?) when is_list(list),
    do: Enum.flat_map(list, &bindings_in(&1, spine?))

  defp bindings_in(_leaf, _spine?), do: []

  defp refutable?({:=, _meta, [{name, _vmeta, ctx}, _rhs]}) when is_atom(name) and is_atom(ctx),
    do: false

  defp refutable?({:=, _meta, _args}), do: true

  # === evaluation ===========================================================

  # `{value, bindings made, effects in order}` of evaluating `ast` in the generator's
  # environment. Compiler diagnostics (an unused binding, say) stay per-process.
  defp run(ast) do
    flush()

    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, Code.eval_quoted(ast, Gen.bindings_env())}
        rescue
          e -> {:error, e}
        end
      end)

    case result do
      {:ok, {value, binding}} ->
        made = binding |> Map.new() |> Map.drop(Keyword.keys(Gen.bindings_env()))
        {value, made, flush()}

      {:error, e} ->
        # Premise: the generated condition must evaluate. Both the original and its hoist go
        # through here, so a failure is a generator bug (invalid Elixir) or a hoist that broke
        # compilation — either way worth its own message, not a silent mismatch.
        flunk("""
        does not evaluate: #{Exception.message(e)}
        #{Enum.map_join(diagnostics, "\n", & &1.message)}

        #{Macro.to_string(ast)}
        """)
    end
  end

  defp flush do
    receive do
      {:effect, n} -> [n | flush()]
    after
      0 -> []
    end
  end

  # === prune model ==========================================================

  @nid :mutare_test_nid

  # Give every metadata-bearing node a test identity and a dummy in-place candidate.
  defp stamp(condition) do
    {stamped, _n} =
      Macro.postwalk(condition, 0, fn
        {form, meta, args}, n when is_list(meta) ->
          {Meta.put_candidates({form, [{@nid, n} | meta], args}, :in_place, [:dummy]), n + 1}

        node, n ->
          {node, n}
      end)

    stamped
  end

  # The identities whose candidate the prune removed.
  defp stripped(pruned) do
    {_tree, ids} =
      Macro.postwalk(pruned, MapSet.new(), fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          if Keyword.has_key?(meta, @nid) and Meta.candidates(node, :in_place) == [],
            do: {node, MapSet.put(acc, meta[@nid])},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    ids
  end

  # A node with arguments is a proper ancestor of an escaping binding iff some argument
  # subtree holds one; nothing inside an isolating form is touched.
  defp expected_stripped(node), do: expected(node, MapSet.new())

  defp expected({form, _meta, args}, acc) when is_list(args) and form in @isolating, do: acc

  defp expected({_form, meta, args}, acc) when is_list(args) do
    acc = if Enum.any?(args, &(escaping(&1) != [])), do: MapSet.put(acc, meta[@nid]), else: acc
    Enum.reduce(args, acc, &expected/2)
  end

  defp expected({left, right}, acc), do: expected(right, expected(left, acc))
  defp expected(list, acc) when is_list(list), do: Enum.reduce(list, acc, &expected/2)
  defp expected(_leaf, acc), do: acc
end
