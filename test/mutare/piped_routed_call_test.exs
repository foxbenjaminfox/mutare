defmodule Mutare.PipedRoutedCallTest do
  @moduledoc """
  `left |> stage(args)` is sugar for `stage(left, args)`, and a routed call is shown without the
  sugar: at every seam an adapter reads a `Mutare.CallRouting.Call` from, a piped call and its
  directly written twin are the same call, whose argument 0 can be read, routed by shape,
  rewritten, and hosted. The Site still speaks the user's spelling. Observed through
  `Mutare.Test.PipedCallProbe`.
  """
  # The probe reports by message to the process running the transform, which is the test's own.
  use ExUnit.Case, async: true
  import Mutare.Test

  alias Mutare.CallRouting.Call
  alias Mutare.Test.PipedCallProbe

  @seams [:route_arguments, :host, :mutate]

  defp source(body) do
    """
    defmodule PipedCallFixture do
      import Mutare.Test.PipedCallDSL

      def run(x, n) do
        #{body}
      end
    end
    """
  end

  defp transform(body, mutators \\ []) do
    Mutare.Transform.transform_string_with_sites(source(body),
      file: "piped_call.ex",
      mutators: mutators ++ [PipedCallProbe]
    )
  end

  # Every `Call` the probe reported during the transform, by seam, as its rendered arguments.
  defp reported do
    Stream.repeatedly(fn ->
      receive do
        {:piped_call_probe, seam, %Call{} = call} -> {seam, call}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.group_by(&elem(&1, 0), fn {_seam, call} ->
      Enum.map(call.arguments, &Macro.to_string/1)
    end)
  end

  test "a piped call and its directly written twin are shown as the same call, at every seam" do
    transform("stage(build(n + 1), x > 1)")
    direct = reported()

    transform("build(n + 1) |> stage(x > 1)")
    piped = reported()

    for seam <- @seams do
      assert direct[seam] == [["build(n + 1)", "x > 1"]], "at #{seam}"
      assert piped[seam] == direct[seam], "at #{seam}"
    end
  end

  test "a stage mid-chain holds the upstream chain as its argument 0: the call it is, below the classifier" do
    transform("n |> stage(x > 1) |> stage(x > 2) |> stage(x > 3)")
    reported = reported()

    # A classifier routes a call before `Resolve` descends its arguments, so what sits inside
    # them is source: unresolved, and as written.
    assert Enum.sort(reported.route_arguments) == [
             ["n", "x > 1"],
             ["n |> stage(x > 1)", "x > 2"],
             ["n |> stage(x > 1) |> stage(x > 2)", "x > 3"]
           ]

    # A host and a mutator read resolved code, where a pipe is the call it is sugar for at
    # every depth — an upstream stage in argument 0 included.
    for seam <- [:host, :mutate] do
      assert Enum.sort(reported[seam]) ==
               [
                 ["n", "x > 1"],
                 ["stage(n, x > 1)", "x > 2"],
                 ["stage(stage(n, x > 1), x > 2)", "x > 3"]
               ],
             "at #{seam}"
    end
  end

  test "a routed call nested in an argument reads the same however it was spelled" do
    defmodule NestedReader do
      @behaviour Mutare.Mutator
      def name, do: :nested_reader

      def mutate(node, _context) do
        with %Call{name: :stage, arguments: [upstream, _condition]} <-
               Mutare.Calls.resolved_routed_call(node),
             %Call{name: :stage, arguments: arguments} <-
               Mutare.Calls.resolved_routed_call(upstream) do
          send(self(), {:nested, Enum.map(arguments, &Macro.to_string/1)})
        end

        :skip
      end
    end

    transform("n |> stage(x > 1) |> stage(x > 2)", [NestedReader])
    assert_received {:nested, ["n", "x > 1"]}

    transform("stage(stage(n, x > 1), x > 2)", [NestedReader])
    assert_received {:nested, ["n", "x > 1"]}
  end

  describe "routing a piped source by its shape" do
    test "a computed source stays an expression, so the upstream code keeps its mutants" do
      %{sites: sites} = transform("build(n + 1) |> stage(x > 1)", [:arithmetic])

      assert [%{mutator: :arithmetic, original_code: "n + 1"} | _] = sites
    end

    test "a schema alias is held back from the families that would swap it" do
      assert %{sites: []} = transform("stage(MyApp.Post, x > 1)", [:alias])
      assert %{sites: []} = transform("MyApp.Post |> stage(x > 1)", [:alias])

      # The treatment is per call, read off the shape: over a computed value the same stage
      # leaves the position an expression, and an alias inside it is an ordinary value again.
      assert %{sites: [%{mutator: :alias, original_code: "MyApp.Post"}]} =
               transform("scope(MyApp.Post) |> stage(x > 1)", [:alias])
    end

    test "a binding declaration is left as written" do
      assert %{sites: [%{mutator: :piped_call_probe}]} =
               transform("(p in MyApp.Post) |> stage(x > 1)", [:alias])
    end
  end

  describe "a mutant that rewrites a piped call's argument 0" do
    @body "(p in n) |> stage(x > 1)"

    test "is reported over the whole pipe, in the user's spelling" do
      %{sites: [site]} = transform(@body)

      assert site.original_code == "(p in n) |> stage(x > 1)"
      assert site.mutated_code == "(p in Enum.reverse(n)) |> stage(x > 1)"
    end
  end

  test "a whole-call mutant that leaves argument 0 alone is reported at the stage" do
    source = """
    defmodule PipedCallFixture do
      import Mutare.Test.PipeSyntaxDSL

      def run(n) do
        (x in n)
        |> raw(x + 1)
      end
    end
    """

    %{sites: [site]} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "piped_call.ex",
        mutators: [Mutare.Test.PipeSyntaxMutator]
      )

    assert {site.line, site.original_code, site.mutated_code} == {6, "raw(x + 1)", "raw(0)"}
  end

  # Swaps `Enum.take/2` for `Enum.drop/2`, and labels the mutant by the arity `variant/2` was
  # shown: a stage-attributed site *reports* `Enum.take(2)`, a call one argument short, and the
  # mutator must never be handed that.
  defmodule TakeDropMutator do
    @behaviour Mutare.Mutator

    @impl true
    def name, do: :take_drop

    @impl true
    def variants, do: ["arity_1", "arity_2"]

    @impl true
    def mutate(node) do
      case Mutare.Calls.resolved_call_to(node, Enum, :take) do
        {:ok, :take, [_enum, _count] = args, rebuild} -> [rebuild.(:drop, args)]
        _other -> :skip
      end
    end

    @impl true
    def variant({_head, _meta, args}, _mutated), do: "arity_#{length(args)}"
  end

  test "variant/2 classifies the call the mutator was offered, not the written stage" do
    labels = fn body ->
      source = "defmodule TakeFixture do\n  def run(xs), do: #{body}\nend\n"

      %{sites: [site]} =
        Mutare.Transform.transform_string_with_sites(source, mutators: [TakeDropMutator])

      {site.original_code, site.mutated_code, site.variant}
    end

    assert labels.("Enum.take(xs, 2)") == {"Enum.take(xs, 2)", "Enum.drop(xs, 2)", ["arity_2"]}
    assert labels.("xs |> Enum.take(2)") == {"Enum.take(2)", "Enum.drop(2)", ["arity_2"]}
  end

  test "a piped call resolves as the call it is, at the root of an offered node and beneath it" do
    # The operands of a node a mutator is offered are resolved code too: a mutator asking
    # whether an operand is a call to `Enum.count/1` gets one answer for both spellings.
    defmodule OperandReader do
      @behaviour Mutare.Mutator
      def name, do: :operand_reader

      def mutate({:+, _meta, operands}) do
        resolved =
          for operand <- operands do
            {module, fun, arguments, _rebuild} = Mutare.Calls.resolved_call(operand)
            {module, fun, length(arguments)}
          end

        send(self(), {:operands, resolved})
        []
      end

      def mutate(_node), do: []
    end

    Mutare.Transform.transform_string_with_sites(
      """
      defmodule OperandFixture do
        def run(xs, ys), do: (xs |> Enum.count()) + Enum.count(ys)
      end
      """,
      file: "operand.ex",
      mutators: [OperandReader]
    )

    assert_received {:operands, [{[:Enum], :count, 1}, {[:Enum], :count, 1}]}

    assert {[:Enum], :take, [_xs, _count], _rebuild} =
             "xs |> Enum.take(2)"
             |> Sourceror.parse_string!()
             |> Mutare.Transform.Resolve.annotate()
             |> Mutare.Transform.Calls.resolved_call()
  end

  test "a replacement of the whole expression covers the whole pipe" do
    source = """
    defmodule PipedCallFixture do
      import Mutare.Test.PipeSyntaxDSL

      def run(n) do
        (x in n)
        |> raw(x + 1)
      end
    end
    """

    %{sites: sites} =
      Mutare.Transform.transform_string_with_sites(source,
        file: "piped_call.ex",
        mutators: [:return_value]
      )

    assert [_ | _] = sites

    for site <- sites do
      assert {site.line, site.original_code} == {5, "(x in n)\n|> raw(x + 1)"}
    end
  end

  test "argument 0 of a piped call can be routed :hosted" do
    defmodule HostedSource do
      @behaviour Mutare.Mutator
      @behaviour Mutare.CallRouting
      @behaviour Mutare.Mutator.MacroHost

      def name, do: :hosted_source
      def call_routes, do: [{Mutare.Test.PipedCallDSL, :stage, 2, [:hosted, :raw]}]
      def hosted_macros, do: [{Mutare.Test.PipedCallDSL, :stage, 2}]

      def host(%Call{arguments: [source, _condition]}, _context) do
        send(self(), {:hosted_source, Macro.to_string(source)})
        []
      end
    end

    Mutare.Transform.transform_string_with_sites(source("n |> stage(x > 1)"),
      file: "piped_call.ex",
      mutators: [HostedSource]
    )

    assert_received {:hosted_source, "n"}
  end

  # `Resolve` rewrites these pipes like any other; what the compiler — and so any macro handed
  # the region — is given is the source `Render` spells back, which is the pipe.
  describe "code Mutare does not analyze keeps the pipe it was written with" do
    # `_ = 41` gives the function a mutant of its own, so it is re-rendered whatever the region
    # under test contributes — an unmutated file is returned as source, which would prove nothing.
    defp rendered(body, opts) do
      result =
        Mutare.Transform.transform_string_with_sites(
          source("_ = 41\n    " <> body),
          [file: "piped_call.ex", mutators: [PipedCallProbe, :integer]] ++ opts
        )

      assert Enum.any?(result.sites, &(&1.original_code == "41"))
      result.metamutant
    end

    test "inside a :raw argument" do
      emitted =
        rendered("keep(n |> stage(x > 1), 5)",
          call_routes: [{:*, :keep, 2, [:raw, :expression]}]
        )

      assert emitted =~ "n |> stage(x > 1)"
      refute emitted =~ "stage(n, x > 1)"
    end

    test "inside a :skip'ped call" do
      emitted = rendered("keep(n |> stage(x > 1), 5)", call_routes: [{:*, :keep, 2, :skip}])

      assert emitted =~ "keep(n |> stage(x > 1), 5)"
    end

    test "inside a quote" do
      emitted = rendered("quote(do: n |> stage(x > 1))", [])

      assert emitted =~ "n |> stage(x > 1)"
      refute emitted =~ "stage(n, x > 1)"
    end

    test "and where it is analyzed, the metamutant spells the direct call as the pipe again" do
      emitted = rendered("keep(n |> stage(x > 1), 5)", [])

      assert emitted =~ ~r/n\s*\|> stage\(/
      refute emitted =~ "stage(n,"
    end
  end
end

defmodule Mutare.PipedRoutedCallRunTest do
  # Runs compiled metamutants under a selected mutant. `with_active_mutant/2` sets the VM-wide
  # selector, so these live apart from the pure transform tests above, which stay `async: true`.
  use ExUnit.Case, async: false
  import Mutare.Test

  @source """
  defmodule PipedCallFixture do
    import Mutare.Test.PipedCallDSL

    def run(x, n) do
      (p in n) |> stage(x > 1)
    end
  end
  """

  test "a mutant that rewrites a piped call's argument 0 is delivered as syntax" do
    {[module], [site]} = compile_metamutant(@source, [Mutare.Test.PipedCallProbe])

    assert module.run(2, [1, 2]) == [1, 2]
    assert with_active_mutant(site.id, fn -> module.run(2, [1, 2]) end) == [2, 1]
  end
end
