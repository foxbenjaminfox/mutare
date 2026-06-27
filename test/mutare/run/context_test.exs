defmodule Mutare.Run.ContextTest do
  use ExUnit.Case, async: true

  alias Mutare.{Options, Project}
  alias Mutare.Run.Context

  doctest Context

  describe "new/1" do
    test "splits runtime-wiring keys from configuration keys" do
      scan = fn _ -> :ok end
      context = Context.new(mutators: [:arithmetic], workers: 2, on_scan: scan)

      assert %Options{} = context.options
      assert Enum.map(context.options.mutators, & &1.name) == [:arithmetic]
      assert context.options.workers == 2
      assert context.on_scan == scan
      assert context.project == nil
    end

    test "validates configuration through Options (an unknown config key is rejected)" do
      assert_raise ArgumentError, ~r/unknown option/, fn -> Context.new(bogus: 1) end
    end

    test "wraps an existing Options with no wiring" do
      options = Options.new(workers: 3)
      context = Context.new(options)

      assert context.options == options
      assert context.project == nil
      assert context.reporter == nil
    end

    test "is idempotent on a Context" do
      context = Context.new(workers: 2)
      assert Context.new(context) == context
    end
  end

  describe "new/2" do
    test "attaches wiring to already-resolved options" do
      options = Options.new([])
      project = Project.resolve(".")
      context = Context.new(options, project: project)

      assert context.options == options
      assert context.project == project
    end

    test "accepts a keyword config as the first argument too" do
      context = Context.new([workers: 2], on_phase: fn _ -> :ok end)
      assert context.options.workers == 2
      assert is_function(context.on_phase, 1)
    end
  end

  describe "wiring validation" do
    test "each hook accepts nil or a 1-arity function" do
      for key <- [:reporter, :on_phase, :on_start, :on_scan] do
        assert Map.get(Context.new([{key, nil}]), key) == nil

        fun = fn _ -> :ok end
        assert Map.get(Context.new([{key, fun}]), key) == fun
      end
    end

    test "rejects a non-function or a wrong-arity hook" do
      assert_raise ArgumentError, ~r/:reporter must be a 1-arity function/, fn ->
        Context.new(reporter: fn -> :ok end)
      end

      assert_raise ArgumentError, ~r/:on_start must be a 1-arity function/, fn ->
        Context.new(on_start: :nope)
      end
    end

    test "rejects a non-Project :project" do
      assert_raise ArgumentError, ~r/:project must be a Mutare.Project/, fn ->
        Context.new(project: :nope)
      end
    end
  end

  describe "hook/2" do
    test "returns the bound hook, or a no-op when unset" do
      fun = fn _ -> :ok end
      context = Context.new(reporter: fun)

      assert Context.hook(context, :reporter) == fun

      noop = Context.hook(context, :on_phase)
      assert is_function(noop, 1)
      assert noop.(:anything) == :ok
    end
  end

  describe "ensure_project/2" do
    test "resolves a project from root when unset" do
      context = Context.ensure_project(Context.new([]), ".")
      assert %Project{} = context.project
    end

    test "leaves an existing project untouched" do
      project = Project.resolve(".")
      context = Context.new([], project: project)
      assert Context.ensure_project(context, "some/other/root").project == project
    end
  end
end
