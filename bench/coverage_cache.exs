# Run with `elixir bench/coverage_cache.exs /path/to/reference_helper_template.ex`.
# Compile both helpers with the same options, then compare warmed literal-payload calls in fresh
# processes. This isolates probe bookkeeping; it says nothing about ordinary mutant runs.
defmodule CoverageCacheBench do
  def run(reference_path, label_mode \\ "labeled") do
    current_path = Path.expand("../lib/mutare/coverage/helper_template.ex", __DIR__)
    variants = [{:reference, reference_path}, {:current, current_path}]

    helpers =
      Map.new(variants, fn {name, path} ->
        module = Module.concat(__MODULE__, name)

        path
        |> File.read!()
        |> String.replace(
          "defmodule Mutare.Coverage.HelperTemplate do",
          "defmodule #{inspect(module)} do",
          global: false
        )
        |> Code.compile_string()

        {name, module}
      end)

    runtime = helpers.current.runtime(:fixture)

    for key <- [:agg_table, :attr_table, :unlabeled_table, :test_table, :wholefile_table] do
      :ets.new(Map.fetch!(runtime, key), [:named_table, :public, :set])
    end

    IO.puts(
      "Elixir #{System.version()}, OTP #{System.otp_release()}, #{:erlang.system_info(:schedulers_online)} schedulers"
    )

    IO.puts("attribution: #{label_mode}")
    IO.puts("ids\tgroups\tvariant\tns_per_hit\treductions_per_hit\tminor_gcs")

    for size <- [1, 2, 3, 8, 32, 128], groups <- [1, 64] do
      runners =
        Map.new(helpers, fn {name, helper} ->
          runner = Module.concat(__MODULE__, "#{name}_#{size}_#{groups}")

          calls =
            Enum.map_join(0..(groups - 1), "\n", fn group ->
              ids = Enum.to_list((group * size + 1)..((group + 1) * size))

              "#{inspect(helper)}.hit(\"lib/subject.ex\", #{inspect(ids, charlists: :as_lists, limit: :infinity)})"
            end)

          Code.compile_string("""
          defmodule #{inspect(runner)} do
            def run(0), do: :ok
            def run(n) do
              #{calls}
              run(n - 1)
            end
          end
          """)

          {name, runner}
        end)

      rounds = div(300_000, groups)
      hits = rounds * groups

      samples =
        for sample <- 1..7,
            name <-
              if(rem(sample, 2) == 0, do: [:current, :reference], else: [:reference, :current]) do
          {name, sample(runners[name], rounds, hits, label_mode)}
        end

      for name <- [:reference, :current] do
        values = for {^name, values} <- samples, do: values
        {ns, reductions, gcs} = Enum.sort(values) |> Enum.at(3)

        IO.puts(
          "#{size}\t#{groups}\t#{name}\t#{Float.round(ns, 1)}\t#{Float.round(reductions, 2)}\t#{gcs}"
        )
      end
    end
  end

  defp sample(runner, rounds, hits, label_mode) do
    parent = self()
    token = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        if label_mode == "labeled",
          do: Process.put(:"$process_label", {__MODULE__, :"test benchmark"})

        runner.run(10)
        :erlang.garbage_collect()
        {:reductions, before_reductions} = Process.info(self(), :reductions)
        {:garbage_collection, before_gc} = Process.info(self(), :garbage_collection)
        start = System.monotonic_time()
        runner.run(rounds)
        elapsed = System.monotonic_time() - start
        {:reductions, after_reductions} = Process.info(self(), :reductions)
        {:garbage_collection, after_gc} = Process.info(self(), :garbage_collection)

        send(
          parent,
          {token,
           {
             System.convert_time_unit(elapsed, :native, :nanosecond) / hits,
             (after_reductions - before_reductions) / hits,
             after_gc[:minor_gcs] - before_gc[:minor_gcs]
           }}
        )
      end)

    receive do
      {^token, values} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> values
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise "benchmark worker failed: #{inspect(reason)}"
    end
  end
end

case System.argv() do
  [reference_path] ->
    CoverageCacheBench.run(reference_path)

  [reference_path, mode] when mode in ["labeled", "unlabeled"] ->
    CoverageCacheBench.run(reference_path, mode)

  _ ->
    raise "usage: elixir bench/coverage_cache.exs /path/to/reference_helper_template.ex [labeled|unlabeled]"
end
