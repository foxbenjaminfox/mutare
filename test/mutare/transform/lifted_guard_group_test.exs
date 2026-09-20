defmodule Mutare.Transform.LiftedGuardGroupTest do
  @moduledoc """
  A lifted clause's **guard-only** mutants share one clause: the source head patterns, one copy
  of the raw body, and a `when` alternative per mutant, each gated on its own id
  (`Mutare.Transform.LiftedEmit`). Pattern-changing mutants and a custom mutator's guard keep
  a clause per mutant.

  The behavioural oracle is independent of the emitter: each site's range is patched into the
  source, the patched module is compiled on its own, and its outcomes are compared with the
  metamutant's under that id.
  """
  use ExUnit.Case, async: false

  alias Mutare.{Manifest, Selector}

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  # A marker no guard and no generated code contains, so its count is the number of copies of
  # the first clause's body.
  @marker ":shared_body_marker"

  @body """
  def classify(x, y) when x > 10 and y >= 2 do
    send(self(), #{@marker})
    {:big, x + y}
  end

  def classify(x, _y) when hd(x) == 1 when x < 0, do: {:odd, x}
  def classify(x, y) when is_integer(x) and x > 0, do: {:small, x, y}
  def classify(x, _y), do: {:other, x}
  """

  @inputs for x <- [-1, 0, 1, 10, 11, 12, [1], [2], :atom], y <- [1, 2, 3], do: [x, y]

  describe "behaviour" do
    test "every mutant agrees with its independently patched source" do
      {module, sites, _meta} = fixture(:Oracle, @body)
      assert Enum.count(sites, &(&1.mutator == :relational)) >= 8

      for site <- [nil | sites] do
        expected = patched_module(:Oracle, @body, site)
        Selector.put(if site, do: site.id, else: Selector.baseline())

        for args <- @inputs do
          assert outcome(module, args) == outcome(expected, args),
                 "mutant #{inspect(site && {site.id, site.original_code, site.mutated_code})}, " <>
                   "args #{inspect(args)}"
        end
      end
    end

    test "members from several families share a clause beside an instrumented original" do
      # The default set: relational, logical, and the guard's own integer literals all mutate
      # the first clause's guard, and the body carries in-place selectors — so the shared raw
      # body and the instrumented original's body genuinely differ.
      {module, sites, meta} = fixture(:Default, @body, Mutare.Mutators.all())

      # The first clause's lifted sites, less its `clause_drop`: a drop has no mutant clause at
      # all, only an exclusion on the original.
      first_guard =
        Enum.filter(sites, &(&1.line == 2 and &1.kind == :lifted and &1.mutator != :clause_drop))

      assert first_guard |> Enum.map(& &1.mutator) |> Enum.uniq() |> length() >= 3

      assert Enum.sort(clause_ids(meta, hd(first_guard).id)) ==
               Enum.sort(Enum.map(first_guard, & &1.id))

      for site <- [nil | sites], is_nil(site) or not site.poisoned do
        expected = patched_module(:Default, @body, site)
        Selector.put(if site, do: site.id, else: Selector.baseline())

        for args <- @inputs do
          assert outcome(module, args) == outcome(expected, args),
                 "mutant #{inspect(site && {site.id, site.mutator, site.original_code, site.mutated_code})}, " <>
                   "args #{inspect(args)}"
        end
      end
    end

    test "a member whose guard fails hands the call to the next source clause, not the original" do
      {module, sites, _meta} = fixture(:Fallthrough, @body)

      # `x > 10` → `x < 10` with (11, 2): the mutant guard fails. The unmutated first clause
      # would take it as `{:big, 13}`; the mutant must not.
      Selector.put(site(sites, "x > 10", "x < 10").id)
      assert apply(module, :classify, [11, 2]) == {:small, 11, 2}
      refute_received :shared_body_marker

      # And the shared body runs under a member whose guard passes.
      assert apply(module, :classify, [5, 2]) == {:big, 7}
      assert_received :shared_body_marker
    end

    test "a raising alternative fails only itself" do
      # `hd(x) == 1 when x < 0`: with the *second* alternative mutated, the first still raises
      # on a non-list and must fail alone, leaving the mutated second to decide.
      {module, sites, _meta} = fixture(:Raising, @body)

      Selector.put(site(sites, "x < 0", "x <= 0").id)
      assert apply(module, :classify, [0, 1]) == {:odd, 0}
      assert apply(module, :classify, [[1], 1]) == {:odd, [1]}
    end
  end

  describe "shape" do
    test "one copy of the raw body serves every guard mutant of the clause" do
      {_module, sites, meta} = fixture(:Shape, @body)
      first_clause = Enum.filter(sites, &(&1.line == 2 and &1.mutator == :relational))
      assert length(first_clause) >= 4

      # The shared mutant clause, the instrumented original, and the clean copy — where a
      # clause per mutant made it `length(first_clause) + 2`.
      assert count(meta, @marker) == 3

      for site <- first_clause, do: assert(meta =~ gate(site.id))
    end

    test "a source guard that is already a `when` sequence stays flat" do
      {_module, _sites, meta} = fixture(:Flat, @body)
      # Left-nested `(a when b) when c` reaches the guard as a call to `when/2`.
      refute meta =~ ~r/when \(:erlang/
    end

    test "a lone guard mutant keeps a clause of its own, as before" do
      body = "def f(x) when is_binary(x), do: {:bin, x}\ndef f(x), do: {:other, x}"
      {_module, sites, meta} = fixture(:Lone, body, [Mutare.Mutators.GuardDrop])
      assert [%{mutator: :guard_drop, id: id}] = sites

      assert meta =~
               ~r/defp \w+\(\s*mutare_active,\s*x\s*\)\s+when :erlang\."=:="\(mutare_active, #{id}\) do/
    end
  end

  describe "what keeps a clause per mutant" do
    test "a head-pattern mutant" do
      body = "def f(1, x) when x > 1 and x < 9, do: {:one, x}\ndef f(_, x), do: {:rest, x}"

      {module, sites, meta} =
        fixture(:Pattern, body, [Mutare.Mutators.Relational, Mutare.Mutators.IntegerLiteral])

      heads = Enum.filter(sites, &(&1.original_code == "1" and &1.line == 2 and &1.column < 12))
      guards = Enum.filter(sites, &(&1.mutator == :relational))
      assert heads != [] and length(guards) >= 4

      # One clause for the guard group, one per head mutant: a gate per head mutant opens a
      # clause of its own, while the guard gates are alternatives of one.
      assert count(meta, "{:one, x}") == 1 + length(heads) + 2

      for site <- sites do
        expected = patched_module(:Pattern, body, site, :f)
        Selector.put(site.id)

        for args <- [[1, 0], [1, 1], [1, 5], [1, 9], [0, 5], [2, 5]] do
          assert outcome(module, args, :f) == outcome(expected, args, :f),
                 "mutant #{site.id} #{site.original_code} → #{site.mutated_code}, #{inspect(args)}"
        end
      end
    end

    test "a custom mutator's guard mutant" do
      # Poison recovery attributes by line; a custom replacement need not compile, and in a
      # shared clause a head-line error would drop its healthy siblings.
      body = "def f(x) when x > 1 and x < 9, do: {:in, x}\ndef f(x), do: {:out, x}"

      {_module, sites, meta} =
        fixture(:Custom, body, [Mutare.Mutators.Relational, Mutare.Test.AndOrMutator])

      relational = Enum.filter(sites, &(&1.mutator == :relational))
      [custom] = Enum.filter(sites, &(&1.mutator == :and_or))

      # The built-in group's one body, the custom mutant's own, the original, the clean copy.
      assert count(meta, "{:in, x}") == 4
      assert Enum.sort(clause_ids(meta, custom.id)) == [custom.id]

      assert Enum.sort(clause_ids(meta, hd(relational).id)) ==
               Enum.sort(Enum.map(relational, & &1.id))
    end
  end

  describe "what does not" do
    test "a body calling a macro the transform knows nothing about" do
      # The transform does not ask what a call is. A macro that counts its expansions sees a
      # different count under lifting either way; sharing moves it toward the source's one.
      body = """
      defmacrop noted(value), do: value
      def f(x) when x > 1 and x < 9, do: {:in, noted(x)}
      def f(x), do: {:out, x}
      """

      {_module, sites, meta} = fixture(:Macro, body)
      relational = Enum.filter(sites, &(&1.mutator == :relational))
      assert length(relational) >= 4

      members = relational |> Enum.map(& &1.id) |> Enum.sort()
      for site <- relational, do: assert(Enum.sort(clause_ids(meta, site.id)) == members)
    end
  end

  describe "readback" do
    test "each alternative's line maps to its own mutant; the shared body to every member" do
      {_module, sites, meta, var} = fixture_with_var(:Readback, @body)
      manifest = Manifest.from_source(meta, var)

      members =
        sites |> Enum.filter(&(&1.line == 2 and &1.mutator == :relational)) |> Enum.map(& &1.id)

      for id <- members do
        assert Manifest.ids_at_line(manifest, line_of(meta, gate(id))) == [id]
      end

      # The marker's first occurrence is the shared mutant clause (mutants precede originals).
      assert Enum.sort(Manifest.ids_at_line(manifest, line_of(meta, @marker))) ==
               Enum.sort(members)
    end

    test "every member has a branch outside every other mutant's branch" do
      {_module, sites, meta, var} = fixture_with_var(:Mentions, @body)
      mentions = Manifest.from_source(meta, var).mentions

      for site <- sites, site.mutator == :relational do
        assert %{kind: :branch, id: site.id, within: nil} in mentions
      end
    end

    test "dropping a poisoned member keeps its siblings deliverable" do
      {_module, sites, _meta} = fixture(:Before, @body)
      [dropped | kept] = Enum.filter(sites, &(&1.line == 2 and &1.mutator == :relational))

      {module, after_sites, meta} =
        fixture(:After, @body, [Mutare.Mutators.Relational], skip_ids: [dropped.id])

      assert Enum.find(after_sites, &(&1.id == dropped.id)).poisoned
      refute meta =~ gate(dropped.id)

      for site <- kept do
        expected = patched_module(:After, @body, site)
        Selector.put(site.id)
        for args <- @inputs, do: assert(outcome(module, args) == outcome(expected, args))
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp fixture(name, body, mutators \\ [Mutare.Mutators.Relational], opts \\ []) do
    {module, sites, meta, _var} = fixture_with_var(name, body, mutators, opts)
    {module, sites, meta}
  end

  defp fixture_with_var(name, body, mutators \\ [Mutare.Mutators.Relational], opts \\ []) do
    module = Module.concat(__MODULE__, name)

    %{metamutant: meta, sites: sites, dispatch_var: var} =
      Mutare.Transform.transform_string_with_sites(
        source(module, body),
        [file: "lifted_guard_group.ex", mutators: mutators, verify_invariants: true] ++ opts
      )

    [{^module, _} | _] = Mutare.Test.Compile.string(meta)
    {module, sites, meta, var}
  end

  # The source with one site's range patched, compiled under its own module name.
  defp patched_module(name, body, site, _fun \\ :classify) do
    original = Module.concat(__MODULE__, name)
    source = source(original, body)

    patched =
      if site,
        do: Sourceror.patch_string(source, [%{range: site.range, change: site.mutated_code}]),
        else: source

    tag = if site, do: "Patched#{site.id}", else: "Unpatched"
    expected = Module.concat([__MODULE__, name, tag])

    renamed =
      String.replace(
        patched,
        "defmodule #{inspect(original)} do",
        "defmodule #{inspect(expected)} do",
        global: false
      )

    [{^expected, _} | _] = Mutare.Test.Compile.string(renamed)
    expected
  end

  defp source(module, body), do: "defmodule #{inspect(module)} do\n#{body}\nend\n"

  defp outcome(module, args, fun \\ :classify) do
    # Any exception is an outcome to compare, not only a missed clause: term order puts a
    # list above every integer, so `classify([1], 2)` passes `x > 10` and raises in `x + y`
    # — in the source exactly as in the metamutant.
    result =
      try do
        {:ok, apply(module, fun, args)}
      rescue
        error -> {:raised, error.__struct__}
      end

    {result, flush()}
  end

  defp flush do
    receive do
      message -> [message | flush()]
    after
      0 -> []
    end
  end

  defp site(sites, original, mutated) do
    found = Enum.find(sites, &(&1.original_code == original and &1.mutated_code == mutated))
    assert found, "missing #{original} -> #{mutated}"
    found
  end

  defp gate(id), do: ~s[:erlang."=:="(mutare_active, #{id})]

  defp count(text, part), do: length(String.split(text, part)) - 1

  defp line_of(meta, part) do
    index = meta |> String.split("\n") |> Enum.find_index(&String.contains?(&1, part))
    assert index, "no line contains #{part}"
    index + 1
  end

  # The ids gated in the one `defp` clause that gates `id`.
  defp clause_ids(meta, id) do
    clause =
      meta
      |> String.split(~r/^  defp /m)
      |> Enum.find(&String.contains?(&1, gate(id)))

    assert clause, "no clause gates #{id}"

    ~r/:erlang\."=:="\(mutare_active, (\d+)\)/
    |> Regex.scan(clause)
    |> Enum.map(fn [_, n] -> String.to_integer(n) end)
  end
end
