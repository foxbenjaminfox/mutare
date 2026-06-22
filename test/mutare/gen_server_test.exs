defmodule Mutare.GenServerTest do
  @moduledoc """
  The behaviour-gated GenServer return mutator: inside a module implementing
  `GenServer`, it swaps a callback's return tuple for another *valid* OTP return
  (`:reply` → `:noreply`, `:noreply` ↔ `:stop`, …). Inert in non-GenServer modules.
  """
  use ExUnit.Case, async: true

  alias Mutare.Mutators.GenServer, as: GS

  # `{original_code, mutated_code}` for every `:genserver` site, isolating the family
  # (clause-drop is structural and still appears, so filter it out).
  defp genserver_mutations(source) do
    {_meta, sites, _next} = Mutare.transform_string(source, mutators: [GS])

    for s <- sites, s.mutator == :genserver, do: {s.original_code, s.mutated_code}
  end

  # Wrap a body of `handle_*` clauses in a `use GenServer` module.
  defp server(body), do: "defmodule S do\n  use GenServer\n\n#{body}\nend\n"

  describe "the return swap table (gated on @behaviour GenServer)" do
    test "handle_call {:reply, reply, state} drops the reply -> :noreply" do
      assert genserver_mutations(server("  def handle_call(:g, _f, s), do: {:reply, s, s}")) ==
               [{"{:reply, s, s}", "{:noreply, s}"}]
    end

    test "handle_call {:reply, reply, state, action} keeps the action" do
      assert genserver_mutations(
               server("  def handle_call(:g, _f, s), do: {:reply, s, s, :hibernate}")
             ) == [{"{:reply, s, s, :hibernate}", "{:noreply, s, :hibernate}"}]
    end

    test "{:noreply, state} -> {:stop, :normal, state}" do
      assert genserver_mutations(server("  def handle_cast(_m, s), do: {:noreply, s}")) ==
               [{"{:noreply, s}", "{:stop, :normal, s}"}]
    end

    test "{:noreply, state, action} -> {:stop, :normal, state} (drops the action)" do
      assert genserver_mutations(
               server("  def handle_info(_m, s), do: {:noreply, s, {:continue, :go}}")
             ) == [{"{:noreply, s, {:continue, :go}}", "{:stop, :normal, s}"}]
    end

    test "{:stop, reason, state} -> {:noreply, state}" do
      assert genserver_mutations(server("  def handle_cast(_m, s), do: {:stop, :shutdown, s}")) ==
               [{"{:stop, :shutdown, s}", "{:noreply, s}"}]
    end

    test "handle_call {:stop, reason, reply, state} -> {:reply, reply, state}" do
      assert genserver_mutations(
               server("  def handle_call(:g, _f, s), do: {:stop, :normal, :ok, s}")
             ) ==
               [{"{:stop, :normal, :ok, s}", "{:reply, :ok, s}"}]
    end

    test "a multi-statement body's 2-tuple tail is still mutated" do
      body = """
        def handle_cast(_m, s) do
          x = s + 1
          {:noreply, x}
        end\
      """

      assert genserver_mutations(server(body)) == [{"{:noreply, x}", "{:stop, :normal, x}"}]
    end
  end

  describe "scope" do
    test "fires on a directly-declared @behaviour GenServer (not just `use`)" do
      source = """
      defmodule S do
        @behaviour GenServer
        def handle_call(:g, _f, s), do: {:reply, s, s}
      end
      """

      assert genserver_mutations(source) == [{"{:reply, s, s}", "{:noreply, s}"}]
    end

    test "does NOT fire in a non-GenServer module" do
      source = """
      defmodule Plain do
        def handle_call(:g, _f, s), do: {:reply, s, s}
      end
      """

      assert genserver_mutations(source) == []
    end

    test "leaves non-callback return shapes (e.g. {:ok, x}) untouched" do
      assert genserver_mutations(server("  def init(s), do: {:ok, s}")) == []
    end

    test "leaves a 2-tuple {:stop, reason} (an init shape) untouched" do
      assert genserver_mutations(server("  def init(_), do: {:stop, :bad}")) == []
    end
  end

  describe "compile safety" do
    test "every embedded mutant is a valid GenServer return that compiles" do
      source =
        server("""
          def handle_call(:a, _f, s), do: {:reply, s, s}
          def handle_call(:b, _f, s), do: {:noreply, s}
          def handle_call(:c, _f, s), do: {:stop, :normal, :ok, s}
          def handle_cast(_m, s), do: {:noreply, s, :hibernate}
          def handle_info(_m, s), do: {:stop, :shutdown, s}\
        """)

      {metamutant, sites, _} = Mutare.transform_string(source, mutators: [GS])
      assert Enum.count(sites, &(&1.mutator == :genserver)) == 5
      assert [{S, _binary}] = Code.compile_string(metamutant)
    after
      :code.purge(S)
      :code.delete(S)
    end
  end
end
