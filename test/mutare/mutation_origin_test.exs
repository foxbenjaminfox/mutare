defmodule Mutare.MutationOriginTest do
  use ExUnit.Case, async: true

  alias Mutare.{Analyze, Schema}
  alias Mutare.Mutator.Mutation
  alias Mutare.Test.SourcePatch

  defmodule DSL do
    defmacro hosted(expression), do: expression
    defmacro plain(expression), do: expression
    defmacro options(pairs), do: pairs
  end

  defmodule Adapter do
    @behaviour Mutare.Mutator
    @behaviour Mutare.CallRouting
    @behaviour Mutare.Mutator.MacroHost

    alias Mutare.CallRouting.Call
    alias Mutare.Mutator.MacroHost.Target

    def name, do: :origin_adapter
    def variants, do: [:replacement, :drop]

    def call_routes,
      do: [{DSL, :hosted, 1, [:hosted]}, {DSL, :options, 1, [:hosted]}, {DSL, :plain, 1, [:raw]}]

    def hosted_macros, do: [{DSL, :hosted, 1}, {DSL, :options, 1}]

    def mutate(node, context) do
      case Mutare.Calls.resolved_call_to(node, DSL, :plain) do
        {:ok, :plain, [inner], rebuild} ->
          for mutation <- Analyze.collect_expression(inner, context.mutators, context),
              do: Mutation.map_node(mutation, &rebuild.(:plain, [&1]))

        _ ->
          []
      end
    end

    def host(%Call{name: :hosted, arguments: [inner]}, context) do
      mutations = Analyze.collect_expression(inner, context.mutators, context)
      wrap = fn node -> quote do: (fn value -> value end).(unquote(node)) end
      [Target.new(inner, mutations, &replace_argument/2, wrap: wrap)]
    end

    def host(%Call{name: :options, arguments: [pairs]}, _context) do
      [{key, value}, dropped] = pairs
      replacement = Mutare.AST.literal(7)

      mutants = [
        Mutation.new([{key, replacement}, dropped],
          attribution: Mutation.at(value, replacement),
          variant: :replacement,
          note: "replacement note"
        ),
        Mutation.new([{key, value}],
          attribution: Mutation.at_drop(dropped),
          variant: :drop,
          note: "drop note"
        )
      ]

      [Target.new(pairs, mutants, &replace_argument/2)]
    end

    defp replace_argument({form, meta, [_]}, replacement), do: {form, meta, [replacement]}
  end

  @mutators [Adapter, {Mutare.Mutators.Arithmetic, as: :math}]

  defp source(expression) do
    """
    defmodule Fixture do
      import Mutare.MutationOriginTest.DSL
      def run(n), do: #{expression}
    end
    """
  end

  test "collection retains the changed node, producer and label through mapping" do
    original = Sourceror.parse_string!("left + right * 2")
    mutations = Analyze.collect_expression(original, [Mutare.Mutators.Arithmetic])
    assert length(mutations) == 2

    multiplication =
      Enum.find(mutations, &(Macro.to_string(&1.attribution.original) == "right * 2"))

    assert multiplication.producer.name == :arithmetic
    assert multiplication.variant == ["/"]
    assert Macro.to_string(multiplication.attribution.mutated) == "right / 2"
    mapped = Mutation.map_node(multiplication, &{:box, [], [&1]})
    assert %{mapped | node: multiplication.node} == multiplication

    assert Enum.map(mutations, &{&1.producer, &1.node, &1.note, &1.variant}) ==
             Analyze.expression_mutations(original, [Mutare.Mutators.Arithmetic])
  end

  for expression <- [
        "hosted(n * 2)",
        "plain(n * 2)",
        "hosted(plain(hosted(n * 2)))",
        "plain(hosted(plain(n * 2)))"
      ] do
    test "patch and selected mutation agree through #{expression}" do
      [site] =
        SourcePatch.assert_patches(source(unquote(expression)), @mutators, run: [6], run: [0])

      assert site.original_code == "n * 2"
      assert site.mutated_code == "n / 2"
      assert site.mutator == :math
      assert site.variant == ["/"]
    end
  end

  for expression <- [
        "options(first: n, second: 2)",
        "hosted(plain(options(first: n, second: 2)))"
      ] do
    test "explicit replacement and deletion attribution survive #{expression}" do
      sites = SourcePatch.assert_patches(source(unquote(expression)), [Adapter], run: [3])
      assert [replace, drop] = sites

      assert {replace.original_code, replace.mutated_code, replace.note, replace.variant} ==
               {"n", "7", "replacement note", ["replacement"]}

      assert {drop.original_code, drop.mutated_code, drop.operation, drop.note, drop.variant} ==
               {"second: 2", "", :delete, "drop note", ["drop"]}
    end
  end

  test "a line ignore reaches one of two identical nested expressions" do
    src =
      source("""
      hosted({
        plain(hosted(n * 2)), # mutare:ignore[math:/]
        plain(hosted(n * 2))
      })
      """)

    Mutare.Test.isolate_selector()
    %{mutants: sites} = Mutare.transform_string(src, mutators: @mutators)
    assert [ignored, live] = sites
    assert ignored.ignored
    refute live.ignored
    assert live.line == ignored.line + 1
    assert ignored.original_code == live.original_code
    assert ignored.mutated_code == live.mutated_code
  end

  test "an infix not-in origin includes its left operand through hosting" do
    [site] =
      SourcePatch.assert_patches(
        source("hosted(n not in [1, 2])"),
        [Adapter, Mutare.Mutators.Logical],
        run: [1],
        run: [3]
      )

    assert site.original_code == "n not in [1, 2]"
    assert site.mutated_code == "n in [1, 2]"
  end

  test "a collected pipe stage keeps its selection line separate from its patch range" do
    src =
      source("""
      hosted(plain(hosted(
        n
        |> Enum.uniq()
      )))
      """)

    mutators = [Adapter, Mutare.Mutators.CallRemoval]
    [site] = SourcePatch.assert_patches(src, mutators, run: [[1, 1, 2]])
    assert site.line == site.range.start[:line] + 1
    assert site.original_code == "n\n|> Enum.uniq()"
    assert site.mutated_code == "n"

    ignored_source =
      String.replace(src, "|> Enum.uniq()", "|> Enum.uniq() # mutare:ignore[call_removal]")

    assert %{mutants: [%{ignored: true, line: line}]} =
             Mutare.transform_string(ignored_source, mutators: mutators)

    assert line == site.line
  end

  @tag :tmp_dir
  test "count and emission select the same attributed hosted line", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(
      Path.join(root, "lib/fixture.ex"),
      source("""
      hosted({
        n * 2,
        n * 2
      })
      """)
    )

    full = Schema.build(root, mutators: @mutators)
    assert [first, second] = full.sites

    focused =
      Schema.build(root,
        mutators: @mutators,
        only_lines: MapSet.new([{"lib/fixture.ex", second.line}])
      )

    assert focused.sites == [second]
    assert first.line != second.line
  end
end
