# Generate once, then profile compilation separately from discovery/rendering:
#
#   mix run bench/compile_shapes.exs /tmp/mutare-shapes
#   cd /tmp/mutare-shapes/arithmetic-160
#   MIX_ENV=test ERL_COMPILER_OPTIONS='[no_ssa_opt_alias,time]' \
#     /usr/bin/time -v mix compile --force --no-verification --profile time
#
# The tiny generated projects have no dependencies. Their project options disable
# inference explicitly, including on Elixir 1.20. To compare revisions, run this
# same generator in each checkout and compile with the same Elixir/OTP and flags.
# Add `time` to inherited ERL_COMPILER_OPTIONS rather than replacing other options.
# `module_definition: :interpreted` can be added to a generated project's options
# on Elixir >= 1.20 for a separate experiment; it is not Mutare's default.

defmodule Mutare.CompileShapes do
  def run(output) do
    File.mkdir_p!(output)

    rows =
      for {shape, sizes} <- [
            case: [25, 50, 100],
            guards: [8, 16, 32],
            arithmetic: [40, 80, 160],
            arithmetic_default: [40, 80, 160],
            arithmetic_variables: [40, 80, 160]
          ],
          size <- sizes do
        source = source(shape, size)

        mutators =
          case shape do
            :arithmetic -> [:arithmetic]
            :arithmetic_default -> Mutare.Mutators.all()
            :arithmetic_variables -> Mutare.Mutators.all()
            _ -> [:integer, :relational]
          end

        {metamutant, sites, _} =
          Mutare.Transform.transform_string_with_sites(source, mutators: mutators)

        write_project(output, "#{shape}-#{size}", source, metamutant, length(sites))
      end

    source = source(:functions, 100)
    original = Path.join(output, "focused-source/lib")
    File.mkdir_p!(original)
    File.write!(Path.join(original, "shape.ex"), source)

    focused_rows =
      for cap <- [nil, 10, 1] do
        schema =
          Mutare.Schema.build(Path.dirname(original), mutators: [:arithmetic], max_mutants: cap)

        write_project(
          output,
          "focused-#{cap || "all"}",
          source,
          schema.metamutants["lib/shape.ex"],
          length(schema.sites)
        )
      end

    header = "shape\tsites\tsource_bytes\tgenerated_bytes\tsource_nodes\tgenerated_nodes\n"

    File.write!(
      Path.join(output, "sizes.tsv"),
      header <> Enum.join(rows ++ focused_rows, "\n") <> "\n"
    )

    IO.puts(Path.join(output, "sizes.tsv"))
  end

  defp write_project(output, name, source, metamutant, count) do
    root = Path.join(output, name)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/shape.ex"), metamutant)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule CompileShape.MixProject do
      use Mix.Project
      def project do
        [app: :compile_shape, version: "0.1.0", elixirc_options: [infer_signatures: false]]
      end
    end
    """)

    Enum.join(
      [name, count, byte_size(source), byte_size(metamutant), nodes(source), nodes(metamutant)],
      "\t"
    )
  end

  defp nodes(source) do
    {_ast, count} =
      Macro.prewalk(Code.string_to_quoted!(source), 0, fn node, n -> {node, n + 1} end)

    count
  end

  defp source(:case, size) do
    clauses = for i <- 1..size, do: "{#{i}, n} when n >= #{i} -> n"

    "defmodule CompileShape do\ndef run(x) do\ncase x do\n#{Enum.join(clauses, "\n")}\nend\nend\nend\n"
  end

  defp source(:guards, size) do
    guards = for i <- 1..size, do: "x >= #{i}"
    guard = Enum.join(guards, " and ")

    "defmodule CompileShape do\ndef run(x) when #{guard} when is_float(x), do: x\ndef run(_), do: :missing\nend\n"
  end

  defp source(:arithmetic, size) do
    expr = Enum.reduce(1..size, "x", fn _, acc -> "(#{acc} + 2)" end)
    "defmodule CompileShape do\ndef run(x), do: #{expr}\nend\n"
  end

  defp source(:arithmetic_default, size), do: source(:arithmetic, size)

  defp source(:arithmetic_variables, size) do
    expr = Enum.reduce(1..size, "x", fn _, acc -> "(#{acc} + y)" end)
    "defmodule CompileShape do\ndef run(x, y), do: #{expr}\nend\n"
  end

  defp source(:functions, size) do
    functions = for i <- 1..size, do: "def run#{i}(x), do: x + 2"
    "defmodule CompileShape do\n#{Enum.join(functions, "\n")}\nend\n"
  end
end

case System.argv() do
  [output] -> Mutare.CompileShapes.run(Path.expand(output))
  _ -> raise "usage: mix run bench/compile_shapes.exs OUTPUT_DIRECTORY"
end
