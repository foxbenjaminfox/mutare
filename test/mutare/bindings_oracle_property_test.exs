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
          Enum.map(later_probes, fn probe -> {probe.name, ["a", "b"], probe.body} end)

      {source, lines} = module_source_with_lines(inspect(module), defs)

      case Compile.string_result(source, "oracle.ex") do
        {{:ok, _}, diagnostics} ->
          try do
            run_check(module) ++
              guaranteed_checks(module, statements, resolved_statements) ++
              readable_checks(nodes, resolved_statements) ++
              later_checks(later_probes, lines, diagnostics)
          after
            :code.delete(module)
            :code.purge(module)
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
        probe <- [later_probe(statements, node, x, "later_#{i}_#{x}")],
        probe != nil,
        do: probe
  end

  @placeholder {:__mutare_probe__, [], nil}

  # The probe's binding is the one the warning must be about, and the compiler names a
  # binding by its line — so the variable gets a line no other binding of the name shares.
  # The program's other bindings of it (a parameter, an earlier match, the node's own) are
  # elsewhere, and a warning about one of them is not evidence. The node is rendered in
  # place of a placeholder and spliced back parenthesized, on lines of its own:
  #
  #     …(a = 1,
  #     a =
  #     (
  #     <node>
  #     ))…
  #
  # The line break ahead of the variable is legal after a bracket, a comma or an operator,
  # and it is only after those that a binding can precede on the line; a bare call head
  # (`if`, `Kernel.if`, `case` — rendered without parentheses) takes no break and binds
  # nothing. `nil` where the node is not found exactly once.
  defp later_probe(statements, node, x, name) do
    case substitute(statements, identity(node), fn _ -> @placeholder end) do
      {with_placeholder, 1} ->
        [before, rest] =
          String.split(Gen.render_body(with_placeholder), Macro.to_string(@placeholder), parts: 2)

        break = if before =~ ~r/[\w?!]\s*$/, do: "", else: "\n"
        body = before <> break <> "#{x} =\n(\n" <> Macro.to_string(node) <> "\n)" <> rest
        # The body's first line is offset 0; the binding is on the last line of `before`, or
        # the one after it.
        offset = newlines(before) + newlines(break)
        %{name: name, node: node, x: x, body: body, binding_offset: offset}

      _ ->
        nil
    end
  end

  defp newlines(text), do: text |> String.graphemes() |> Enum.count(&(&1 == "\n"))

  defp later_checks(probes, lines, diagnostics) do
    for probe <- probes,
        %{body: body_line} = Map.fetch!(lines, probe.name),
        not unused_warning?(diagnostics, probe.x, body_line + probe.binding_offset),
        do: {:read_after, probe.x, Macro.to_string(probe.node)}
  end

  defp unused_warning?(diagnostics, x, line) do
    Enum.any?(diagnostics, fn diagnostic ->
      diagnostic.severity == :warning and diagnostic_line(diagnostic) == line and
        diagnostic.message =~ ~s(variable "#{x}" is unused)
    end)
  end

  defp diagnostic_line(%{position: {line, _column}}), do: line
  defp diagnostic_line(%{position: line}) when is_integer(line), do: line

  # --- the oracle's own false-negative path -----------------------------------------------

  # A claim that nothing reads `a` after `a = 1` is wrong: `q = a` reads it. The probe
  # `a = (a = 1)` leaves two *other* bindings of `a` unused — the parameter, and the node's
  # own, shadowed at once — and the compiler warns about both. Neither is the probe's
  # binding, whose read the check must miss to report the claim; a check that took any
  # warning about `a` in the function would be satisfied and stay silent.
  test "a wrong `later` claim is reported even where the name has other unused bindings" do
    statements = [quote(do: a = 1), quote(do: q = a)]
    model_source = module_source("Mutare.Test.BindingOracleControlModel", [def_run(statements)])

    [node | _] =
      resolved =
      model_source
      |> Sourceror.parse_string!()
      |> Resolve.annotate(registry(), warnings: false)
      |> Bindings.annotate()
      |> body_statements()

    {_bound, _conflicts, _uncertain, later} = Meta.bindings(node)
    assert MapSet.member?(later, :a), "the stamp itself reads `a` after the node"

    probe = later_probe(resolved, node, :a, "later_0_a")
    module = :"Elixir.Mutare.Test.BindingOracleControl#{System.unique_integer([:positive])}"

    {source, lines} =
      module_source_with_lines(inspect(module), [{probe.name, ["a", "b"], probe.body}])

    assert {{:ok, _}, diagnostics} = Compile.string_result(source, "oracle_control.ex")
    :code.delete(module)
    :code.purge(module)

    unused_a =
      for d <- diagnostics, d.message =~ ~s(variable "a" is unused), do: diagnostic_line(d)

    assert length(unused_a) == 2, "the control keeps two other unused bindings of `a`"
    assert later_checks([probe], lines, diagnostics) == [{:read_after, :a, "a = 1"}]
  end

  # --- module rendering ----------------------------------------------------------------------

  defp def_run(statements), do: {"run", ["a", "b"], Gen.render_body(statements)}

  defp module_source(name, defs), do: elem(module_source_with_lines(name, defs), 0)

  defp module_source_with_lines(name, defs) do
    head = ["defmodule #{name} do"] ++ String.split(String.trim_trailing(Gen.preamble()), "\n")

    # `index` gives each def the line its body starts on.
    {lines, index, _} =
      Enum.reduce(defs, {head, %{}, length(head)}, fn {def_name, params, body},
                                                      {acc, index, count} ->
        body_lines = String.split(body, "\n")
        def_lines = ["def #{def_name}(#{Enum.join(params, ", ")}) do"] ++ body_lines ++ ["end"]
        last = count + length(def_lines)
        {acc ++ def_lines, Map.put(index, def_name, %{body: count + 2}), last}
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
