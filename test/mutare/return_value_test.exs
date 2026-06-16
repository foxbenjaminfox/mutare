defmodule Mutare.ReturnValueTest do
  @moduledoc """
  Return-value mutation: replace a `def`/`defp` clause's tail expression with a
  constant. Structural (the transform names the tail), delivered by the in-place
  selector, on by default.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Mutare.Mutators.ReturnValue
  alias Mutare.{Selector, Site}

  @compile {:no_warn_undefined, Mutare.ReturnValueFixture}

  # Isolate the family: with only ReturnValue enabled, the *only* operator-free
  # sites are return mutants (clause-drop is structural and still appears for
  # multi-clause groups, so filter to :return_value when a group lifts).
  @only [ReturnValue]

  # One compile for the runtime-semantics tests below; behavior then changes only
  # by flipping `:persistent_term` (the central bet). The other describe blocks
  # don't use `sites` — they call `return_sites/1` directly.
  @runtime_source """
  defmodule Mutare.ReturnValueFixture do
    def add(a, b), do: a + b
    def tag, do: :ok
  end
  """

  setup_all do
    {metamutant, sites, _} = Mutare.transform_string(@runtime_source, mutators: @only)
    [{_module, _binary}] = Code.compile_string(metamutant)
    %{sites: sites}
  end

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  # Return-value sites for a one-line function body `def f(a, b), do: <tail>`.
  defp return_sites(tail) do
    {_meta, sites, _} =
      Mutare.transform_string("defmodule T do\n  def f(a, b), do: #{tail}\nend\n",
        mutators: @only
      )

    Enum.filter(sites, &(&1.mutator == :return_value))
  end

  defp mutated_codes(tail), do: tail |> return_sites() |> Enum.map(& &1.mutated_code)

  describe "replacements/1 (which constant, and which tails are skipped)" do
    test "a computed numeric tail becomes 0" do
      assert mutated_codes("a + b") == ["0"]
      assert mutated_codes("a * b") == ["0"]
      assert mutated_codes("div(a, b)") == ["0"]
      assert mutated_codes("-a") == ["0"]
    end

    test "a string concatenation becomes \"\"" do
      assert mutated_codes(~s("x" <> b)) == [~s("")]
    end

    test "a list concatenation becomes []" do
      assert mutated_codes("a ++ b") == ["[]"]
      assert mutated_codes("a -- b") == ["[]"]
    end

    test "a variable, call, tuple, map, or atom tail becomes nil" do
      assert mutated_codes("a") == ["nil"]
      assert mutated_codes("foo(a)") == ["nil"]
      assert mutated_codes("{:ok, a}") == ["nil"]
      assert mutated_codes("%{a: a}") == ["nil"]
      assert mutated_codes(":ok") == ["nil"]
    end

    test "a boolean-valued tail is skipped (Conditional already forces true/false)" do
      assert return_sites("a > b") == []
      assert return_sites("a and b") == []
      assert return_sites("a in b") == []
      assert return_sites("not a") == []
    end

    test "a literal a value family already mutates is skipped" do
      assert return_sites("5") == []
      assert return_sites("1.5") == []
      assert return_sites(~s("hi")) == []
      assert return_sites("[1, 2]") == []
      assert return_sites("true") == []
    end

    test "a nil tail is skipped (replacing nil with nil is equivalent)" do
      assert return_sites("nil") == []
    end

    test "a quote-block tail is skipped (macro AST is left whole)" do
      assert return_sites("quote(do: x + 1)") == []
    end

    test "an empty-list / empty-string tail is its own redundant literal, skipped" do
      assert return_sites("[]") == []
      assert return_sites(~s("")) == []
    end

    test "mutate/1 never fires as a node mutator — the family is structural" do
      assert ReturnValue.mutate({:+, [], [1, 2]}) == :skip
      assert ReturnValue.mutate({:__block__, [], [:ok]}) == :skip
      assert ReturnValue.name() == :return_value
    end
  end

  describe "the recorded Site" do
    test "is :return_value, :in_place, operator-free, with the right diff and line" do
      [site] = return_sites("a + b")

      assert %Site{
               mutator: :return_value,
               kind: :in_place,
               operation: :replace,
               original_op: nil,
               mutated_op: nil,
               original_code: "a + b",
               mutated_code: "0",
               line: 2
             } = site

      assert Site.describe(site) == "return_value  a + b → 0"
    end
  end

  describe "which positions are targeted" do
    test "only the tail of a multi-statement body, not intermediate statements" do
      source = """
      defmodule T do
        def f(x) do
          y = x + 1
          y * 2
        end
      end
      """

      {_meta, sites, _} = Mutare.transform_string(source, mutators: @only)
      returns = Enum.filter(sites, &(&1.mutator == :return_value))

      # `y = x + 1` (line 3) is not the tail; only `y * 2` (line 4) is.
      assert [%Site{line: 4, original_code: "y * 2", mutated_code: "0"}] = returns
    end

    test "every clause of a lifted (guarded) group returns from its __orig copy" do
      source = """
      defmodule T do
        def g(n) when n > 0, do: n + 1
        def g(_), do: :zero
      end
      """

      {meta, sites, _} =
        with_log(fn -> Mutare.transform_string(source, mutators: @only) end) |> elem(0)

      returns = Enum.filter(sites, &(&1.mutator == :return_value))

      # Both clause tails get a return mutant (n + 1 → 0, :zero → nil), and they
      # live in the lifted `__orig` copy alongside the in-place selectors.
      assert MapSet.new(returns, & &1.mutated_code) == MapSet.new(["0", "nil"])
      assert meta =~ ~r/defp __mutare_g_1_g\d+_orig/
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "an operator swap and a return mutant share one selector at the tail node" do
      # `a + b` is both an arithmetic site and a return-value site: one selector
      # `case` hosts both mutant clauses (a - b, and 0).
      {meta, sites, _} =
        Mutare.transform_string("defmodule T do\n  def f(a, b), do: a + b\nend\n",
          mutators: [Mutare.Mutators.Arithmetic, ReturnValue]
        )

      assert Enum.map(sites, & &1.mutator) == [:arithmetic, :return_value]
      # one selector subject only (both mutants live under it)
      assert meta |> String.split(":persistent_term.get(:mutare_active") |> length() == 2
      assert {:ok, _} = Code.string_to_quoted(meta)
    end
  end

  describe "selection and ignore" do
    test "off when not in the :mutators list" do
      {_meta, sites, _} =
        Mutare.transform_string("defmodule T do\n  def f(a, b), do: a + b\nend\n",
          mutators: [Mutare.Mutators.Arithmetic]
        )

      refute Enum.any?(sites, &(&1.mutator == :return_value))
    end

    test "on by default (part of Mutare.Mutators.all/0)" do
      assert ReturnValue in Mutare.Mutators.all()

      {_meta, sites, _} =
        Mutare.transform_string("defmodule T do\n  def f(a, b), do: a + b\nend\n")

      assert Enum.any?(sites, &(&1.mutator == :return_value))
    end

    test "# mutare:ignore[return_value] suppresses only the return mutant" do
      source = """
      defmodule T do
        def f(a, b), do: a + b   # mutare:ignore[return_value] tested elsewhere
      end
      """

      {_meta, sites, _} =
        Mutare.transform_string(source, mutators: [Mutare.Mutators.Arithmetic, ReturnValue])

      by = Map.new(sites, &{&1.mutator, &1.ignored})
      assert by[:return_value] == true
      assert by[:arithmetic] == false
    end
  end

  describe "runtime semantics (one compile, flip the selector)" do
    test "baseline returns the real value", %{sites: _} do
      assert Mutare.ReturnValueFixture.add(2, 3) == 5
      assert Mutare.ReturnValueFixture.tag() == :ok
    end

    test "the return mutant replaces add/2's result with 0", %{sites: sites} do
      site = Enum.find(sites, &(&1.original_code == "a + b"))
      Selector.put(site.id)
      assert Mutare.ReturnValueFixture.add(2, 3) == 0
      # a sibling function is unaffected
      assert Mutare.ReturnValueFixture.tag() == :ok
    end

    test "the return mutant replaces tag/0's :ok with nil", %{sites: sites} do
      site = Enum.find(sites, &(&1.original_code == ":ok"))
      Selector.put(site.id)
      assert Mutare.ReturnValueFixture.tag() == nil
    end
  end
end
