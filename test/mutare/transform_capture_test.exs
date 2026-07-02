defmodule Mutare.TransformCaptureTest do
  # Mutation of `&Mod.fun/N` reference captures (a call *value*): the same call families
  # that match a written call match the capture, via re-capture (rename/removal). Split
  # from transform_test.exs. `async: false` — a runtime test flips the global selector.
  use ExUnit.Case, async: false

  alias Mutare.Site

  describe "capture mutation (a `&Mod.fun/N` reference is a call value)" do
    alias Mutare.Selector

    test "a remote capture is renamed, kept in capture form (&String.first/1 → &String.last/1)" do
      source = "defmodule Cap do\n  def f(l), do: Enum.map(l, &String.first/1)\nend\n"

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringCall]
        )

      assert [
               %Site{
                 mutator: :string_call,
                 kind: :in_place,
                 original_code: "&String.first/1",
                 mutated_code: "&String.last/1"
               }
             ] = sites

      # Baseline branch is the *verbatim* capture (a real external fun — identity preserved),
      # the mutant a re-built capture (not an eta-expanded `fn`).
      assert meta =~ "&String.first/1"
      assert meta =~ "&String.last/1"
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "a transparent-transform capture earns a removal (&String.upcase/1 → &Function.identity/1)" do
      source = "defmodule Cap do\n  def f(l), do: Enum.map(l, &String.upcase/1)\nend\n"

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      # Removal of an arity-1 capture is the named, alias-proof identity capture.
      assert [
               %Site{
                 mutator: :call_removal,
                 original_code: "&String.upcase/1",
                 mutated_code: "&Elixir.Function.identity/1"
               }
             ] = sites
    end

    test "an arity-N removal becomes the arity-N first-arg projection (no named identity/N)" do
      source = "defmodule Cap do\n  def f(l), do: Enum.map(l, &String.slice/3)\nend\n"

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      assert [%Site{mutator: :call_removal, original_code: "&String.slice/3"} = site] = sites
      assert site.mutated_code == "fn mutare_capture_arg, _, _ -> mutare_capture_arg end"
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "an Erlang-atom-module capture resolves and mutates (&:string.trim/1)" do
      source = "defmodule Cap do\n  def f(l), do: Enum.map(l, &:string.trim/1)\nend\n"

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      assert [
               %Site{
                 mutator: :call_removal,
                 original_code: "&:string.trim/1",
                 mutated_code: "&Elixir.Function.identity/1"
               }
             ] = sites
    end

    test "an aliased capture resolves through the alias and keeps the written alias in the diff" do
      source =
        "defmodule Cap do\n  alias String, as: S\n  def f(l), do: Enum.map(l, &S.first/1)\nend\n"

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringCall]
        )

      assert [
               %Site{
                 mutator: :string_call,
                 original_code: "&S.first/1",
                 mutated_code: "&S.last/1"
               }
             ] =
               sites
    end

    test "a whole-imported bare capture is renamed and kept bare" do
      source = """
      defmodule Cap do
        import Enum
        def f(l), do: Enum.map(l, &filter/2)
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Collection]
        )

      assert [
               %Site{
                 mutator: :collection,
                 original_code: "&filter/2",
                 mutated_code: "&reject/2"
               }
             ] = sites

      assert meta =~ "&filter/2"
      assert meta =~ "&reject/2"
      assert_compiles(meta)
    end

    test "a whole-imported bare capture witnesses a renamed bare sibling" do
      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(
          """
          defmodule HiddenCaptureRejectReplacement do
            def reject(xs, fun), do: Enum.map(xs, fun)

            defmacro __using__(_) do
              quote do
                import Enum, except: [reject: 2]
                import HiddenCaptureRejectReplacement, only: [reject: 2]
              end
            end
          end

          defmodule CapHiddenRejectReplacement do
            import Enum
            use HiddenCaptureRejectReplacement

            def f(l), do: Enum.map(l, &filter/2)
          end
          """,
          mutators: [Mutare.Mutators.Collection]
        )

      assert [
               %Site{
                 mutator: :collection,
                 original_code: "&filter/2",
                 mutated_code: "&reject/2"
               } = site
             ] = sites

      assert meta =~ "import Elixir.Enum, only: [filter: 2]"
      assert meta =~ "import Elixir.Enum, only: [reject: 2]"

      stderr =
        assert_compile_error(
          meta,
          ["reject/2", "Enum", "HiddenCaptureRejectReplacement"],
          "lib/hidden_capture_reject_replacement.ex"
        )

      assert Mutare.Poison.ids(stderr, %{"lib/hidden_capture_reject_replacement.ex" => meta}) ==
               MapSet.new([site.id])
    end

    test "a selectively-imported bare capture qualifies a renamed sibling" do
      source = """
      defmodule Cap do
        import Enum, only: [filter: 2]
        def f(l), do: Enum.map(l, &filter/2)
      end
      """

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Collection]
        )

      assert [
               %Site{
                 mutator: :collection,
                 original_code: "&filter/2",
                 mutated_code: "&Elixir.Enum.reject/2"
               }
             ] = sites
    end

    test "a bare imported transparent-transform capture earns a removal" do
      source = """
      defmodule Cap do
        import String, only: [upcase: 1]
        def f, do: &upcase/1
      end
      """

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CallRemoval]
        )

      assert [
               %Site{
                 mutator: :call_removal,
                 original_code: "&upcase/1",
                 mutated_code: "&Elixir.Function.identity/1"
               }
             ] = sites
    end

    test "a bare local capture is still pruned (no import stamp to resolve it)" do
      source =
        "defmodule Cap do\n  def f(l), do: Enum.map(l, &local/1)\n  def local(x), do: x\nend\n"

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source, mutators: Mutare.Mutators.all())

      # No site mutates the capture *itself* (the enclosing `Enum.map(...)` still mutates,
      # so check the capture form exactly, not as a substring).
      refute Enum.any?(sites, &(&1.original_code == "&local/1"))
    end

    test "a capture in a module-level scaffold is inert (compile-time, mutant 0), runtime captures still mutate" do
      # The `for` generator runs once at compile time with mutant 0 active, so a selector
      # wrapping the scaffold's own `&String.first/1` could never activate or record coverage
      # at test time — it would only mint an inert no-coverage mutant. The capture must stay
      # raw there, while a capture in an ordinary `def` body (`:runtime`) still mutates.
      source = """
      defmodule ScaffoldCap do
        for _fun <- [&String.first/1] do
          def generated, do: :ok
        end

        def runtime_cap, do: &String.first/1
      end
      """

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringCall]
        )

      # The scaffold's capture renders verbatim — not wrapped in a selector. Only the runtime
      # `def runtime_cap` capture is a site (without the context guard both would be).
      assert meta =~ "for _fun <- [&String.first/1] do"
      assert [%Site{mutator: :string_call, original_code: "&String.first/1"}] = sites
      assert_compiles(meta)
    end

    test "an arity-changing family can't re-capture, so it leaves the capture alone" do
      # CollectionArity *drops* an argument — the output reuses fewer args, so it is not
      # re-capturable at the original arity and is dropped. A same-arity swap it can express
      # (`Enum.sort/1` → `Enum.reverse/1`) *is* re-captured, so assert against a drop-only case.
      source = "defmodule Cap do\n  def f(l), do: Enum.map(l, &Enum.take/2)\nend\n"

      {_meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.CollectionArity]
        )

      refute Enum.any?(sites, &(&1.original_code == "&Enum.take/2"))
    end

    test "runtime: baseline keeps the verbatim capture's identity; the mutant is a real external fun" do
      source = "defmodule Mutare.CaptureRuntimeFixture do\n  def fun, do: &String.first/1\nend\n"

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.StringCall]
        )

      # Bind the module from the compile result (not a literal) so the compiler can't
      # constant-fold a reference to a not-yet-defined module into an "undefined" warning.
      [{mod, _}] = assert_compiles(meta)
      site = Enum.find(sites, &(&1.mutator == :string_call))

      Selector.put(Selector.baseline())
      base = mod.fun()
      # External funs compare by MFA, so the mutant-0 value is *equal* to a hand-written
      # capture — `==` / map-key / MapSet identity is preserved at baseline.
      assert base == (&String.first/1)
      assert base.("hi") == "h"

      Selector.put(site.id)
      mutant = mod.fun()
      # A real external fun (`&String.last/1`), not an eta-expanded `fn`: it compares equal to
      # the hand-written swap and unequal to the original, and behaves like String.last.
      assert mutant == (&String.last/1)
      refute mutant == (&String.first/1)
      assert mutant.("hi") == "i"
    after
      Selector.put(Selector.baseline())
    end
  end

  describe "expression captures (`&(… &1 … &2 …)`): the body is ordinary runtime code" do
    alias Mutare.Selector

    test "an operator in the capture body is mutated (`&(&1 && &2)` → `&(&1 || &2)`)" do
      # Distinct from a `&Mod.fun/N` *reference* capture (above): an expression capture's
      # body is not a call value, so it does not route through `Captures.offer`. It falls
      # through to ordinary `:runtime` analysis, and the `&&` is offered to Logical like any
      # other body operator.
      source = "defmodule Cap do\n  def both, do: &(&1 && &2)\nend\n"

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.Logical])

      assert [
               %Site{
                 mutator: :logical,
                 kind: :in_place,
                 original_form: :&&,
                 mutated_form: :||,
                 original_code: "&1 && &2",
                 mutated_code: "&1 || &2"
               }
             ] = sites

      assert_compiles(meta)
    end

    test "the woven selector lands *inside* the capture and compiles + activates at runtime" do
      # The in-place selector `case` is hoisted into the `&(…)` body — an unusual construct
      # that `Code.string_to_quoted` (parse-only) would wave through but a real compile must
      # validate. Prove the capture still produces a working 2-arity fun: the baseline keeps
      # `&&` semantics (short-circuit on a falsy LHS) and flipping the mutant swaps to `||`.
      source = "defmodule Mutare.CaptureBodyFixture do\n  def both, do: &(&1 && &2)\nend\n"

      {meta, sites, _} =
        Mutare.Transform.transform_string_with_sites(source, mutators: [Mutare.Mutators.Logical])

      # Bind the module from the compile result (not a literal) so the compiler can't fold a
      # reference to a not-yet-defined module into an "undefined" warning.
      [{mod, _}] = assert_compiles(meta)
      site = Enum.find(sites, &(&1.mutator == :logical))

      Selector.put(Selector.baseline())
      base = mod.both()
      assert base.(true, :x) == :x
      # `&&` short-circuits on a falsy LHS, returning it unevaluated.
      assert base.(nil, :x) == nil

      Selector.put(site.id)
      mutant = mod.both()
      # `||` returns the truthy RHS where `&&` returned the falsy LHS — a real behaviour change.
      assert mutant.(nil, :x) == :x
      assert mutant.(false, nil) == nil
    after
      Selector.put(Selector.baseline())
    end

    test "numbered placeholders (`&1`/`&2`) are never mutated as integer literals" do
      # `&1`/`&2` carry a *bare* integer index, not a `{:__block__, _, [n]}` literal node, so
      # the literal families never see them. A body of only placeholders yields no literal
      # site; a real adjacent literal still mutates. This disambiguation is what keeps a
      # capture from being corrupted into an invalid `&0` or a wrong-position `&2`.
      lit = [Mutare.Mutators.Literal]

      {_m, placeholder_only, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule C do\n  def f, do: &(&1 + &2)\nend\n",
          mutators: lit
        )

      assert placeholder_only == []

      {_m, with_literal, _} =
        Mutare.Transform.transform_string_with_sites(
          "defmodule C do\n  def f, do: &(&1 + 1)\nend\n",
          mutators: lit
        )

      # Only the standalone `1` mutates (succ `2`, and zero/pred deduped to `0`); the
      # placeholder's `1` contributes nothing. Were it mutated too we would see four sites.
      assert with_literal |> Enum.map(& &1.mutated_code) |> Enum.sort() == ["0", "2"]
    end
  end

  defp assert_compiles(meta) do
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end

  defp assert_compile_error(meta, message, file) do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise CompileError, fn -> Code.compile_string(meta, file) end
      end)

    for m <- List.wrap(message), do: assert(stderr =~ m)
    stderr
  end
end
