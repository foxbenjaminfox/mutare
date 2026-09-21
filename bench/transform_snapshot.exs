# Differential check for a transform refactor: what the transform writes for a fixed corpus.
# Driven by `bench/transform_diff.sh`; see bench/README.md "Transform differential".
#
#   MIX_ENV=test mix run bench/transform_snapshot.exs corpus CORPUS_FILE
#   MIX_ENV=test mix run bench/transform_snapshot.exs snapshot CORPUS_FILE OUT_DIR
#
# `corpus` is written once, by the revision under test, so both revisions transform the same
# sources under the same options. `snapshot` must therefore run on a revision that lacks the
# generators, and reads nothing but the corpus file and `Mutare.transform_string/2`.

defmodule TransformSnapshot do
  alias Mutare.Test.{CleanSourcePatchGenerators, SourcePatchGenerators}

  def corpus(file) do
    items = project_sources() ++ patch_fixtures() ++ clean_fixtures()
    File.write!(file, :erlang.term_to_binary(items))
    IO.puts("#{length(items)} corpus items -> #{file}")
  end

  def snapshot(corpus_file, out) do
    File.mkdir_p!(out)
    items = corpus_file |> File.read!() |> :erlang.binary_to_term()

    items
    |> Task.async_stream(&write(&1, out), timeout: :infinity, ordered: false)
    |> Stream.run()

    IO.puts("#{length(items)} snapshots -> #{out}")
  end

  defp project_sources do
    for path <- Path.wildcard("lib/**/*.ex") ++ Path.wildcard("examples/*/lib/**/*.ex") do
      {"src-" <> String.replace(path, "/", "__"), File.read!(path), []}
    end
  end

  defp patch_fixtures do
    g = SourcePatchGenerators

    for operand <- g.operands(),
        spelling <- g.spellings(),
        delivery <- g.deliveries(),
        callee <- g.callees(),
        wrapped? <- [false, true] do
      recipe = %{
        operand: operand,
        spelling: spelling,
        delivery: delivery,
        callee: callee,
        wrapped?: wrapped?,
        offset: 0
      }

      fixture("patch-#{operand}-#{spelling}-#{delivery}-#{callee}-#{wrapped?}", g.fixture(recipe))
    end
  end

  defp clean_fixtures do
    g = CleanSourcePatchGenerators

    for boundary <- g.boundaries(), routing <- g.routings(), spelling <- g.spellings() do
      recipe = %{boundary: boundary, routing: routing, spelling: spelling, values: [], initial: 0}
      fixture("clean-#{boundary}-#{routing}-#{spelling}", g.fixture(recipe))
    end
  end

  defp fixture(name, %{source: source, mutators: mutators, opts: opts}),
    do: {name, source, Keyword.put(opts, :mutators, mutators)}

  # A raise is recorded, not propagated: a base revision may lack a module the corpus names,
  # and a refactor that starts or stops raising is a difference worth seeing in the diff.
  defp write({name, source, opts}, out) do
    body =
      try do
        result = Mutare.transform_string(source, opts)

        sites =
          Enum.map_join(result.mutants, "\n", fn site ->
            site |> canonical() |> inspect(limit: :infinity, printable_limit: :infinity)
          end)

        result.metamutant <> "\n\n# ---- sites ----\n" <> sites <> "\n"
      rescue
        exception -> "# ---- raised ----\n" <> Exception.message(exception) <> "\n"
      end

    File.write!(Path.join(out, name <> ".txt"), body)
  end

  # A small map iterates its atom keys in the order this VM created them (OTP 26+), so an
  # inspected map differs between two runs that agree. Sorted pairs do not.
  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(%{} = map),
    do: map |> Enum.map(fn {k, v} -> {k, canonical(v)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other
end

case System.argv() do
  ["corpus", file] -> TransformSnapshot.corpus(file)
  ["snapshot", corpus, out] -> TransformSnapshot.snapshot(corpus, out)
  _ -> raise "usage: transform_snapshot.exs corpus FILE | snapshot FILE OUT_DIR"
end
