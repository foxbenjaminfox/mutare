# Generate first, then time compilation in separate VMs. See bench/README.md for
# cold builds, incremental overlays, compiler profiles, and baseline smoke checks.

defmodule Mutare.CompileShapes do
  @structures [:definitions, :case, :fn, :receive, :try, :clauses]
  @exceptions ~w(ArgumentError RuntimeError ArithmeticError KeyError MatchError CaseClauseError FunctionClauseError Protocol.UndefinedError)

  def run(output, prefixes) do
    fixtures = Enum.filter(fixtures(), &selected?(&1.name, prefixes))
    if fixtures == [], do: raise("no fixtures match #{inspect(prefixes)}")
    File.mkdir_p!(output)
    rows = Enum.map(fixtures, &generate(output, &1))

    # Keep the original six columns first; append diagnostics and construct counts.
    columns = [:shape, :sites, :source_bytes, :generated_bytes, :source_nodes, :generated_nodes]
    extra = for kind <- @structures, side <- [:source, :generated], do: :"#{side}_#{kind}"
    write_table(output, "sizes.tsv", columns ++ [:ignored] ++ extra, Enum.map(rows, & &1.total))
    file_columns = [:shape, :file, :sites, :ignored, :source_sha256, :generated_sha256]

    file_metrics =
      for metric <- [:bytes, :nodes] ++ @structures,
          side <- [:source, :generated],
          do: :"#{side}_#{metric}"

    write_table(
      output,
      "files.tsv",
      file_columns ++ file_metrics,
      Enum.flat_map(rows, & &1.files)
    )

    write_table(output, "projects.tsv", [:shape, :mutators], Enum.map(rows, & &1.config))

    write_file(
      output,
      "environment.exs",
      inspect(
        %{
          elixir: System.version(),
          otp: List.to_string(:erlang.system_info(:otp_release)),
          erts: List.to_string(:erlang.system_info(:version)),
          schedulers: :erlang.system_info(:schedulers_online)
        },
        pretty: true
      ) <> "\n"
    )

    IO.puts("Generated #{length(rows)} projects; #{Path.join(output, "sizes.tsv")}")
  end

  defp selected?(_name, []), do: true
  defp selected?(name, prefixes), do: Enum.any?(prefixes, &String.starts_with?(name, &1))

  defp fixtures do
    ordinary =
      for {shape, sizes, mutators} <- [
            {:case, [25, 50, 100], [:integer, :relational]},
            {:case_default, [25, 50, 100], :default},
            {:guards, [8, 16, 32], [:integer, :relational]},
            {:guards_default, [8, 16, 32], :default},
            {:arithmetic, [40, 80, 160], [:arithmetic]},
            {:arithmetic_default, [40, 80, 160], :default},
            {:arithmetic_variables, [40, 80, 160], :default},
            {:fn, [10, 20, 40], [:integer, :relational]},
            {:fn_default, [10, 20, 40], :default},
            {:receive, [10, 20, 40], [:integer, :relational]},
            {:receive_default, [10, 20, 40], :default}
          ],
          size <- sizes do
        {source, check} = source(shape, size)
        fixture("#{shape}-#{size}", source, mutators, check)
      end

    # Cross two independent dimensions: mutations in a head/handler and the size
    # of the unchanged body each such mutation currently duplicates.
    bodies =
      for {shape, isolated} <- [
            {:head_body, [:integer]},
            {:guard_body, [:relational]},
            {:rescue_types, [:rescue_type]},
            {:rescue_clauses, [:rescue_type]}
          ],
          mode <- [:isolated, :default],
          count <- [2, 4, 8],
          size <- [10, 40, 160] do
        {source, check} = body_source(shape, count, size)
        mutators = if mode == :default, do: :default, else: isolated
        fixture("#{shape}-#{mode}-#{count}x#{size}", source, mutators, check)
      end

    ignored =
      for mode <- [:arithmetic, :default], percent <- [0, 50, 100] do
        source =
          functions(1000, fn i ->
            if rem(i - 1, 100) < percent, do: "# mutare:ignore\n", else: ""
          end)

        mutators = if mode == :default, do: :default, else: [:arithmetic]
        fixture("ignored-#{mode}-#{percent}", source, mutators, "CompileShape.run2(3) == 5")
      end

    ignored =
      ignored ++
        [
          fixture(
            "ignored-file",
            "# mutare:ignore-file\n" <> functions(1000),
            :default,
            "CompileShape.run2(3) == 5"
          ),
          fixture(
            "ignored-variant",
            functions(1000, fn _ -> "# mutare:ignore[arithmetic:-]\n" end),
            :default,
            "CompileShape.run2(3) == 5"
          )
        ]

    focused =
      for cap <- [nil, 10, 1] do
        fixture(
          "focused-#{cap || "all"}",
          functions(100),
          [:arithmetic],
          "CompileShape.run2(3) == 5"
        )
        |> Map.put(:options, max_mutants: cap)
      end

    retained =
      for mode <- [:arithmetic, :default], version <- [:before, :after] do
        expression = if version == :before, do: "x + 2", else: "x + 2 + 3"
        a = "defmodule CompileShapeA do\ndef run(x), do: #{expression}\nend\n"
        b = functions(100) |> String.replace("defmodule CompileShape", "defmodule CompileShapeB")
        mutators = if mode == :default, do: :default, else: [:arithmetic]

        %{
          name: "retained-#{mode}-#{version}",
          sources: %{"lib/a.ex" => a, "lib/b.ex" => b},
          mutators: mutators,
          options: [],
          check:
            "CompileShapeA.run(3) == #{if version == :before, do: 5, else: 8} and CompileShapeB.run2(3) == 5"
        }
      end

    ordinary ++ bodies ++ ignored ++ focused ++ retained
  end

  defp fixture(name, source, mutators, check),
    do: %{
      name: name,
      sources: %{"lib/shape.ex" => source},
      mutators: mutators,
      options: [],
      check: check
    }

  defp generate(output, fixture) do
    IO.puts("Generating #{fixture.name}")
    root = Path.join(output, fixture.name)
    original_root = Path.join(root, "originals")
    for {rel, source} <- fixture.sources, do: write_file(original_root, rel, source)
    mutators = if fixture.mutators == :default, do: Mutare.Mutators.all(), else: fixture.mutators

    {metamutants, sites} =
      case {Map.to_list(fixture.sources), fixture.options} do
        {[{rel, source}], []} ->
          {meta, sites, _} =
            Mutare.Transform.transform_string_with_sites(source,
              file: rel,
              mutators: mutators,
              render_site_code: false,
              summarize_sites: false
            )

          {%{rel => meta}, sites}

        _ ->
          context =
            Mutare.Run.Context.new([mutators: mutators, defer_site_code: true] ++ fixture.options)

          # Explicit inputs prevent leftovers from changing the candidate order.
          files =
            fixture.sources
            |> Map.keys()
            |> Enum.sort()
            |> Enum.map(&Path.join(original_root, &1))

          schema = Mutare.Schema.from_files(files, original_root, context)
          if schema.skipped != [], do: raise("skipped fixture files: #{inspect(schema.skipped)}")
          {Map.merge(fixture.sources, schema.metamutants), schema.sites}
      end

    for {rel, meta} <- metamutants, do: write_file(root, rel, meta)

    write_file(root, "mix.exs", """
    defmodule CompileShape.MixProject do
      use Mix.Project
      def project do
        [app: :compile_shape, version: "0.1.0", elixirc_options: [infer_signatures: false]]
      end
    end
    """)

    write_file(root, "smoke.exs", """
    # Baseline only. Run after compilation with: mix run --no-compile smoke.exs
    unless #{String.trim(fixture.check)}, do: raise("baseline fixture failed")
    """)

    files =
      for {rel, source} <- Enum.sort(fixture.sources) do
        meta = Map.fetch!(metamutants, rel)
        file_sites = Enum.filter(sites, &(&1.file == rel))

        %{
          shape: fixture.name,
          file: rel,
          sites: length(file_sites),
          ignored: Enum.count(file_sites, & &1.ignored),
          source_sha256: hash(source),
          generated_sha256: hash(meta)
        }
        |> Map.merge(metrics(source, :source))
        |> Map.merge(metrics(meta, :generated))
      end

    total =
      Enum.reduce(files, %{shape: fixture.name}, fn file, acc ->
        Enum.reduce(file, acc, fn
          {key, value}, acc when is_integer(value) -> Map.update(acc, key, value, &(&1 + value))
          _, acc -> acc
        end)
      end)

    %{
      total: total,
      files: files,
      config: %{shape: fixture.name, mutators: Enum.join(mutators, ",")}
    }
  end

  defp metrics(source, side) do
    initial = Map.new([:nodes | @structures], &{&1, 0})

    {_, counts} =
      Macro.prewalk(Code.string_to_quoted!(source), initial, fn node, counts ->
        kind =
          case node do
            {form, _, _} when form in [:def, :defp, :defmacro, :defmacrop] -> :definitions
            {form, _, _} when form in [:case, :fn, :receive, :try] -> form
            {:->, _, _} -> :clauses
            _ -> nil
          end

        counts = Map.update!(counts, :nodes, &(&1 + 1))
        {node, if(kind, do: Map.update!(counts, kind, &(&1 + 1)), else: counts)}
      end)

    counts |> Map.put(:bytes, byte_size(source)) |> Map.new(fn {k, v} -> {:"#{side}_#{k}", v} end)
  end

  defp hash(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  defp write_file(root, rel, source) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    # Preserve mtimes when regeneration produces identical bytes.
    if File.read(path) != {:ok, source}, do: File.write!(path, source)
  end

  defp write_table(root, name, columns, rows) do
    lines = [
      Enum.join(columns, "\t")
      | Enum.map(rows, fn row ->
          Enum.map_join(columns, "\t", &to_string(Map.fetch!(row, &1)))
        end)
    ]

    write_file(root, name, Enum.join(lines, "\n") <> "\n")
  end

  defp source(shape, size)
       when shape in [
              :case_default,
              :guards_default,
              :arithmetic_default,
              :fn_default,
              :receive_default
            ] do
    base = %{
      case_default: :case,
      guards_default: :guards,
      arithmetic_default: :arithmetic,
      fn_default: :fn,
      receive_default: :receive
    }

    source(Map.fetch!(base, shape), size)
  end

  defp source(:case, size) do
    clauses = for i <- 1..size, do: "{#{i}, n} when n >= #{i} -> n"

    {"defmodule CompileShape do\ndef run(x) do\ncase x do\n#{Enum.join(clauses, "\n")}\nend\nend\nend\n",
     "CompileShape.run({1, 3}) == 3"}
  end

  defp source(:guards, size) do
    guard = Enum.map_join(1..size, " and ", &"x >= #{&1}")

    {"defmodule CompileShape do\ndef run(x) when #{guard} when is_float(x), do: x\ndef run(_), do: :missing\nend\n",
     "CompileShape.run(#{size}) == #{size} and CompileShape.run(0) == :missing"}
  end

  defp source(:arithmetic, size) do
    expr = Enum.reduce(1..size, "x", fn _, acc -> "(#{acc} + 2)" end)

    {"defmodule CompileShape do\ndef run(x), do: #{expr}\nend\n",
     "CompileShape.run(3) == #{3 + size * 2}"}
  end

  defp source(:arithmetic_variables, size) do
    expr = Enum.reduce(1..size, "x", fn _, acc -> "(#{acc} + y)" end)

    {"defmodule CompileShape do\ndef run(x, y), do: #{expr}\nend\n",
     "CompileShape.run(3, 2) == #{3 + size * 2}"}
  end

  defp source(:fn, size) do
    clauses = Enum.map_join(1..size, "\n", &"#{&1}, n when n >= #{&1} -> n + offset")

    {"defmodule CompileShape do\ndef run(offset), do: fn\n#{clauses}\nend\nend\n",
     "CompileShape.run(2).(1, 3) == 5 and CompileShape.run(2).(#{size}, #{size}) == #{size + 2}"}
  end

  defp source(:receive, size) do
    clauses = Enum.map_join(1..size, "\n", &"{#{&1}, n} when n >= #{&1} -> n + 2")

    {"defmodule CompileShape do\ndef run() do\nreceive do\n#{clauses}\nafter\n0 -> :timeout\nend\nend\nend\n",
     "(send(self(), :unmatched); send(self(), {#{size}, #{size}}); send(self(), {1, 3}); CompileShape.run() == #{size + 2} and CompileShape.run() == 5 and CompileShape.run() == :timeout)"}
  end

  defp body_source(shape, count, size) when shape in [:head_body, :guard_body] do
    {head, guard, args} =
      case shape do
        :head_body ->
          pattern = "{" <> Enum.join(1..count, ", ") <> "}"
          {"#{pattern}, x", "is_integer(x)", "#{pattern}, 20"}

        :guard_body ->
          {"x", Enum.map_join(1..count, " and ", &"x >= #{&1}"), "20"}
      end

    {"defmodule CompileShape do\ndef run(#{head}) when #{guard} do\n#{body(size)}\nend\nend\n",
     "CompileShape.run(#{args}) == #{20 + size * 2}"}
  end

  defp body_source(shape, count, size) when shape in [:rescue_types, :rescue_clauses] do
    types = Enum.take(@exceptions, count)
    handler = "send(self(), {:compile_shape_rescue, e.__struct__}); {:rescued, e.__struct__}"

    rescue_clauses =
      case shape do
        :rescue_types -> "e in [#{Enum.join(types, ", ")}] -> #{handler}"
        :rescue_clauses -> Enum.map_join(types, "\n", &"e in #{&1} -> #{handler}")
      end

    {"""
     defmodule CompileShape do
       def run(x, failure) do
         try do
           send(self(), :compile_shape_do)
           if failure, do: raise(failure)
           #{body(size)}
         rescue
           #{rescue_clauses}
         after
           send(self(), :compile_shape_after)
         end
       end
     end
     """, rescue_check(types, size)}
  end

  defp rescue_check(types, size) do
    """
    (
      collect = fn collect, events ->
        receive do
          event -> collect.(collect, [event | events])
        after
          0 -> Enum.reverse(events)
        end
      end

      cases = [
        {nil, {:returned, #{20 + size * 2}}, [:compile_shape_do, :compile_shape_after]},
        {ErlangError, {:raised, ErlangError}, [:compile_shape_do, :compile_shape_after]}
        | for type <- [#{Enum.join(types, ", ")}] do
            {type, {:returned, {:rescued, type}},
             [:compile_shape_do, {:compile_shape_rescue, type}, :compile_shape_after]}
          end
      ]

      Enum.each(cases, fn {failure, expected, expected_events} ->
        result =
          try do
            {:returned, CompileShape.run(20, failure)}
          rescue
            e -> {:raised, e.__struct__}
          end

        events = collect.(collect, [])
        unless {result, events} == {expected, expected_events} do
          raise "rescue fixture failed for \#{inspect(failure)}: \#{inspect({result, events})}"
        end
      end)
      true
    )
    """
  end

  defp body(size), do: Enum.join(List.duplicate("x = x + 2", size) ++ ["x"], "\n")

  defp functions(size, prefix \\ fn _ -> "" end) do
    functions = for i <- 1..size, do: prefix.(i) <> "def run#{i}(x), do: x + 2"
    "defmodule CompileShape do\n#{Enum.join(functions, "\n")}\nend\n"
  end
end

case System.argv() do
  [output | prefixes] -> Mutare.CompileShapes.run(Path.expand(output), prefixes)
  _ -> raise "usage: mix run bench/compile_shapes.exs OUTPUT_DIRECTORY [NAME_PREFIX ...]"
end
