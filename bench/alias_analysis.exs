# Generate once, compile the exact same source with alias analysis on/off, then
# measure it in fresh VMs. Run with `mix run bench/alias_analysis.exs OUTPUT`.
# See bench/README.md for controls and interpretation.

defmodule Mutare.AliasAnalysisBench do
  @kernels [
    :tuple,
    :binary,
    :selectors,
    :clauses,
    :cases,
    :pipelines,
    :bindings,
    :body_only,
    :callback,
    :leaf1,
    :leaf2,
    :leaf3,
    :leaf4
  ]
  @counts [
    tuple: 500_000,
    binary: 500_000,
    selectors: 100_000,
    clauses: 500_000,
    cases: 250_000,
    pipelines: 30_000,
    bindings: 250_000,
    body_only: 250_000,
    callback: 250_000,
    leaf1: 500_000,
    leaf2: 500_000,
    leaf3: 500_000,
    leaf4: 500_000
  ]
  # The leaf kernels share one marker: their "inside" mutation lives in `leaf_one/2`, so
  # for the larger leaves that state is one more "elsewhere" sample.
  @markers %{
    tuple: "a + 1",
    binary: "value + 1",
    selectors: "x + 2",
    clauses: "x + 3",
    cases: "value + 4",
    pipelines: "x + 5",
    bindings: "x + 11",
    body_only: "x + 12",
    callback: "acc + 13",
    leaf1: "x + y",
    leaf2: "x + y",
    leaf3: "x + y",
    leaf4: "x + y"
  }

  def run(root, rounds, experiment \\ :alias, clean_opts \\ []) when rounds > 0 do
    root = Path.expand(root)
    File.mkdir_p!(root)
    source = source()

    options = [
      file: "lib/kernel.ex",
      runtime_namespace: "lib/kernel.ex",
      mutators:
        if(experiment == :alias,
          do: [:arithmetic, :relational],
          else: [:arithmetic, :relational, :integer]
        )
    ]

    %{metamutant: meta, sites: sites} =
      Mutare.Transform.transform_string_with_sites(
        source,
        options ++ [clean_functions: false]
      )

    sources = [{"original", source}, {"metamutant", meta}]

    sources =
      if experiment in [:clean, :clean_alias] do
        %{metamutant: clean, sites: clean_sites} =
          Mutare.Transform.transform_string_with_sites(
            source,
            options ++ [clean_functions: true] ++ clean_opts
          )

        unless sites == clean_sites, do: raise("clean path changed mutation identities")
        sources ++ [{"clean", clean}]
      else
        sources
      end

    ids =
      Map.new(@kernels, fn kernel ->
        marker = Map.fetch!(@markers, kernel)

        site =
          Enum.find(sites, &(&1.original_code == marker and &1.variant == :-)) ||
            Enum.find(
              sites,
              &(&1.original_code == marker and &1.mutated_code == String.replace(marker, "+", "-"))
            )

        if is_nil(site), do: raise("no safe mutation for #{kernel}: #{marker}")
        {kernel, site.id}
      end)

    elsewhere = Enum.find(sites, &(&1.original_code == "x + 7")).id
    File.write!(Path.join(root, "original.ex"), source)
    File.write!(Path.join(root, "metamutant.ex"), meta)

    File.write!(
      Path.join(root, "environment.exs"),
      inspect(
        %{
          elixir: System.version(),
          otp: to_string(:erlang.system_info(:otp_release)),
          erts: to_string(:erlang.system_info(:version)),
          schedulers: :erlang.system_info(:schedulers_online),
          git: elem(System.cmd("git", ["rev-parse", "HEAD"]), 0) |> String.trim(),
          source_sha256: hash(source),
          metamutant_sha256: hash(meta),
          sites: length(sites),
          inherited_erl_options: System.get_env("ERL_COMPILER_OPTIONS"),
          experiment: experiment,
          hashes: Map.new(sources, fn {name, code} -> {name, hash(code)} end)
        },
        pretty: true
      ) <> "\n"
    )

    expected = expected(source)

    for {shape, code} <- sources do
      project = Path.join(root, shape)
      File.mkdir_p!(Path.join(project, "lib"))
      File.write!(Path.join(project, "lib/kernel.ex"), code)
      File.write!(Path.join(project, "lib/coverage.ex"), Mutare.Coverage.Recorder.helper_source())

      File.write!(Path.join(project, "mix.exs"), """
      defmodule AliasBench.Project do
        use Mix.Project
        def project, do: [app: :alias_bench, version: "0.1.0", elixirc_options: [infer_signatures: false]]
      end
      """)

      # Literal expected values are computed from separately compiled single-mutant
      # source. No selector machinery participates in this semantic oracle.
      File.write!(Path.join(project, "worker.exs"), worker(ids, elsewhere, expected))
    end

    compile_path = Path.join(root, "compile.tsv")
    run_path = Path.join(root, "runtime.tsv")
    File.write!(compile_path, "round\tshape\talias\tcompile_us\tbeam_bytes\tcode_bytes\n")

    File.write!(
      run_path,
      "round\tshape\talias\tstate\tkernel\titerations\truntime_us\treductions\tminor_gcs\treclaimed_words\n"
    )

    inherited = inherited_options()

    for round <- 1..rounds,
        {shape, enabled?} <- alternating(round, experiment) do
      project = Path.join(root, shape)
      label = if enabled?, do: "on", else: "off"
      build = Path.join(project, "_build_#{label}")
      opts = if enabled?, do: inherited, else: [:no_ssa_opt_alias | inherited]

      env = [
        {"MIX_ENV", "test"},
        {"MIX_BUILD_PATH", build},
        {"ERL_COMPILER_OPTIONS", IO.iodata_to_binary(:io_lib.format(~c"~tp", [opts]))}
      ]

      args = ["compile", "--force"] ++ Mutare.Sandbox.CompilerOptions.compile_args()

      {us, {output, status}} =
        :timer.tc(fn ->
          System.cmd("mix", args, cd: project, env: env, stderr_to_stdout: true)
        end)

      File.write!(Path.join(project, "compile-#{round}-#{label}.log"), output)
      if status != 0, do: raise("compile failed; see #{project}/compile-#{round}-#{label}.log")
      beam = Path.join(build, "lib/alias_bench/ebin/Elixir.AliasBench.Kernel.beam")
      binary = File.read!(beam)
      {:ok, _, chunks} = :beam_lib.all_chunks(binary)
      code = chunks |> List.keyfind(~c"Code", 0) |> elem(1)

      File.write!(
        compile_path,
        "#{round}\t#{shape}\t#{label}\t#{us}\t#{byte_size(binary)}\t#{byte_size(code)}\n",
        [:append]
      )

      File.write!(
        Path.join(project, "beam-#{label}.exs"),
        inspect(:beam_disasm.file(String.to_charlist(beam)),
          limit: :infinity,
          pretty: true,
          width: 120
        )
      )

      {runtime, status} =
        System.cmd(
          "elixir",
          ["-pa", Path.dirname(beam), "worker.exs", to_string(round), shape, label],
          cd: project,
          env: env,
          stderr_to_stdout: true
        )

      if status != 0, do: raise("runtime failed: #{runtime}")
      File.write!(run_path, runtime, [:append])
      IO.puts("round #{round} #{shape} alias #{label}: #{Float.round(us / 1000, 1)} ms compile")
    end

    IO.puts("Results: #{compile_path}, #{run_path}")
  end

  defp alternating(round, experiment) do
    choices =
      case experiment do
        :alias ->
          for shape <- ["original", "metamutant"],
              enabled? <- [true, false],
              do: {shape, enabled?}

        :clean ->
          for shape <- ["original", "metamutant", "clean"], do: {shape, false}

        # Do the two effects compose? The clean build runs source code, which is where the
        # alias pass finds `private_append`.
        :clean_alias ->
          for shape <- ["original", "clean"], enabled? <- [true, false], do: {shape, enabled?}
      end

    if rem(round, 2) == 1, do: choices, else: Enum.reverse(choices)
  end

  defp inherited_options do
    case System.get_env("ERL_COMPILER_OPTIONS") do
      empty when empty in [nil, ""] ->
        []

      raw ->
        {:ok, tokens, _} = :erl_scan.string(String.to_charlist(raw <> "."))
        {:ok, parsed} = :erl_parse.parse_term(tokens)
        opts = List.wrap(parsed)

        if :no_ssa_opt_alias in opts or :no_ssa_opt in opts,
          do:
            raise(
              "alias experiment requires inherited options without no_ssa_opt_alias/no_ssa_opt"
            )

        opts
    end
  end

  defp hash(source), do: Base.encode16(:crypto.hash(:sha256, source), case: :lower)

  defp expected(source) do
    # Compile references once during generation, outside every timed subprocess.
    Code.compiler_options(ignore_module_conflict: true, infer_signatures: false)

    for state <- [:baseline, :inside], kernel <- @kernels, into: %{} do
      marker = Map.fetch!(@markers, kernel)

      reference =
        if state == :inside,
          do: String.replace(source, marker, String.replace(marker, "+", "-"), global: false),
          else: source

      reference = String.replace(reference, "AliasBench.Kernel", "AliasBench.Reference")
      Code.compile_string(reference)
      {{state, kernel}, apply(AliasBench.Reference, kernel, [31, 11])}
    end
  end

  defp worker(ids, elsewhere, expected) do
    setup = Mutare.Coverage.Recorder.tables_ast(:harness) |> Macro.to_string()

    # The worker runs without Mutare, so the stored form of a namespace is written out —
    # asked of this revision's `Mutare.Selector`, so the script also runs in a worktree of
    # a revision that stored the path string itself (`bench/kernel_ab.exs`).
    Code.ensure_loaded!(Mutare.Selector)

    [this_file, other_file] =
      for namespace <- ["lib/kernel.ex", "lib/other.ex"] do
        if function_exported?(Mutare.Selector, :namespace_key, 1),
          do: inspect(apply(Mutare.Selector, :namespace_key, [namespace])),
          else: inspect(namespace)
      end

    """
    defmodule AliasBench.Worker do
      def run do
        [round, shape, alias_mode] = System.argv()
        ids = #{inspect(ids)}
        expected = #{inspect(expected, limit: :infinity)}
        for state <- [:baseline, :probe, :elsewhere, :other_file, :inside] do
          :persistent_term.put(:mutare_probe, state == :probe)
          :persistent_term.put(:mutare_track, false)
          #{setup}
          for {kernel, iterations} <- #{inspect(@counts)} do
            active = case state do
              :inside -> {#{this_file}, Map.fetch!(ids, kernel)}
              :elsewhere -> {#{this_file}, #{elsewhere}}
              :other_file -> {#{other_file}, 1}
              _ -> 0
            end
            :persistent_term.put(:mutare_active, active)
            oracle_state = if state == :inside and shape != "original", do: :inside, else: :baseline
            actual = apply(AliasBench.Kernel, kernel, [31, 11])
            unless actual == Map.fetch!(expected, {oracle_state, kernel}),
              do: raise("single-mutant behavior differs: " <> inspect({shape, state, kernel, actual}))
            # Warm JIT/code/data before creating the measured process. Each sample
            # has fresh process-local coverage caches and heap/GC history.
            apply(AliasBench.Kernel, kernel, [100, 11])
            parent = self()
            {pid, ref} = spawn_monitor(fn ->
              Process.put(:"$process_label", {AliasBench.Kernel, :"test benchmark"})
              :erlang.garbage_collect()
              {_, words0, _} = :erlang.statistics(:garbage_collection)
              {:reductions, reductions0} = Process.info(self(), :reductions)
              {us, value} = :timer.tc(fn -> apply(AliasBench.Kernel, kernel, [iterations, 11]) end)
              {:reductions, reductions1} = Process.info(self(), :reductions)
              {:garbage_collection, gc} = Process.info(self(), :garbage_collection)
              {_, words1, _} = :erlang.statistics(:garbage_collection)
              # Consume the result after timing. Keep GC counters inside the sample
              # but exclude term hashing and mailbox serialization from elapsed time.
              send(parent, {:sample, [round, shape, alias_mode, state, kernel, iterations,
                us, reductions1 - reductions0, gc[:minor_gcs], words1 - words0], :erlang.phash2(value)})
            end)
            receive do
              {:sample, row, _checksum} ->
                IO.puts(Enum.join(row, "\\t"))
                receive do {:DOWN, ^ref, :process, ^pid, :normal} -> :ok end
              {:DOWN, ^ref, :process, ^pid, reason} -> raise("sample failed: " <> inspect(reason))
            after
              120_000 -> raise("sample timed out")
            end
          end
        end
      end
    end
    AliasBench.Worker.run()
    """
  end

  defp source do
    selectors = Enum.map_join(1..16, "\n", fn _ -> "x = x + 2" end)

    clauses =
      Enum.map_join(0..7, "\n", fn tag ->
        "defp clauses_loop(n, #{tag}, x) when n > 0, do: clauses_loop(n - 1, rem(#{tag} + 1, 8), x + 3)"
      end)

    """
    defmodule AliasBench.Kernel do
      def elsewhere(x), do: x + 7

      def tuple(n, seed), do: tuple_loop(n, {seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
      defp tuple_loop(0, state), do: state
      defp tuple_loop(n, {a, _b, _c, _d, _e, _f, _g, _h, _i, _j, _k, _l, _m, _o, _p, _q} = state) do
        state = put_elem(state, 0, a + 1)
        tuple_loop(n - 1, state)
      end

      def binary(n, seed), do: binary_loop(n, <<>>, seed)
      defp binary_loop(0, acc, _value), do: acc
      defp binary_loop(n, acc, value), do: binary_loop(n - 1, <<acc::binary, value + 1>>, value)

      def selectors(n, seed), do: selectors_loop(n, seed)
      defp selectors_loop(0, x), do: x
      defp selectors_loop(n, x) do
        #{selectors}
        selectors_loop(n - 1, x)
      end

      def clauses(n, seed), do: clauses_loop(n, 0, seed)
      defp clauses_loop(0, _tag, x), do: x
      #{clauses}

      def cases(n, seed), do: cases_loop(n, seed)
      defp cases_loop(0, value), do: value
      defp cases_loop(n, value) do
        increment = case rem(n, 4) do
          0 -> value + 4
          1 -> value + 6
          2 -> value + 8
          3 -> value + 10
        end
        cases_loop(n - 1, increment)
      end

      def pipelines(n, seed), do: pipelines_loop(n, seed)
      defp pipelines_loop(0, value), do: value
      defp pipelines_loop(n, value) do
        next = [value, 1, 2, 3] |> Enum.map(fn x -> x + 5 end) |> Enum.sum()
        pipelines_loop(n - 1, next)
      end

      def bindings(n, seed), do: bindings_loop(n, seed)
      defp bindings_loop(0, x), do: x
      defp bindings_loop(n, x) do
        adjusted = x + 11
        scaled =
          case rem(n, 3) do
            0 -> adjusted * 2
            1 ->
              local = adjusted - 3
              local * 2
            _ -> adjusted
          end
        bindings_loop(n - 1, rem(scaled, 1_000_003))
      end

      def body_only(n, seed), do: body_only_loop(n, seed)
      defp body_only_loop(n, x) do
        if n > 0 do
          y = x + 12
          z = y * 3
          body_only_loop(n - 1, rem(z, 1_000_003))
        else
          x
        end
      end

      def callback(n, seed) do
        Enum.reduce(1..n, seed, fn i, acc -> rem(acc + 13 + i, 1_000_003) end)
      end

      # mutare:ignore-start the drivers hold no mutant, so every build runs the same loop
      def leaf1(n, seed), do: leaf_drive(n, seed, 1)
      def leaf2(n, seed), do: leaf_drive(n, seed, 2)
      def leaf3(n, seed), do: leaf_drive(n, seed, 3)
      def leaf4(n, seed), do: leaf_drive(n, seed, 4)
      defp leaf_drive(0, x, _leaf), do: x
      defp leaf_drive(n, x, 1), do: leaf_drive(n - 1, leaf_one(x, 3), 1)
      defp leaf_drive(n, x, 2), do: leaf_drive(n - 1, leaf_two(x, 3), 2)
      defp leaf_drive(n, x, 3), do: leaf_drive(n - 1, leaf_three(x, 3), 3)
      defp leaf_drive(n, x, 4), do: leaf_drive(n - 1, leaf_four(x, 3), 4)
      # mutare:ignore-end

      defp leaf_one(x, y), do: x + y
      defp leaf_two(x, y), do: x + y + y
      defp leaf_three(x, y), do: x + y + y + y
      defp leaf_four(x, y), do: x + y + y + y + y
    end
    """
  end
end

case System.argv() do
  [output] ->
    Mutare.AliasAnalysisBench.run(output, 5)

  [output, rounds] ->
    Mutare.AliasAnalysisBench.run(output, String.to_integer(rounds))

  [output, rounds, "clean"] ->
    Mutare.AliasAnalysisBench.run(output, String.to_integer(rounds), :clean)

  [output, rounds, "clean_alias"] ->
    Mutare.AliasAnalysisBench.run(output, String.to_integer(rounds), :clean_alias)

  [output, rounds, "clean", threshold] ->
    Mutare.AliasAnalysisBench.run(output, String.to_integer(rounds), :clean,
      clean_threshold: String.to_integer(threshold)
    )

  _ ->
    raise(
      "usage: mix run bench/alias_analysis.exs OUTPUT [ROUNDS [clean [THRESHOLD] | clean_alias]]"
    )
end
