defmodule Mutare.BindingsOraclePropertyTest do
  @moduledoc """
  The binding readers checked against the Elixir compiler, over generated programs
  (`Mutare.Test.BindingOracleGenerators`), each reader in the direction it is allowed to
  err (`Mutare.Transform.Bindings`):

    * **Guaranteed bindings** (`BindingEscapeEmit.expression_bindings/1`). For every
      statement and every name, Elixir says whether the statement leaves the name bound: a
      twin of the statement with the name's reads renamed away and the name unbound on entry,
      then `binding()`. Where the statement holds no construct the model reads inexactly on
      purpose — a lazy position whose macro binds as statements, a classifier withheld
      beneath a skip — the two must agree exactly; where it does, the model may miss a
      binding but never claim one, and a binding it misses must be among its possible
      writes (`Bindings.matched_names/1`).
    * **Bound at a node** (the stamp's `bound` less `conflicts` and `uncertain`): every name
      the stamp calls readable as incoming is readable there per Elixir — the node
      substituted by a read of the name compiles. A sibling's fresh binding read as a
      statement's, a `match?/2` pattern read inside its value, a branch's binding read after
      the branch: each is an undefined variable here.
    * **Read after a node** (`later`): a name the stamp says nothing reads after the node,
      bound at the node instead, is one Elixir reports unused.

  Elixir expands the fixture macros, so their routes are checked against what they do, not
  what they declare. Each case compiles one throwaway module (the twins and the `later`
  probes, batched) and evaluates one anonymous function per readability claim.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias Mutare.CallRouting.Registry
  alias Mutare.Test.BindingOracleGenerators, as: Gen
  alias Mutare.Test.Compile
  alias Mutare.Transform.{BindingEscapeEmit, Bindings, Meta, MetaKeys, Resolve}

  @moduletag :property
  @moduletag timeout: 600_000
  @numtests 40

  property "the binding readers agree with the compiler where they must, and err only to " <>
             "their permitted side",
           numtests: @numtests,
           max_shrinks: 40 do
    forall program <- Gen.program() do
      disagreements = check(program)

      when_fail(
        disagreements == [],
        IO.puts(
          "\n" <>
            Gen.render_body(program.statements) <> "\n\n" <> inspect(disagreements, pretty: true)
        )
      )
    end
  end

  defp registry, do: Registry.build([], [], [Mutare.Test.BindingOracle])

  defp check(%{statements: statements}) do
    n = length(statements)
    model_source = module_source("Mutare.Test.BindingOracleModel", [def_run(statements)])

    resolved =
      model_source
      |> Sourceror.parse_string!()
      |> Resolve.annotate(registry(), warnings: false)
      |> Bindings.annotate()

    resolved_statements = body_statements(resolved)

    if length(resolved_statements) != n do
      [{:statement_count, n, length(resolved_statements)}]
    else
      nodes = resolved_statements |> Enum.flat_map(&stamped/1)
      later_probes = later_probes(nodes, resolved_statements)
      module = :"Elixir.Mutare.Test.BindingOracleCase#{System.unique_integer([:positive])}"

      defs =
        [def_run(statements)] ++
          twin_defs(statements) ++
          Enum.map(later_probes, fn {name, _node, _x, body} -> {name, ["a", "b"], body} end)

      {source, lines} = module_source_with_lines(inspect(module), defs)

      case Compile.string_result(source, "oracle.ex") do
        {{:ok, _}, diagnostics} ->
          try do
            run_check(module) ++
              guaranteed_checks(module, statements, resolved_statements) ++
              readable_checks(nodes, resolved_statements) ++
              later_checks(later_probes, lines, diagnostics)
          after
            :code.purge(module)
            :code.delete(module)
          end

        {{:error, _}, diagnostics} ->
          [{:oracle_module_failed, Compile.messages(diagnostics), source}]
      end
    end
  end

  # --- the program itself ------------------------------------------------------------------

  defp run_check(module) do
    module.run(:a0, :b0)
    []
  rescue
    error -> [{:program_raised, Exception.message(error)}]
  end

  # --- guaranteed bindings, per statement and name ------------------------------------------

  defp twin_defs(statements) do
    for {statement, k} <- Enum.with_index(statements, 1), x <- Gen.names() do
      renamed = Gen.rename_reads(statement, x, :"#{x}_in")
      params = Enum.map(Gen.names() -- [x], &Atom.to_string/1) ++ ["#{x}_in"]
      body = Gen.render_body([renamed]) <> "\nKeyword.has_key?(binding(), #{inspect(x)})"
      {"rebinds_#{k}_#{x}", params, body}
    end
  end

  defp guaranteed_checks(module, statements, resolved_statements) do
    for {{statement, resolved}, k} <-
          Enum.with_index(Enum.zip(statements, resolved_statements), 1),
        x <- Gen.names(),
        disagreement <- [guaranteed_check(module, k, x, statement, resolved)],
        disagreement != nil,
        do: disagreement
  end

  defp guaranteed_check(module, k, x, statement, resolved) do
    arity = length(Gen.names())
    truth = apply(module, :"rebinds_#{k}_#{x}", List.duplicate(:value, arity))
    guaranteed = x in BindingEscapeEmit.expression_bindings(resolved)
    possible = x in Bindings.matched_names(resolved)
    exact? = not (Gen.inexact?(statement) or Bindings.unknown_routing?(resolved))

    cond do
      exact? and truth != guaranteed ->
        {:guaranteed, k, x, elixir: truth, model: guaranteed}

      guaranteed and not truth ->
        {:guaranteed_overclaimed, k, x}

      truth and not (guaranteed or possible) ->
        {:binding_missed_as_possible, k, x}

      true ->
        nil
    end
  end

  # --- bound at a node: readable per Elixir -------------------------------------------------

  defp readable_checks(nodes, statements) do
    for node <- nodes,
        {bound, conflicts, uncertain, _later} = Meta.bindings(node),
        x <- bound |> MapSet.difference(conflicts) |> MapSet.difference(uncertain),
        disagreement <- [readable_check(node, x, statements)],
        disagreement != nil,
        do: disagreement
  end

  defp readable_check(node, x, statements) do
    case substitute(statements, identity(node), &{:__block__, [], [{x, [], nil}, &1]}) do
      {substituted, 1} ->
        source = Gen.preamble() <> "fn a, b ->\n" <> render(substituted) <> "\nend"

        case eval(source) do
          :ok ->
            nil

          {:error, message} ->
            if message =~ ~s(undefined variable "#{x}"),
              do: {:unreadable, x, Macro.to_string(node)},
              else: {:readable_probe_artifact, x, Macro.to_string(node), message}
        end

      {_, count} ->
        {:ambiguous_node, count, Macro.to_string(node)}
    end
  end

  defp eval(source) do
    {result, _diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.eval_string(source)
          :ok
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    result
  end

  # --- read after a node: unused per Elixir -------------------------------------------------

  # One probe per stamped node and name the stamp says nothing reads after it: the node
  # bound to the name, so that Elixir reports the binding unused.
  defp later_probes(nodes, statements) do
    for {node, i} <- Enum.with_index(nodes),
        {_bound, _conflicts, _uncertain, later} = Meta.bindings(node),
        later != :all,
        x <- Gen.names(),
        not MapSet.member?(later, x),
        {substituted, 1} <- [
          substitute(statements, identity(node), &{:=, [], [{x, [], nil}, &1]})
        ],
        do: {"later_#{i}_#{x}", node, x, Gen.render_body(substituted)}
  end

  defp later_checks(probes, lines, diagnostics) do
    for {name, node, x, _} <- probes,
        {first, last} = Map.fetch!(lines, name),
        not unused_warning?(diagnostics, x, first, last),
        do: {:read_after, x, Macro.to_string(node)}
  end

  defp unused_warning?(diagnostics, x, first, last) do
    Enum.any?(diagnostics, fn diagnostic ->
      line =
        case diagnostic.position do
          {line, _column} -> line
          line when is_integer(line) -> line
        end

      diagnostic.severity == :warning and line in first..last and
        diagnostic.message =~ ~s(variable "#{x}" is unused)
    end)
  end

  # --- module rendering ----------------------------------------------------------------------

  defp def_run(statements), do: {"run", ["a", "b"], Gen.render_body(statements)}

  defp module_source(name, defs), do: elem(module_source_with_lines(name, defs), 0)

  defp module_source_with_lines(name, defs) do
    head = ["defmodule #{name} do"] ++ String.split(String.trim_trailing(Gen.preamble()), "\n")

    {lines, index, _} =
      Enum.reduce(defs, {head, %{}, length(head)}, fn {def_name, params, body},
                                                      {acc, index, count} ->
        body_lines = String.split(body, "\n")
        def_lines = ["def #{def_name}(#{Enum.join(params, ", ")}) do"] ++ body_lines ++ ["end"]
        first = count + 1
        last = count + length(def_lines)
        {acc ++ def_lines, Map.put(index, def_name, {first, last}), last}
      end)

    {Enum.join(lines ++ ["end"], "\n") <> "\n", index}
  end

  # --- AST plumbing ----------------------------------------------------------------------------

  defp body_statements(module_ast) do
    {_, body} =
      Macro.prewalk(module_ast, nil, fn
        {:def, _, [{:run, _, _}, [{{:__block__, _, [:do]}, body}]]} = node, _ -> {node, body}
        {:def, _, [{:run, _, _}, [{:do, body}]]} = node, _ -> {node, body}
        node, acc -> {node, acc}
      end)

    case body do
      {:__block__, _, statements} when length(statements) >= 2 -> statements
      single -> [single]
    end
  end

  defp stamped(tree) do
    {_, acc} =
      Macro.prewalk(tree, [], fn
        {_form, meta, args} = node, acc when is_list(meta) and is_list(args) ->
          if Keyword.has_key?(meta, MetaKeys.bindings_key()),
            do: {node, [node | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # A node is identified by the id `Resolve` stamped on it, so substitution happens in the
  # resolved tree itself and the result is rendered from there: its only rewrite of these
  # programs is alias expansion, which compiles as the source did.
  defp identity(node), do: Resolve.nid(node)

  defp substitute(statements, id, replace) do
    Macro.postwalk(statements, 0, fn
      {_form, meta, args} = node, count when is_list(meta) and is_list(args) ->
        if identity(node) == id, do: {replace.(node), count + 1}, else: {node, count}

      node, count ->
        {node, count}
    end)
  end

  # Rendering a resolved tree: the stamps are meta, which `Macro.to_string/1` ignores.
  defp render(statements), do: Gen.render_body(statements)
end
