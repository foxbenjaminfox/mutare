defmodule Mutare.PoisonTest do
  @moduledoc "Compile-poisoning: detect the offending mutant, drop it, recover."
  use ExUnit.Case, async: false

  alias Mutare.{Poison, Result}
  alias Mutare.Test.Project

  @poison [mutators: [Mutare.Test.PoisonMutator], file: "lib/p.ex"]
  @src "defmodule P do\n  def f(a, b), do: a + b\nend\n"

  describe "transform :skip_ids" do
    test "a skipped id is recorded :poisoned with no selector, so it compiles" do
      {meta, [site], _next_id} = Mutare.transform_string(@src, @poison)

      # Without skipping, the poison mutant is in the metamutant (won't compile).
      assert meta =~ "mutare_unbound_xyz"

      {meta2, [site2], _next_id} =
        Mutare.transform_string(@src, Keyword.put(@poison, :skip_ids, MapSet.new([site.id])))

      assert site2.id == site.id
      assert site2.poisoned
      refute meta2 =~ "mutare_unbound_xyz"
      # And it actually compiles now.
      assert [{P, _}] = Code.compile_string(meta2)
    after
      :code.purge(P)
      :code.delete(P)
    end
  end

  describe "Poison.ids/2" do
    test "maps a compile error's file:line to the mutant whose generated code spans it" do
      {meta, [site], _next_id} = Mutare.transform_string(@src, @poison)

      line =
        meta
        |> String.split("\n")
        |> Enum.find_index(&(&1 =~ "mutare_unbound_xyz"))
        |> Kernel.+(1)

      error = "lib/p.ex:#{line}:5: undefined variable \"mutare_unbound_xyz\""
      # `Poison.ids/2` now takes the metamutant *sources* and builds the manifest
      # lazily, so the scan never pays for it on a healthy run.
      metamutants = %{"lib/p.ex" => meta}
      assert Poison.ids(error, metamutants) == MapSet.new([site.id])
    end

    test "returns empty when nothing maps (caller then aborts)" do
      assert Poison.ids("some unrelated error", %{}) == MapSet.new()
    end

    test "ignores a warning's file:line — only error diagnostics locate poison" do
      {meta, [site], _next_id} = Mutare.transform_string(@src, @poison)
      metamutants = %{"lib/p.ex" => meta}

      line =
        meta
        |> String.split("\n")
        |> Enum.find_index(&(&1 =~ "mutare_unbound_xyz"))
        |> Kernel.+(1)

      # mix footers a *warning* with the same `└─ file:line` shape as an error. A failed
      # compile prints every warning the mutations provoke; pointing one at the mutant's
      # own line must NOT flag it as poison (the bug that dropped ~110 valid plug mutants).
      warning =
        "    warning: variable \"x\" is unused\n" <>
          "    └─ lib/p.ex:#{line}:5: P.f/2\n"

      assert Poison.ids(warning, metamutants) == MapSet.new()

      # The same location inside an `error:` diagnostic *is* the poison.
      error =
        "    error: undefined variable \"mutare_unbound_xyz\"\n" <>
          "    └─ lib/p.ex:#{line}:5: P.f/2\n"

      assert Poison.ids(error, metamutants) == MapSet.new([site.id])

      # A warning sharing the output with the real error neither adds nor hides ids.
      assert Poison.ids(warning <> error, metamutants) == MapSet.new([site.id])
    end
  end

  describe "unrecoverable compile failure → remediation hint" do
    @tag :runner
    @tag timeout: 180_000
    test "a macro requiring a literal arg aborts, and the captured output drives a :skip hint" do
      # The one poison class recovery *can't* isolate: a macro that only accepts a
      # compile-time literal (`Size.megabytes(5)`). Mutare wraps the literal in a
      # runtime selector `case`, the macro receives that `case` AST and raises while
      # the compiler is expanding it — and the compiler reports the macro *call* line,
      # not the spliced selector inside it, so `Poison.ids/2` maps nothing and the run
      # aborts. The end-to-end value of this test is the *bridge*: the real compiler
      # output must still carry an `expanding macro:` frame, so `Mutare.Poison.Hint`
      # can name the macro and print a `:skip` snippet. Guards against compiler-output
      # drift the pure `HintTest` can't see.
      %{project: project, sandbox: sandbox} =
        Project.build(:litmacro, %{
          "lib/size.ex" => """
          defmodule Size do
            defmacro megabytes(n) when is_integer(n) do
              quote do: unquote(n) * 1024 * 1024
            end
          end
          """,
          "lib/usage.ex" => """
          defmodule Usage do
            require Size
            def limit, do: Size.megabytes(5)
          end
          """,
          "test/usage_test.exs" => """
          defmodule UsageTest do
            use ExUnit.Case
            test "limit", do: assert(Usage.limit() == 5 * 1024 * 1024)
          end
          """
        })

      # Only Literal, so the *only* mutation is the `5` at the call site — the macro
      # definition (its body inside `quote`) has no sites, so the abort is the macro
      # poison alone, isolated and immediate (an empty poison set ⊆ skip_ids, no retries).
      assert {:error, :compile_failed, detail} =
               Mutare.run(project, sandbox: sandbox, mutators: [Mutare.Mutators.Literal])

      assert detail =~ "expanding macro: Size.megabytes"

      hint = Poison.Hint.for_compile_failure(detail)
      assert hint =~ "compile-time literal"
      assert hint =~ "{Size, :megabytes, :skip}"
    end
  end

  describe "end to end recovery" do
    @tag :runner
    @tag timeout: 180_000
    test "a poisoning mutant is dropped (:poisoned) and the rest of the run proceeds" do
      %{project: project, sandbox: sandbox} =
        Project.build(:p, %{
          "lib/p.ex" => """
          defmodule P do
            def add(a, b), do: a + b
            def gte?(a, b), do: a >= b
          end
          """,
          "test/p_test.exs" => """
          defmodule PTest do
            use ExUnit.Case
            test "gte boundary" do
              assert P.gte?(5, 5)
              refute P.gte?(4, 5)
            end
          end
          """
        })

      mutators = [Mutare.Test.PoisonMutator, Mutare.Mutators.Relational]
      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: mutators)

      # add/2's `+` mutates to an unbound var → poison → dropped, not aborted.
      assert [%Result{site: %{original_form: :+}, status: :poisoned}] =
               Enum.filter(run.results, &(&1.status == :poisoned))

      # gte?/2's relational mutants still ran and were killed.
      assert Enum.count(run.results, &(&1.status == :killed)) == 2
      assert Mutare.Report.score(run.results) == 100.0
    end

    @tag :runner
    @tag timeout: 180_000
    test "a poison in a guard (lifted, bad code in a private defp) is dropped, not aborted" do
      # The regression: a guard mutation's poison lives in a generated private
      # `defp __mutare_…_m<id>`, lines away from its dispatcher clause. The old
      # line→id mapping matched only the dispatcher clause's start line, so it
      # found nothing (MapSet.new([])) and the whole run aborted. The manifest's
      # generated ranges cover the private definition, so it's now identifiable.
      %{project: project, sandbox: sandbox} =
        Project.build(:pg, %{
          "lib/pg.ex" => """
          defmodule Pg do
            def gte?(a, b) when a + 0 >= b, do: true
            def gte?(_, _), do: false
          end
          """,
          "test/pg_test.exs" => """
          defmodule PgTest do
            use ExUnit.Case
            test "gte boundary" do
              assert Pg.gte?(5, 5)
              refute Pg.gte?(4, 5)
            end
          end
          """
        })

      mutators = [Mutare.Test.PoisonMutator, Mutare.Mutators.Relational]
      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: mutators)

      # the guard's `+` poisons (→ unbound var in the lifted copy) → dropped.
      assert [%Result{site: %{original_form: :+}, status: :poisoned}] =
               Enum.filter(run.results, &(&1.status == :poisoned))

      # the surviving lifted mutants (guard relational swaps + clause drops) ran;
      # the boundary test kills them, so the run completes rather than aborting.
      refute Enum.empty?(Enum.filter(run.results, &(&1.status == :killed)))
      assert Mutare.Report.score(run.results) == 100.0
    end

    @tag :runner
    @tag timeout: 180_000
    test "a poisoning block-macro invocation is skipped wholesale, sparing a same-named sibling" do
      # `guarded …` is an *unknown* module-level block macro: Mutare mutates its body on
      # the guess a DSL unquotes it into a function. This DSL dispatches on its first arg:
      # `guarded :guard do …` splices the body into a `when` guard (the injected selector
      # `case` is illegal there → poison), while `guarded :body do …` emits a normal
      # function body (the selector is fine). The runner must skip the *whole hostile
      # block* at once — but, crucially, only **that invocation**: the `:body` block is a
      # different invocation of the same macro, so its valid mutants must still run. A
      # bare-name tag would bucket both together and wrongly suppress the `:body` mutants.
      %{project: project, sandbox: sandbox} =
        Project.build(:gdsl, %{
          "lib/guard_dsl.ex" => """
          defmodule GuardDSL do
            # `:guard` → splice into a `when` guard, where a selector `case` is illegal
            # (a *mutated* body poisons; the raw body, a guard-legal expr, compiles).
            defmacro guarded(:guard, do: body) do
              quote do
                def g(x) when unquote(unwrap(body)), do: x
              end
            end

            # `:body` → a normal function body, where the selector is perfectly legal, so
            # this sibling invocation of the same macro mutates and runs fine.
            defmacro guarded(:body, do: body) do
              quote do
                def b, do: unquote(unwrap(body))
              end
            end

            defp unwrap({:__block__, _meta, [single]}), do: single
            defp unwrap(other), do: other
          end
          """,
          "lib/uses.ex" => """
          defmodule Uses do
            import GuardDSL

            guarded :guard do
              1 < 2
            end

            guarded :body do
              3 + 4
            end
          end
          """,
          "test/uses_test.exs" => """
          defmodule UsesTest do
            use ExUnit.Case

            test "g" do
              assert Uses.g(:yes) == :yes
            end

            test "b" do
              assert Uses.b() == 7
            end
          end
          """
        })

      mutators = [Mutare.Mutators.Relational, Mutare.Mutators.Literal, Mutare.Mutators.Arithmetic]
      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: mutators)

      # The two `guarded` invocations are tagged apart (same name, different nid).
      by_tag =
        run.results
        |> Enum.filter(&match?({:guarded, _}, &1.site.block_macro))
        |> Enum.group_by(& &1.site.block_macro, & &1.status)

      assert map_size(by_tag) == 2
      statuses = Map.values(by_tag)

      # One invocation (`:guard`) poisons wholesale — every mutant in it dropped…
      assert Enum.any?(statuses, &(Enum.uniq(&1) == [:poisoned]))
      # …while the other (`:body`) is spared: its mutants compiled, ran, and were killed
      # by `b() == 7`. A name-based tag would have poisoned these too (the regression).
      assert Enum.any?(statuses, &(:killed in &1))
      refute Enum.any?(statuses, &(:poisoned in &1 and :killed in &1))
    end

    @tag :runner
    @tag timeout: 180_000
    test "an id-specific poison in an unknown block spares the block's compile-safe siblings" do
      # `wrap do … end` is an *unknown* module-level block macro, but a **non-hostile** one:
      # it unquotes its body into a normal function body, where the injected selector `case`
      # is perfectly legal. So the block as a whole is fine — only *one* mutant in it is
      # broken: the custom `PoisonMutator` rewrites `+` to an unbound variable. Eager
      # escalation would, on that single poison, drop the *whole* block — wrongly marking the
      # compile-safe built-in arithmetic/literal siblings `:poisoned` and shrinking the score.
      # Evidence-based escalation drops only the poison mutant (the block never takes a second
      # strike), so the siblings compile, run, and are killed.
      %{project: project, sandbox: sandbox} =
        Project.build(:wdsl, %{
          "lib/wrap_dsl.ex" => """
          defmodule WrapDSL do
            # Unquote the body into a *normal* function body — selectors are legal here, so
            # the block is not wholesale-hostile; any poison is one mutant's own doing.
            defmacro wrap(do: body) do
              quote do
                def w, do: unquote(unwrap(body))
              end
            end

            defp unwrap({:__block__, _meta, [single]}), do: single
            defp unwrap(other), do: other
          end
          """,
          "lib/uses_wrap.ex" => """
          defmodule UsesWrap do
            import WrapDSL

            wrap do
              1 + 2
            end
          end
          """,
          "test/uses_wrap_test.exs" => """
          defmodule UsesWrapTest do
            use ExUnit.Case

            test "w" do
              assert UsesWrap.w() == 3
            end
          end
          """
        })

      mutators = [Mutare.Test.PoisonMutator, Mutare.Mutators.Arithmetic, Mutare.Mutators.Literal]
      assert {:ok, run} = Mutare.run(project, sandbox: sandbox, mutators: mutators)

      block = Enum.filter(run.results, &match?({:wrap, _}, &1.site.block_macro))

      # Only the custom `:poison` mutant is dropped; the built-in siblings are NOT poisoned.
      poisoned = for r <- block, r.status == :poisoned, do: r.site.mutator
      assert poisoned == [:poison]

      # The compile-safe arithmetic/literal siblings compiled, ran, and were killed by
      # `w() == 3` (eager escalation would have left them `:poisoned`, never run).
      assert Enum.any?(
               block,
               &(&1.status == :killed and &1.site.mutator in [:arithmetic, :literal])
             )

      refute Enum.any?(block, &(&1.status == :poisoned and &1.site.mutator != :poison))
    end
  end
end
