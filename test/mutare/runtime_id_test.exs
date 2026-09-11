defmodule Mutare.RuntimeIdTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Mutare.{Coverage, Manifest, Metamutant, Poison, RuntimeId, Schema, Selector, Transform}

  @moduletag :tmp_dir

  defmodule FixtureCoverage do
    def hit(ids), do: hit(nil, ids)

    def hit(namespace, ids) do
      send(self(), {:fixture_coverage, namespace, ids})
      true
    end
  end

  setup do
    active = Selector.active()
    on_exit(fn -> Selector.put(active) end)
    Selector.put(0)
    :ok
  end

  test "an unrelated count or discovery change moves report ids without rewriting B", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "lib"))
    a = Path.join(root, "lib/a.ex")
    b = Path.join(root, "lib/b.ex")
    File.write!(a, "defmodule StableA do\n def f(x), do: x + 2\nend\n")
    File.write!(b, source("StableB"))
    before = Schema.build(root)
    File.write!(a, "defmodule StableA do\n def f(x), do: x + 2 + 3\nend\n")
    after_edit = Schema.build(root)
    alone = Schema.build(root, only_files: MapSet.new(["lib/b.ex"]))

    assert before.metamutants["lib/b.ex"] == after_edit.metamutants["lib/b.ex"]
    assert before.metamutants["lib/b.ex"] == alone.metamutants["lib/b.ex"]
    refute before.start_ids["lib/b.ex"] == after_edit.start_ids["lib/b.ex"]
    assert alone.start_ids["lib/b.ex"] == 1

    identities = fn schema ->
      for site <- schema.sites, site.file == "lib/b.ex", do: RuntimeId.of(site)
    end

    assert identities.(before) == identities.(after_edit)
    assert identities.(before) == identities.(alone)
  end

  test "report offsets never enter emitted code, including selection and poison holes" do
    opts = [file: "lib/b.ex", runtime_namespace: "lib/b.ex"]
    src = source("StableB")
    {full, sites, next} = Transform.transform_string_with_sites(src, opts)

    {shifted, shifted_sites, shifted_next} =
      Transform.transform_string_with_sites(src, [start_id: 501] ++ opts)

    assert shifted == full
    assert shifted_next == next + 500
    assert Enum.map(shifted_sites, & &1.id) == Enum.map(sites, &(&1.id + 500))
    assert Enum.map(shifted_sites, & &1.runtime_id) == Enum.map(sites, & &1.runtime_id)
    {standalone, _, _} = Transform.transform_string_with_sites(src)
    # A dropped function clause has no mutant body to poison. Preserve the
    # existing manifest's attribution, including inline default selectors.
    assert manifest_ids(full) == manifest_ids(standalone)

    selection = MapSet.new(2..(next - 1)//2)

    {focused, _, _} =
      Transform.transform_string_with_sites(
        src,
        [emit_ids: selection, skip_ids: MapSet.new([2])] ++ opts
      )

    {focused_shifted, _, _} =
      Transform.transform_string_with_sites(
        src,
        [start_id: 501, emit_ids: MapSet.new(selection, &(&1 + 500)), skip_ids: MapSet.new([502])] ++
          opts
      )

    assert focused == focused_shifted

    assert manifest_ids(focused) ==
             MapSet.intersection(manifest_ids(full), MapSet.delete(selection, 2))
  end

  test "the same local id activates one file, and switching or resetting clears the old file" do
    opts = [mutators: [:arithmetic], start_id: 30]

    for {file, module} <- [{"lib/a.ex", RuntimeA}, {"lib/b.ex", RuntimeB}] do
      {meta, [site], 31} =
        Transform.transform_string_with_sites(
          "defmodule #{inspect(module)} do\n def f(x), do: x + 2\nend\n",
          [file: file, runtime_namespace: file] ++ opts
        )

      assert site.id == 30
      assert site.runtime_id == {file, 1}
      Mutare.Test.Compile.string(meta)

      on_exit(fn ->
        :code.purge(module)
        :code.delete(module)
      end)
    end

    observe = fn -> for module <- [RuntimeA, RuntimeB], do: module.f(5) end
    assert observe.() == [7, 7]
    Selector.put({"lib/a.ex", 1})
    assert observe.() == [3, 7]
    Selector.put({"lib/b.ex", 1})
    assert observe.() == [7, 3]
    Selector.put(0)
    assert observe.() == [7, 7]
  end

  test "namespace selector recognition survives literal-encoded parsing and key isolation" do
    namespace = "apps/core/lib/a.ex"
    subject = Metamutant.subject_ast(namespace)
    assert Metamutant.subject?(subject)

    reparsed =
      subject
      |> Mutare.AST.to_string()
      |> Code.string_to_quoted!(
        literal_encoder: fn value, meta -> {:ok, {:__block__, meta, [value]}} end
      )

    assert Metamutant.subject?(reparsed)
    assert Code.eval_quoted(subject) |> elem(0) == 0
    Selector.put({namespace, 9})
    assert Code.eval_quoted(subject) |> elem(0) == 9
    Selector.put({"another.ex", 9})
    assert Code.eval_quoted(subject) |> elem(0) == :inactive
  end

  test "namespaced delivery preserves each standalone mutant's behavior across emission paths" do
    module = NamespaceExecution

    src =
      source(inspect(module))
      |> String.replace("defmodule #{inspect(module)} do", """
      defmodule #{inspect(module)} do
        import Mutare.Test.HostDSL
        def hosted(a, b), do: filter([a], a > b)
        def collision(mutare_local_id, mutare_active), do: {mutare_local_id + 1, mutare_active + 2}
      """)

    opts = [start_id: 301, mutators: Mutare.Mutators.all() ++ [Mutare.Test.HostMutator]]

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    {standalone, sites, _} = Transform.transform_string_with_sites(src, opts)
    Mutare.Test.Compile.string(standalone)
    baseline = observe(module)

    expected =
      Map.new(sites, fn site ->
        Selector.put(site.id)
        {site.id, observe(module)}
      end)

    :code.purge(module)
    :code.delete(module)

    {namespaced, sites, _} =
      Transform.transform_string_with_sites(src, [runtime_namespace: "lib/execution.ex"] ++ opts)

    Mutare.Test.Compile.string(namespaced)

    for site <- sites do
      Selector.put(RuntimeId.of(site))
      assert observe(module) == expected[site.id], "runtime identity #{inspect(site.runtime_id)}"
    end

    Selector.put({"unrelated.ex", 1})
    assert observe(module) == baseline
    Selector.put(0)
    assert observe(module) == baseline
  end

  test "coverage translates every collection and rejects unknown runtime identities", %{
    tmp_dir: root
  } do
    a = {"lib/a.ex", 1}
    b = {"lib/b.ex", 1}
    path = Path.join(root, "coverage.terms")

    # The dump groups local ids under their file namespace.
    payload = %{
      aggregate: %{"lib/a.ex" => [1], "lib/b.ex" => [1]},
      by_file: %{"test/b_test.exs" => %{"lib/b.ex" => [1]}},
      unlabeled: %{"lib/a.ex" => [1]},
      by_test: %{"lib/b.ex" => %{1 => ["test b"]}},
      wholefile: %{"lib/b.ex" => [1]}
    }

    File.write!(path, :erlang.term_to_binary(payload))
    assert {:ok, coverage} = Coverage.read_dump(path, %{a => 3, b => 17})

    assert coverage == %{
             aggregate: MapSet.new([3, 17]),
             by_file: %{"test/b_test.exs" => MapSet.new([17])},
             unlabeled: MapSet.new([3]),
             by_test: %{17 => MapSet.new(["test b"])},
             wholefile: MapSet.new([17])
           }

    # Without an index, the same dump reads back as the runtime identities it recorded.
    assert {:ok, raw} = Coverage.read_dump(path)
    assert raw.aggregate == MapSet.new([a, b])
    assert raw.by_test == %{b => MapSet.new(["test b"])}

    # An unknown id in *any* field must invalidate the dump, even when its aggregate is valid.
    for field <- Map.keys(payload) do
      field_only = Map.merge(%{aggregate: %{}, by_file: %{}}, Map.take(payload, [field]))
      File.write!(path, :erlang.term_to_binary(field_only))

      assert capture_log(fn ->
               assert {:error, {:unknown_runtime_id, _}} = Coverage.read_dump(path, %{})
             end) =~ "falling back to run-all"
    end
  end

  test "self-hosted fixture emission uses its private helper, leaving outer probe ids untouched" do
    alias Mutare.Coverage.Recorder
    saved_env = System.get_env(Recorder.fixture_override_env())
    saved_track = :persistent_term.get(Recorder.track_key(), false)

    try do
      System.put_env(Recorder.fixture_override_env(), Atom.to_string(FixtureCoverage))
      :persistent_term.put(Recorder.track_key(), true)

      for namespace <- [nil, "lib/fixture.ex"] do
        record = Recorder.record_ast([1, 2], :mutare_active, namespace)
        assert {true, _} = Code.eval_quoted(record, mutare_active: 0)
        assert_received {:fixture_coverage, ^namespace, [1, 2]}
        attr = Recorder.no_warn_attr_ast(namespace) |> Macro.to_string()
        assert attr =~ inspect(FixtureCoverage)
        assert Recorder.helper_source() =~ "defmodule :mutare_cov do"
      end
    after
      if saved_env,
        do: System.put_env(Recorder.fixture_override_env(), saved_env),
        else: System.delete_env(Recorder.fixture_override_env())

      :persistent_term.put(Recorder.track_key(), saved_track)
    end
  end

  test "poison translates local ids before combining files, including the macro fallback" do
    {metas, sites} =
      Enum.reduce([{"lib/a.ex", 10}, {"lib/b.ex", 20}], {%{}, []}, fn {file, start},
                                                                      {metas, sites} ->
        src = "defmodule PoisonIdentity do\n def f(x), do: query(x + 2)\nend\n"

        {meta, [site], _} =
          Transform.transform_string_with_sites(src,
            file: file,
            runtime_namespace: file,
            start_id: start,
            mutators: [:arithmetic]
          )

        {Map.put(metas, file, meta), [site | sites]}
      end)

    index = RuntimeId.file_index(sites)

    errors =
      Enum.map_join(metas, "\n", fn {file, meta} ->
        line = meta |> String.split("\n") |> Enum.find_index(&String.contains?(&1, "x - 2"))
        "#{file}:#{line + 1}: broken mutation"
      end)

    assert Poison.ids(errors, metas, index) == MapSet.new([10, 20])

    # One failure per file, as the compiler prints them: each stacktrace's innermost frame is
    # looked up in its own call-site file, and the two files' local ids translate apart.
    frames =
      Enum.map_join(Map.keys(metas), "\n", fn file ->
        "** (RuntimeError) boom\nexpanding macro: MyDsl.query/1\n#{file}:2: PoisonIdentity.f/1"
      end)

    assert [{{"MyDsl", :query}, ids}] = Poison.macro_poison(frames, metas, index)
    assert ids == MapSet.new([10, 20])
  end

  test "poison attributes nothing rather than raising on a pristine file's phantom ids", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "defmodule PhantomA do\n def f(x), do: x + 2\nend\n")

    # `lib/b.ex` writes a selector's own shape. The cap leaves it nothing to emit, so it
    # renders pristine — no generated code anchors the salted dispatch name, and the manifest
    # reads this `1 ->` clause back as local id 1, which no site of this run claims.
    imitation = """
    defmodule PhantomB do
      def pick(mutare_active) do
        case mutare_active do
          1 -> :one
          _ -> :other
        end
      end
    end
    """

    File.write!(Path.join(root, "lib/b.ex"), imitation)

    schema = Schema.build(root, max_mutants: 2)
    index = RuntimeId.file_index(schema.sites)

    assert schema.metamutants["lib/b.ex"] == imitation
    assert Enum.filter(schema.sites, &(&1.file == "lib/b.ex")) == []
    assert manifest_ids(schema.metamutants["lib/b.ex"]) == MapSet.new([1])

    phantom = "** (CompileError) lib/b.ex:4: broken\n"
    real = error_at_first_region(schema, "lib/a.ex")
    real_ids = Poison.ids(real, schema.metamutants, index)

    assert Poison.ids(phantom, schema.metamutants, index) == MapSet.new()
    refute Enum.empty?(real_ids)
    assert Poison.ids(real <> phantom, schema.metamutants, index) == real_ids

    frames = "expanding macro: MyDsl.pick/1\nlib/b.ex:3: PhantomB.pick/1\n"
    assert Poison.macro_poison(frames, schema.metamutants, index) == []
  end

  # A compile error pointing at the first line of generated code in `file`'s metamutant —
  # a location that really does attribute to a mutant.
  defp error_at_first_region(schema, file) do
    %{lo: line} =
      schema.metamutants
      |> Map.fetch!(file)
      |> Manifest.from_source()
      |> Map.fetch!(:regions)
      |> hd()

    "** (CompileError) #{file}:#{line}: broken\n"
  end

  defp manifest_ids(source),
    do:
      source
      |> Manifest.from_source()
      |> Map.fetch!(:regions)
      |> Enum.flat_map(& &1.ids)
      |> MapSet.new()

  defp observe(module) do
    for {function, args} <- [
          {:body, [5]},
          {:guarded, [-1]},
          {:guarded, [0]},
          {:guarded, [2]},
          {:default, []},
          {:matching, [1]},
          {:matching, [:other]},
          {:anonymous, [1]},
          {:anonymous, [3]},
          {:rescued, [0]},
          {:rescued, [2]},
          {:binding, [{1, 3}]},
          {:hosted, [2, 1]},
          {:hosted, [1, 1]},
          {:collision, [3, 4]}
        ] do
      try do
        {:ok, apply(module, function, args)}
      rescue
        error -> {:raised, error.__struct__}
      end
    end
  end

  defp source(module) do
    """
    defmodule #{module} do
      def body(x), do: x + 2
      def guarded(x) when x > 0, do: x + 3
      def guarded(x), do: x - 5
      def default(x \\\\ 2), do: x + 1
      def matching(x) do
        case x do
          1 -> :one
          _ -> :other
        end
      end
      def anonymous(x), do: (fn 1 -> 2; n -> n + 1 end).(x)
      def mailbox do
        receive do
          {:value, 1} -> 2
          {:value, n} -> n + 1
        after
          0 -> :empty
        end
      end
      def rescued(x) do
        try do
          10 / x
        rescue
          e in [ArithmeticError, ArgumentError] -> {:error, e}
        end
      end
      def binding(x) do
        {1, n} = x
        destructure([a, b], [n, 2])
        a + b
      end
    end
    """
  end
end
