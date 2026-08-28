defmodule Mutare.Runner.AppGraphTest do
  use ExUnit.Case, async: true

  alias Mutare.Project
  alias Mutare.Runner.AppGraph

  @names [:core, :web, :solo]

  describe "parse/2 — the `mix eval` output contract" do
    test "keeps the umbrella apps' edges, dropping Hex deps and other nodes" do
      output = """
      ==> core
      warning: something the target printed
      mutare-dep core jason
      mutare-dep web core plug
      mutare-dep solo
      mutare-dep jason
      mutare-dep plug mime
      mutare-dep mutare_support
      mutare-dep-end
      """

      assert AppGraph.parse(output, @names) == {:ok, %{core: [], web: [:core], solo: []}}
    end

    test "is :error without the end marker (truncated output)" do
      output = "mutare-dep core\nmutare-dep web core\nmutare-dep solo\n"
      assert AppGraph.parse(output, @names) == :error
    end

    test "is :error when an umbrella app is missing from the tree" do
      output = "mutare-dep core\nmutare-dep web core\nmutare-dep-end\n"
      assert AppGraph.parse(output, @names) == :error
    end

    test "never mints atoms from subprocess output" do
      novel = "zz_#{System.unique_integer([:positive])}_dep"
      output = "mutare-dep core #{novel}\nmutare-dep web\nmutare-dep solo\nmutare-dep-end\n"

      assert AppGraph.parse(output, @names) == {:ok, %{core: [], web: [], solo: []}}
      assert_raise ArgumentError, fn -> String.to_existing_atom(novel) end
    end
  end

  describe "read/2" do
    test "a single (non-umbrella) project is an empty graph, without running mix" do
      assert AppGraph.read(%Project{umbrella?: false}, "/nonexistent/sandbox") == {:ok, %{}}
    end

    # One real `mix eval` against a generated (uncompiled) umbrella: the declared
    # graph must carry the `runtime: false` edge the compiled `.app` would omit.
    @tag :runner
    @tag timeout: 120_000
    test "reads the declared graph from an umbrella, runtime: false edges included" do
      over =
        Mutare.Test.Umbrella.build(:graph_umbrella, %{
          core: %{files: %{"lib/core.ex" => "defmodule Core do\nend\n"}},
          web: %{
            deps: [{:core, runtime: false}],
            files: %{"lib/web.ex" => "defmodule Web do\nend\n"}
          },
          solo: %{files: %{"lib/solo.ex" => "defmodule Solo do\nend\n"}}
        })

      project = Project.resolve(over.umbrella)

      assert AppGraph.read(project, over.umbrella) == {:ok, %{core: [], web: [:core], solo: []}}
    end
  end
end
