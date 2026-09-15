# Run with `mix run bench/dispatch_shapes.exs /tmp/mutare-dispatch`.
# This compares compiler output, not elapsed execution time. It preserves source-clause
# order and changes only generated activation gates in these deliberately simple fixtures.
defmodule Mutare.Bench.DispatchShapes do
  alias Mutare.AST

  def inspect_fixture(name, source, mutators, output_root) do
    result =
      Mutare.Transform.transform_string_with_sites(source,
        mutators: mutators,
        warnings: false,
        clean_functions: false
      )

    ast = Code.string_to_quoted!(result.metamutant)
    {changed, count} = Macro.prewalk(ast, 0, &literal_gate(&1, &2, result.dispatch_var))
    if count == 0 and name != "pipes", do: raise("fixture #{name} rewrote no gates")
    output = Path.join(output_root, name)
    File.mkdir_p!(output)
    File.write!(Path.join(output, "original.ex"), source)
    File.write!(Path.join(output, "current.ex"), result.metamutant)
    File.write!(Path.join(output, "literal.ex"), Macro.to_string(changed))

    beams =
      for {label, variant} <- [{"current", ast}, {"literal", changed}], into: %{} do
        [{module, beam}] = Code.compile_quoted(variant)
        :code.purge(module)
        :code.delete(module)
        disasm = :beam_disasm.file(beam)
        File.write!(Path.join(output, label <> ".beam"), beam)

        File.write!(
          Path.join(output, label <> ".disasm"),
          inspect(disasm, limit: :infinity, pretty: true, width: 120)
        )

        {:beam_file, _, _, _, _, functions} = disasm

        normalized =
          Enum.map(functions, fn {:function, name, arity, label, instructions} ->
            {:function, name, arity, label, Enum.reject(instructions, &match?({:line, _}, &1))}
          end)

        instructions = Enum.flat_map(normalized, &elem(&1, 4))

        counts =
          Enum.frequencies_by(instructions, fn item ->
            if is_tuple(item), do: elem(item, 0), else: item
          end)

        {label, {normalized, byte_size(beam), counts}}
      end

    {current, current_size, current_counts} = beams["current"]
    {literal, literal_size, literal_counts} = beams["literal"]

    summary = %{
      fixture: name,
      changed_clauses: count,
      same_instructions: current == literal,
      beam_bytes: {current_size, literal_size},
      current_counts: current_counts,
      literal_counts: literal_counts
    }

    File.write!(
      Path.join(output, "summary.exs"),
      inspect(summary, limit: :infinity, pretty: true) <> "\n"
    )

    IO.inspect(summary, limit: :infinity)
  end

  defp literal_gate(
         {vis, meta, [{:when, wm, [{name, cm, [active | args]}, guard]} | body]} = node,
         count,
         var
       )
       when vis in [:def, :defp] do
    case {active, split_gate(guard, var)} do
      {{^var, _, context}, {id, rest}} when is_atom(context) ->
        call = {name, cm, [id | args]}
        head = if rest, do: {:when, wm, [call, rest]}, else: call
        {{vis, meta, [head | body]}, count + 1}

      _ ->
        {node, count}
    end
  end

  defp literal_gate(
         {:->, meta, [[{:when, wm, [{active, pattern}, guard]}], body]} = node,
         count,
         var
       ) do
    case {active, split_gate(guard, var)} do
      {{^var, _, context}, {id, rest}} when is_atom(context) ->
        tuple = {id, pattern}
        head = if rest, do: {:when, wm, [tuple, rest]}, else: tuple
        {{:->, meta, [[head], body]}, count + 1}

      _ ->
        {node, count}
    end
  end

  defp literal_gate(node, count, _), do: {node, count}

  defp split_gate(guard, var) do
    case AST.erlang_call_args(guard, :"=:=") do
      {:ok, [{^var, _, _}, id]} when is_integer(id) ->
        {id, nil}

      _ ->
        case AST.erlang_call_args(guard, :andalso) do
          {:ok, [left, right]} ->
            case split_gate(left, var) do
              {id, nil} -> {id, right}
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end
end

output =
  case System.argv() do
    [] -> "/tmp/mutare-dispatch"
    [path] -> Path.expand(path)
    _ -> raise "usage: mix run bench/dispatch_shapes.exs [output_directory]"
  end

File.mkdir_p!(output)
Code.compiler_options(ignore_module_conflict: true)

if Map.has_key?(Code.compiler_options(), :infer_signatures),
  do: Code.compiler_options(infer_signatures: false)

environment = %{
  elixir: System.version(),
  otp: System.otp_release(),
  erts: to_string(:erlang.system_info(:version)),
  schedulers: :erlang.system_info(:schedulers_online),
  erl_compiler_options: System.get_env("ERL_COMPILER_OPTIONS"),
  elixir_compiler_options: Code.compiler_options(),
  clean_functions: false
}

File.write!(Path.join(output, "environment.exs"), inspect(environment, pretty: true) <> "\n")

for clauses <- [4, 25] do
  case_clauses = Enum.map_join(1..clauses, "\n", fn i -> "#{i} -> #{i} * x" end)

  Mutare.Bench.DispatchShapes.inspect_fixture(
    "case-#{clauses}",
    """
    defmodule InspectCase do
      def run(x) do
        case x do
          #{case_clauses}
          _ -> :other
        end
      end
    end
    """,
    [:integer],
    output
  )

  function_clauses = Enum.map_join(1..clauses, "\n", fn i -> "def run(#{i}, x), do: x * #{i}" end)

  Mutare.Bench.DispatchShapes.inspect_fixture(
    "head-#{clauses}",
    """
    defmodule InspectHead do
      #{function_clauses}
      def run(_, x), do: x
    end
    """,
    [:integer],
    output
  )

  function_clauses =
    Enum.map_join(1..clauses, "\n", fn i -> "def run(n, x) when n >= #{i * 10}, do: x * #{i}" end)

  Mutare.Bench.DispatchShapes.inspect_fixture(
    "guard-#{clauses}",
    """
    defmodule InspectGuard do
      #{function_clauses}
      def run(_, x), do: x
    end
    """,
    [:relational],
    output
  )
end

Mutare.Bench.DispatchShapes.inspect_fixture(
  "pipes",
  """
  defmodule InspectPipe do
    def run(xs), do: xs |> Enum.filter(&is_integer/1) |> Enum.take(10) |> Enum.sum()
  end
  """,
  [:collection],
  output
)
