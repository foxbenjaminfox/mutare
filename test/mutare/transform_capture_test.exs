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
      {meta, sites, _} = Mutare.transform_string(source, mutators: [Mutare.Mutators.StringCall])

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
      {_meta, sites, _} = Mutare.transform_string(source, mutators: [Mutare.Mutators.CallRemoval])

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
      {meta, sites, _} = Mutare.transform_string(source, mutators: [Mutare.Mutators.CallRemoval])

      assert [%Site{mutator: :call_removal, original_code: "&String.slice/3"} = site] = sites
      assert site.mutated_code == "fn mutare_capture_arg, _, _ -> mutare_capture_arg end"
      assert {:ok, _} = Code.string_to_quoted(meta)
    end

    test "an Erlang-atom-module capture resolves and mutates (&:string.trim/1)" do
      source = "defmodule Cap do\n  def f(l), do: Enum.map(l, &:string.trim/1)\nend\n"
      {_meta, sites, _} = Mutare.transform_string(source, mutators: [Mutare.Mutators.CallRemoval])

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

      {_meta, sites, _} = Mutare.transform_string(source, mutators: [Mutare.Mutators.StringCall])

      assert [
               %Site{
                 mutator: :string_call,
                 original_code: "&S.first/1",
                 mutated_code: "&S.last/1"
               }
             ] =
               sites
    end

    test "a bare/local capture is deferred (no import stamp to resolve it)" do
      source =
        "defmodule Cap do\n  def f(l), do: Enum.map(l, &local/1)\n  def local(x), do: x\nend\n"

      {_meta, sites, _} = Mutare.transform_string(source, mutators: Mutare.Mutators.all())

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
        Mutare.transform_string(source, mutators: [Mutare.Mutators.StringCall])

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
        Mutare.transform_string(source, mutators: [Mutare.Mutators.CollectionArity])

      refute Enum.any?(sites, &(&1.original_code == "&Enum.take/2"))
    end

    test "runtime: baseline keeps the verbatim capture's identity; the mutant is a real external fun" do
      source = "defmodule Mutare.CaptureRuntimeFixture do\n  def fun, do: &String.first/1\nend\n"
      {meta, sites, _} = Mutare.transform_string(source, mutators: [Mutare.Mutators.StringCall])
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

  defp assert_compiles(meta) do
    assert [_ | _] = Mutare.Test.Compile.string(meta)
  end
end
