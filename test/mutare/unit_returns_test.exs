defmodule Mutare.UnitReturnsTest do
  @moduledoc """
  Unit-returning functions (`Mutare.Transform.UnitReturns`): a function whose every return
  path, across all its clauses, is literally `:ok` or `nil` returns no data, so its tails are
  not value positions — no return-value constant (`ReturnValue`) and no `:ok → :error` swap
  (`ConventionAtom`) there. The classification is syntactic and one-sided: it can *miss* a
  unit function, never silence a data-returning one.
  """
  use ExUnit.Case, async: true

  alias Mutare.Mutators.{AtomLiteral, ConventionAtom, ReturnValue}

  @compile {:no_warn_undefined, Mutare.UnitReturnsFixture}

  # The three families that can touch an atom tail. Nothing else is enabled, so every site
  # below is one of: a return constant, a convention swap, or an atom sentinel.
  @families [ReturnValue, ConventionAtom, AtomLiteral]

  defp sites(source) do
    %{sites: sites} = Mutare.Transform.transform_string_with_sites(source, mutators: @families)
    Enum.map(sites, &{&1.mutator, &1.line, &1.original_code, &1.mutated_code})
  end

  defp t(body), do: "defmodule T do\n#{body}\nend\n"

  # The mutants minted on an `:ok` — `{mutator, mutated_code}` pairs, so a test reads as "which
  # families fired on the `:ok`".
  defp on_ok(source),
    do: for({m, _line, ":ok", mutated} <- sites(source), do: {m, mutated})

  # What a data-carrying `:ok` tail gets: the swap plus the contrasting return pair.
  @ok_mutated [convention: ":error", return_value: "nil", return_value: ":mutare"]

  describe "a unit-returning function's tails are not value positions" do
    test "a bare :ok body gets neither a return constant nor a convention swap" do
      assert sites(t("  def f, do: :ok")) == []
      assert sites(t("  defp f, do: :ok")) == []
    end

    test "a side-effect helper ending in :ok" do
      assert sites(t("  def f(x) do\n    IO.puts(x)\n    :ok\n  end")) == []
    end

    test "nil is the other unit spelling, and mixing the two still counts" do
      # An else-less `if` around a side effect returns `:ok | nil`.
      assert sites(t("  def f(x) do\n    if x do\n      IO.puts(x)\n      :ok\n    end\n  end")) ==
               []

      assert sites(t("  def f(x), do: if(x, do: :ok, else: nil)")) == []
    end

    test "every branch of a tail case" do
      src = t("  def f(x) do\n    case x do\n      1 -> :ok\n      _ -> :ok\n    end\n  end")
      assert sites(src) == []
    end

    test "every clause of a multi-clause function" do
      assert sites(t("  def f(1), do: :ok\n  def f(_), do: :ok")) == []
    end

    test "a bodiless default head defines no return path" do
      assert sites(t("  def f(x \\\\ 1)\n  def f(_x), do: :ok")) == []
    end

    test "rescue paths, block and keyword form alike" do
      block = t("  def f(x) do\n    IO.puts(x)\n    :ok\n  rescue\n    _ -> :ok\n  end")
      assert sites(block) == []
      assert sites(t("  def f(_x), do: :ok, rescue: (_ -> :ok)")) == []
    end

    test "a with whose else is present and unit" do
      src =
        t(
          "  def f(x) do\n    with 1 <- x do\n      :ok\n    else\n      _ -> :ok\n    end\n  end"
        )

      assert sites(src) == []
    end

    test "a tail that never returns is no return path: :ok-or-raise is unit" do
      # The `:ok` is not offered; the raising tail is not stamped and keeps its own return pair
      # (`raise … → nil` asks whether the error path is tested).
      src =
        t(
          "  def f(x) do\n    case x do\n      nil -> :ok\n      _ -> raise \"bad\"\n    end\n  end"
        )

      assert on_ok(src) == []

      assert Enum.map(sites(src), &{elem(&1, 0), elem(&1, 2)}) ==
               [return_value: ~s(raise "bad"), return_value: ~s(raise "bad")]

      for tail <- [
            "raise(\"bad\", [])",
            "reraise(x, [])",
            "throw(1)",
            "exit(1)",
            "Kernel.exit(1)",
            ":erlang.error(1)",
            ":erlang.throw(1)",
            ":erlang.exit(1)"
          ] do
        assert on_ok(t("  def f(x), do: if(x, do: :ok, else: #{tail})")) == [], tail
      end
    end

    test "a raise shadowed by another import, or :erlang.exit/2, is an ordinary call" do
      shadowed =
        t(
          "  import Kernel, except: [raise: 1]\n  import Other, only: [raise: 1]\n  def f(x), do: if(x, do: :ok, else: raise(x))"
        )

      assert on_ok(shadowed) == @ok_mutated
      # `:erlang.exit/2` signals another process and returns `true`.
      assert on_ok(t("  def f(x), do: if(x, do: :ok, else: :erlang.exit(x, 1))")) == @ok_mutated
    end

    test "inside a defimpl body" do
      assert sites("defimpl Inspect, for: T do\n  def inspect(_, _), do: :ok\nend\n") == []
    end

    test "an anonymous function whose every clause returns :ok" do
      # The enclosing def's tail is the `Enum.each` call — a call tail is not classified, so
      # it keeps its own return pair — but the closure's `:ok` is unit.
      src = t("  def f(xs), do: Enum.each(xs, fn x -> IO.puts(x); :ok end)")
      assert on_ok(src) == []
      assert Enum.map(sites(src), &elem(&1, 0)) == [:return_value, :return_value]
    end
  end

  describe "stays a value position" do
    test ":ok beside a data path carries the success bit" do
      assert on_ok(t("  def f(x), do: if(x, do: :ok, else: {:error, :bad})")) == @ok_mutated
    end

    test "a sibling clause returning data disqualifies the group" do
      assert on_ok(t("  def f(1), do: :ok\n  def f(_), do: :pending")) == @ok_mutated
    end

    test "an else-less with has an implicit return path" do
      # The non-matching value passes through, so the function is not unit — while the
      # return mutator still targets the `do` tail, the one path a constant can replace.
      assert on_ok(t("  def f(x), do: with(1 <- x, do: :ok)")) == @ok_mutated
    end

    test "an else consumes the do value, so its tail is not a return path" do
      # The `else` clauses match on the `do` value and *their* tails are what the caller gets.
      # Swapping the consumed `:ok` picks a different clause — a real behaviour change under an
      # unchanged (unit) return — so it stays mutable while the `else` tails do not.
      body = "if x, do: :ok, else: nil"
      arms = "      :ok -> IO.puts(1)\n        :ok\n      nil -> IO.puts(2)\n        :ok"

      for src <- [
            t("  def f(x) do\n    try do\n      #{body}\n    else\n#{arms}\n    end\n  end"),
            t("  def f(x) do\n    #{body}\n  else\n#{arms}\n  end")
          ] do
        assert on_ok(src) == @ok_mutated, src
      end
    end

    test "a defdelegate sibling can return anything, so it disqualifies the group" do
      # The delegate expands to a `def` clause of the same signature that no static scan sees.
      assert on_ok(t("  def f(:valid), do: :ok\n  defdelegate f(x), to: Other")) == @ok_mutated
      # …and only that signature: a delegate at another arity leaves the group alone.
      assert on_ok(t("  def f(:valid), do: :ok\n  defdelegate f(x, y), to: Other")) == []

      # The deprecated list form still compiles, and Sourceror wraps the list literal in a
      # single-child `:__block__` — unwrapped, or the whole list reads as one head `__block__/1`
      # and the signatures it really defines go unseen.
      assert on_ok(t("  def f(:valid), do: :ok\n  defdelegate [f(x), g(y)], to: Other")) ==
               @ok_mutated
    end

    test "a name at an arity its special form does not claim is an ordinary call" do
      # Exactly one arity per name is the real construct; at any other, the same name is a local
      # function that merely takes a trailing `do:` keyword, and that `:ok` is an argument.
      for {form, arity} <- [case: 1, cond: 2, if: 3, unless: 1, try: 2, receive: 2] do
        params = Enum.map_join(1..arity, ", ", &"a#{&1}")

        args =
          if arity == 1,
            do: "do: :ok",
            else: Enum.map_join(1..(arity - 1), ", ", &"#{&1}") <> ", do: :ok"

        src = t("  def #{form}(#{params}), do: {#{params}}\n  def f, do: #{form}(#{args})")
        assert {:convention, ":error"} in on_ok(src), "#{form}/#{arity}"
      end
    end

    test "a displaced if is somebody else's macro, and opaque" do
      # `import Kernel, except: [if: 2]` puts an `if/2` in scope that need not return a branch
      # value at all, so its `do:` payload is not classifiable as a return path.
      # Both readings of "not Kernel's": a replacement the resolver can name, and one it can't.
      for replacement <- ["import Other, only: [if: 2]", "import Other"] do
        src =
          t("  import Kernel, except: [if: 2]\n  #{replacement}\n  def f(x), do: if(x, do: :ok)")

        assert on_ok(src) == @ok_mutated, replacement
      end

      # The real `Kernel.if/2` next door still classifies.
      assert on_ok(t("  def f(x), do: if(x, do: :ok)")) == []
    end

    test "a local if at another arity needs no displacement to be reached" do
      # `if/1` and `if/3` don't collide with `Kernel.if/2`, so they compile with no
      # `import Kernel, except:` and carry no stamp — but `if(do: :ok)` really does call them.
      # (A local `if/2` is a hard "conflicts with local function" error, so arity two is safe.)
      one = t("  def if(opts), do: Keyword.fetch!(opts, :do) == :ok\n  def f, do: if(do: :ok)")
      assert {:return_value, ":mutare"} in on_ok(one)

      three = t("  def if(a, b, c), do: {a, b, c}\n  def f, do: if(1, [do: :ok], 3)")
      assert on_ok(three) == [convention: ":error"]
    end

    test "a data atom, and :ok inside data" do
      assert Enum.map(sites(t("  def f, do: :pending")), &elem(&1, 0)) ==
               [:atom, :return_value]

      assert on_ok(t("  def f, do: {:ok, 1}")) == [convention: ":error"]
    end

    test "a call tail is not classified (a known miss)" do
      assert Enum.map(sites(t("  def f(x), do: IO.puts(x)")), &elem(&1, 0)) ==
               [:return_value, :return_value]
    end

    test "an :ok off the tail of a unit function is an ordinary value" do
      src = t("  def f do\n    x = :ok\n    IO.puts(x)\n    :ok\n  end")
      assert sites(src) == [{:convention, 3, ":ok", ":error"}]
    end

    test "an anonymous function with a data path" do
      src = t("  def f(g), do: g.(fn x -> if x, do: :ok, else: :error end)")
      assert on_ok(src) == @ok_mutated
    end
  end

  describe "a behaviour callback's return is the contract's, not the body's" do
    test "a callback of a declared, loadable behaviour keeps its :ok mutants" do
      # `terminate/2` is unit in fact, but the tool can't tell it from a callback whose lone
      # `:ok` is one contract outcome among several (an `Oban.Worker.perform/1`); the
      # exemption errs towards offering.
      src = t("  @behaviour GenServer\n  def terminate(_reason, _state), do: :ok")
      assert on_ok(src) == @ok_mutated
    end

    test "a custom behaviour, and a non-callback sibling stays unit" do
      src =
        t(
          "  @behaviour Mutare.Test.SampleBehaviour\n  def handle(_msg), do: :ok\n  defp helper, do: :ok"
        )

      # Every site sits on the callback's line (3 — `t/1` adds the `defmodule` line); the
      # `helper` on line 4 draws none.
      assert Enum.all?(sites(src), &(elem(&1, 1) == 3))
      assert on_ok(src) == @ok_mutated
    end

    test "a use-injected behaviour counts" do
      src = t("  use Mutare.Test.SampleUsing\n  def handle(_msg), do: :ok")
      assert on_ok(src) == @ok_mutated
    end

    test "@impl marks a callback even when the behaviour can't be loaded" do
      src = t("  @behaviour Nope.Unloadable\n  @impl true\n  def go, do: :ok")
      assert on_ok(src) == @ok_mutated

      src = t("  @behaviour Nope.Unloadable\n  @impl Nope.Unloadable\n  def go, do: :ok")
      assert on_ok(src) == @ok_mutated
    end

    test "@impl on the first clause covers the whole group" do
      src =
        t(
          "  @behaviour Nope.Unloadable\n  @impl true\n  def go(1), do: :ok\n  def go(_), do: :ok"
        )

      assert length(on_ok(src)) == 2 * length(@ok_mutated)
    end

    test "@impl false is the author saying it is not a callback" do
      assert sites(t("  @behaviour Nope.Unloadable\n  @impl false\n  def go, do: :ok")) == []
    end

    test "an unloadable behaviour without @impl exempts nothing" do
      assert sites(t("  @behaviour Nope.Unloadable\n  def go, do: :ok")) == []
    end
  end

  describe "static visibility" do
    test "a nested module is classified on its own, both ways round" do
      outer_unit = t("  def f, do: :ok\n  defmodule Inner do\n    def f, do: :pending\n  end")
      assert on_ok(outer_unit) == []
      assert Enum.map(sites(outer_unit), &elem(&1, 1)) == [4, 4]

      inner_unit = t("  def f, do: :pending\n  defmodule Inner do\n    def f, do: :ok\n  end")
      assert on_ok(inner_unit) == []
      assert Enum.map(sites(inner_unit), &elem(&1, 1)) == [2, 2]
    end

    test "clauses defined under a module-level if/for are grouped with their siblings" do
      # Only scope boundaries prune the walk, so a conditional definition joins the group and
      # its data-returning branch disqualifies it.
      src = t("  if true do\n    def f, do: :ok\n  else\n    def f, do: :pending\n  end")
      assert on_ok(src) == @ok_mutated

      # …while static heads generated by a `for` are ordinary clauses.
      assert sites(t("  for n <- [:a, :b] do\n    def f(unquote(n)), do: :ok\n  end")) == []
    end

    test "a dynamic head leaves the whole module unclassified" do
      src = t("  for n <- [:g] do\n    def unquote(n)(), do: 1\n  end\n  def f, do: :ok")
      assert on_ok(src) == @ok_mutated

      # `def unquote(head)` splices the *whole* head — the same hole in its other spelling,
      # and here the invisible clause is a data-returning sibling of the `:ok` one.
      whole_head =
        t(
          "  head = quote(do: f(:invalid))\n  def f(:valid), do: :ok\n" <>
            "  def unquote(head), do: {:error, :invalid}"
        )

      assert on_ok(whole_head) == @ok_mutated

      # A `defdelegate` whose head is dynamic forfeits the module for the same reason.
      assert on_ok(
               t(
                 "  name = :f\n  def f(:valid), do: :ok\n  defdelegate unquote(name)(x), to: Other"
               )
             ) ==
               @ok_mutated
    end

    test "a quoted clause blocks its signature: its body carries no resolution" do
      # `Module.eval_quoted(__MODULE__, …)` really can inject these beside the visible clauses
      # (the one metaprogramming route the planner also refuses to prune), but `Resolve` stamps
      # nothing inside a `quote` — quoted code resolves where it is *invoked*. So `raise("bad")`
      # there may be the local `raise/1`, which returns data, and the head is all this pass can
      # trust. Blocked, so the visible `:ok` keeps its mutants.
      quoted = fn body ->
        t(
          "  def raise(msg), do: {:error, msg}\n  def f(:good), do: :ok\n" <>
            "  Code.eval_quoted(quote do\n    import Kernel, except: [raise: 1]\n" <>
            "    def f(:bad), do: #{body}\n  end, [], __ENV__)"
        )
      end

      assert on_ok(quoted.(~s|raise("bad")|)) == @ok_mutated
      # …and blocking is unconditional: even a quoted body that *reads* unit blocks the group.
      assert on_ok(quoted.(":ok")) == @ok_mutated
    end

    test "a displaced defmodule is not a scope boundary" do
      # `import Kernel, except: [defmodule: 2]` puts somebody else's `defmodule/2` in scope, and
      # it may splice its block straight into the caller — so the defs inside are this module's
      # siblings, not another module's.
      src =
        t(
          "  import Kernel, except: [defmodule: 2]\n  def f(:good), do: :ok\n" <>
            "  defmodule Inner do\n    def f(:bad), do: :pending\n  end"
        )

      assert on_ok(src) == @ok_mutated

      # The real `Kernel.defmodule/2` next door still opens its own scope.
      assert on_ok(t("  def f, do: :ok\n  defmodule Inner do\n    def f, do: :pending\n  end")) ==
               []
    end

    test "a definition nested in a live one joins this module" do
      # Un-quoted, the inner `def` runs during the outer one's expansion and really does add a
      # clause here — unlike a quoted one, which can only be eval'd into another module.
      src = t("  def f(:good), do: :ok\n  def g, do: unquote((def f(:bad), do: :pending; 1))")
      assert on_ok(src) == @ok_mutated
    end

    test "a live unquote in a macro body runs when this module compiles" do
      # A macro *body* is not another module's scope: its `quote` blocks are data for the
      # invocation site, but anything outside them is evaluated here, at definition time.
      src =
        t("  def f(:good), do: :ok\n  defmacro g, do: unquote((def f(:bad), do: :pending; :ok))")

      assert on_ok(src) == @ok_mutated

      # …while the quoted boilerplate a `__using__` injects still targets somebody else.
      quoted =
        t(
          "  def f, do: :ok\n  defmacro __using__(_) do\n    quote do\n" <>
            "      def f, do: :pending\n    end\n  end"
        )

      assert on_ok(quoted) == []
    end

    test "a definition nested in a definition is data for another module" do
      # A `def` inside a `def` body can only be quoted and eval'd elsewhere ("cannot invoke def
      # inside function"), so it neither joins this module's groups nor blocks them — the
      # reading `ModulePlan` already gives it.
      src =
        t(
          "  defp gen(name) do\n    quote do: (def unquote(name)(), do: 1)\n  end\n" <>
            "  def f, do: :ok"
        )

      assert on_ok(src) == []
    end

    test "a qualified definition is a real clause, so it blocks its signature" do
      # `Kernel.def` (and an aliased `K.def`) mints a clause as real as a bare one; read by name
      # alone the node is a call, and the sibling `:ok` reads as the only path.
      assert on_ok(
               t("  def f(:valid), do: :ok\n  Kernel.def f(:invalid), do: {:error, :invalid}")
             ) ==
               @ok_mutated

      assert on_ok(
               t(
                 "  alias Kernel, as: K\n  def f(:valid), do: :ok\n" <>
                   "  K.def f(:invalid), do: {:error, :invalid}"
               )
             ) == @ok_mutated
    end

    test "a spliced head blocks its name at every arity, and only its name" do
      src = t("  def f(unquote_splicing(args)), do: 1\n  def f, do: :ok\n  def g, do: :ok")
      assert on_ok(src) == @ok_mutated
      assert Enum.map(sites(src), &elem(&1, 1)) == [3, 3, 3]
    end
  end

  describe "the metamutant" do
    test "renders without the stamp and the unit function still returns :ok" do
      src = """
      defmodule Mutare.UnitReturnsFixture do
        def ping(x) do
          send(self(), x)
          :ok
        end
      end
      """

      %{metamutant: metamutant, sites: sites} =
        Mutare.Transform.transform_string_with_sites(src, mutators: @families)

      assert sites == []
      refute metamutant =~ "mutare_unit_tail"

      [{_module, _binary}] = Mutare.Test.Compile.string(metamutant)
      assert Mutare.UnitReturnsFixture.ping(1) == :ok
      assert_received 1
    end
  end
end
