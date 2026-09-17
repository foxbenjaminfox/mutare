# Compare kernel builds sample by sample inside one VM. Run with
# `elixir bench/kernel_ab.exs OUT ROUNDS name=PROJECT_DIR...`, where each PROJECT_DIR is a
# shape `bench/alias_analysis.exs` wrote (`<output>/clean`, `<output>/original`, …), possibly
# by another revision of Mutare. The last build named is the one under test: the ratio
# columns divide its time by each earlier build's. See bench/README.md, "Comparing revisions".

defmodule Mutare.KernelAB do
  @states [:baseline, :elsewhere, :other_file, :inside]

  def run(out, rounds, [{_name, first_dir} | _] = projects) do
    out = Path.expand(out)
    File.rm_rf!(out)
    File.mkdir_p!(Path.join(out, "lib"))

    variants =
      for {name, dir} <- projects do
        dir = Path.expand(dir)
        source = File.read!(Path.join(dir, "lib/kernel.ex"))
        worker = File.read!(Path.join(dir, "worker.exs"))
        module = "AliasBench.Kernel_#{name}"
        key = ":mutare_active_#{name}"

        # Each variant keeps its own selection slot, so none is rewritten between samples
        # (a changed persistent term triggers a global garbage collection).
        source =
          source
          |> String.replace("defmodule AliasBench.Kernel do", "defmodule #{module} do")
          |> String.replace(
            ":persistent_term.get(:mutare_active, 0)",
            ":persistent_term.get(#{key}, 0)"
          )

        File.write!(Path.join(out, "lib/kernel_#{name}.ex"), source)

        %{
          name: name,
          module: module,
          key: key,
          # The stored form of a namespace differs between revisions; read it off the code.
          atom_namespace?: source =~ ~s({:"lib/kernel.ex", mutare_local_id}),
          ids: capture!(worker, ~r/^\s*ids = (%\{.*\})$/m),
          elsewhere: capture!(worker, ~r/:elsewhere -> \{:?"lib\/kernel.ex", (\d+)\}/),
          counts: capture!(worker, ~r/for \{kernel, iterations\} <- (\[.*\]) do/)
        }
      end

    first_dir = Path.expand(first_dir)
    File.cp!(Path.join(first_dir, "mix.exs"), Path.join(out, "mix.exs"))
    File.cp!(Path.join(first_dir, "lib/coverage.ex"), Path.join(out, "lib/coverage.ex"))
    File.write!(Path.join(out, "worker.exs"), worker(variants, rounds))

    env = [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", Path.join(out, "_build")},
      {"ERL_COMPILER_OPTIONS", "[no_ssa_opt_alias]"}
    ]

    {output, status} =
      System.cmd("mix", ["compile", "--force", "--no-verification"],
        cd: out,
        env: env,
        stderr_to_stdout: true
      )

    if status != 0, do: raise("compile failed:\n#{output}")

    {_, 0} =
      System.cmd("elixir", ["-pa", Path.join(out, "_build/lib/alias_bench/ebin"), "worker.exs"],
        cd: out,
        into: IO.stream(:stdio, :line)
      )
  end

  def parse(pairs) do
    for pair <- pairs do
      case String.split(pair, "=", parts: 2) do
        [name, dir] -> {name, dir}
        _other -> raise("expected name=PROJECT_DIR, got #{pair}")
      end
    end
  end

  defp capture!(text, regex) do
    case Regex.run(regex, text) do
      [_all, captured] -> captured
      nil -> raise("worker.exs does not match #{inspect(regex)}")
    end
  end

  defp worker(variants, rounds) do
    descriptors =
      Enum.map_join(variants, ",\n", fn v ->
        namespace = if v.atom_namespace?, do: ~s(:"lib/kernel.ex"), else: ~s("lib/kernel.ex")
        other = if v.atom_namespace?, do: ~s(:"lib/other.ex"), else: ~s("lib/other.ex")

        "  %{name: #{inspect(v.name)}, module: #{v.module}, key: #{v.key}, ids: #{v.ids}, " <>
          "elsewhere: {#{namespace}, #{v.elsewhere}}, namespace: #{namespace}, other: {#{other}, 1}}"
      end)

    """
    variants = [
    #{descriptors}
    ]
    counts = #{hd(variants).counts}
    :persistent_term.put(:mutare_probe, false)
    :persistent_term.put(:mutare_track, false)
    tested = List.last(variants).name
    IO.puts("min ms over #{rounds} alternating samples; ratios are \#{tested} over each earlier build")

    for state <- #{inspect(@states)} do
      IO.puts("\\n== \#{state}")

      IO.puts(
        String.pad_trailing("kernel", 12) <>
          Enum.map_join(variants, "", &String.pad_leading(&1.name, 12)) <>
          Enum.map_join(Enum.drop(variants, -1), "", &String.pad_leading(tested <> "/" <> &1.name, 16))
      )

      for {kernel, iterations} <- counts do
        for v <- variants do
          active =
            case state do
              :baseline -> 0
              :elsewhere -> v.elsewhere
              :other_file -> v.other
              :inside -> {v.namespace, Map.fetch!(v.ids, kernel)}
            end

          :persistent_term.put(v.key, active)
        end

        # Let the collection a changed persistent term schedules finish outside the samples.
        Process.sleep(50)

        # Every state but `inside` must compute what the source does, in every build.
        results = for v <- variants, do: apply(v.module, kernel, [31, 11])

        if state != :inside and length(Enum.uniq(results)) != 1,
          do: raise("builds disagree on \#{kernel} at \#{state}: \#{inspect(results)}")

        for v <- variants, do: apply(v.module, kernel, [100, 11])

        samples =
          for round <- 1..#{rounds},
              v <- if(rem(round, 2) == 1, do: variants, else: Enum.reverse(variants)) do
            parent = self()

            {pid, ref} =
              spawn_monitor(fn ->
                :erlang.garbage_collect()
                {us, value} = :timer.tc(fn -> apply(v.module, kernel, [iterations, 11]) end)
                send(parent, {:sample, us, :erlang.phash2(value)})
              end)

            receive do
              {:sample, us, _checksum} ->
                receive do
                  {:DOWN, ^ref, :process, ^pid, :normal} -> {v.name, us}
                end

              {:DOWN, ^ref, :process, ^pid, reason} ->
                raise("sample failed: " <> inspect(reason))
            end
          end

        best = Map.new(variants, fn v -> {v.name, (for {name, us} <- samples, name == v.name, do: us) |> Enum.min()} end)

        IO.puts(
          String.pad_trailing(to_string(kernel), 12) <>
            Enum.map_join(variants, "", &String.pad_leading(:erlang.float_to_binary(best[&1.name] / 1000, decimals: 3), 12)) <>
            Enum.map_join(Enum.drop(variants, -1), "", fn v ->
              String.pad_leading(:erlang.float_to_binary(best[tested] / best[v.name], decimals: 2) <> "x", 16)
            end)
        )
      end
    end
    """
  end
end

case System.argv() do
  [out, rounds | [_ | _] = pairs] ->
    Mutare.KernelAB.run(out, String.to_integer(rounds), Mutare.KernelAB.parse(pairs))

  _ ->
    raise("usage: elixir bench/kernel_ab.exs OUT ROUNDS name=PROJECT_DIR...")
end
