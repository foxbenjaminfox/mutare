defmodule Mutare.TransformPipeTest do
  # A selector cannot be a bare pipe target — `|>` hoisting lifts the selector into a
  # one-shot closure on the piped value (linear, not exponential, in chain depth). Split
  # from transform_test.exs.
  use ExUnit.Case, async: true
  import Mutare.Test.Metamutant

  describe "a selector cannot be a bare pipe target (|> hoisting)" do
    # `x |> case … end` *parses* but fails to compile (`Kernel.|>/2` can't pipe into
    # a `case`), so these assert the metamutant **compiles**, not just parses.
    test "a mutated middle/first pipe stage compiles" do
      source = """
      defmodule PipeFirst do
        def f(xs), do: xs |> Enum.reject(& &1) |> Enum.map(& &1)
      end
      """

      %{metamutant: meta, sites: sites} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Collection]
        )

      assert Enum.any?(sites, &(&1.mutator == :collection))
      # The diff still shows the bare stage swap, not the whole pipe.
      assert Enum.any?(sites, &(&1.mutated_code == "Enum.filter(& &1)"))
      assert_compiles(meta)
    end

    test "the lazy Stream directional twins are swapped in a pipe and compile" do
      source = """
      defmodule StreamPipe do
        def f(xs), do: xs |> Stream.filter(& &1) |> Stream.take(3) |> Enum.to_list()
      end
      """

      %{metamutant: meta, sites: sites} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Collection]
        )

      pairs = for s <- sites, s.mutator == :collection, do: {s.original_code, s.mutated_code}
      assert {"Stream.filter(& &1)", "Stream.reject(& &1)"} in pairs
      assert {"Stream.take(3)", "Stream.drop(3)"} in pairs
      assert_compiles(meta)
    end

    test "a mutated last pipe stage that is also the function tail compiles" do
      source = """
      defmodule PipeTail do
        def f(xs), do: xs |> Enum.map(& &1) |> Enum.reject(& &1)
      end
      """

      # Collection swaps the trailing `Enum.reject`; ReturnValue additionally wraps
      # the whole tail pipe — so the selector lands in the ReturnValue catch-all.
      %{metamutant: meta} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Collection, Mutare.Mutators.ReturnValue]
        )

      assert_compiles(meta)
    end

    # The selector is lifted into a one-shot closure on the piped value rather than
    # distributed across the branches, so the upstream chain appears once.
    test "the piped value is bound to a closure, not copied into each branch" do
      source = """
      defmodule OneShot do
        def f(xs), do: xs |> Enum.reject(& &1)
      end
      """

      %{metamutant: meta} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Collection]
        )

      # `lhs |> (fn <piped> -> case … end).()`, each branch piping the closure var.
      assert meta =~ ~r/\|>\s*\(fn mutare_piped ->/
      assert meta =~ "mutare_piped |> Enum.filter(& &1)"
      assert meta =~ "mutare_piped |> Enum.reject(& &1)"
      assert_compiles(meta)
    end

    # The historic form distributed `lhs` into every branch, so each mutated stage
    # multiplied the rendered size of the whole prefix-chain-so-far by (mutants + 1):
    # an N-stage chain blew up as ≈(mutants+1)^N (a long pipe of stdlib calls rendered
    # to megabytes). The closure form keeps the prefix once, so size is LINEAR in N.
    # Doubling the stage count must therefore far-less-than-triple the rendered size
    # (it ~doubles); the old form would have multiplied it by ~1000×.
    #
    # `CallRemoval` (not `Collection`) is used because it actually mutates a bare
    # `Enum.reverse()` stage — so each stage really does emit a hoisted closure. The
    # site-count guards keep this honest: if the chosen mutator ever stopped firing on
    # the chain, zero closures would render and the size assertion would pass vacuously.
    test "a deeply chained pipe stays linear in size (no exponential blowup)" do
      chain = fn n ->
        stages = for _ <- 1..n, do: "    |> Enum.reverse()"
        "defmodule Deep do\n  def f(xs) do\n    xs\n#{Enum.join(stages, "\n")}\n  end\nend\n"
      end

      %{metamutant: short, sites: short_sites} =
        Mutare.Transform.transform_string_with_sites(chain.(8),
          mutators: [Mutare.Mutators.CallRemoval]
        )

      %{metamutant: long, sites: long_sites} =
        Mutare.Transform.transform_string_with_sites(chain.(16),
          mutators: [Mutare.Mutators.CallRemoval]
        )

      # Every stage is mutated and therefore hoisted into a closure — otherwise the
      # size assertion below would never exercise the regression-prone path.
      assert length(short_sites) == 8
      assert length(long_sites) == 16
      assert short =~ "fn mutare_piped ->"
      assert long =~ "fn mutare_piped ->"

      assert byte_size(long) < 3 * byte_size(short)
      assert_compiles(long)
    end

    # The closure param is salted off the source's identifiers (like the dispatch and
    # super variables), so a stage argument that mentions the canonical name is not
    # captured by the closure.
    test "a source variable named `mutare_piped` forces the closure param to salt" do
      source = """
      defmodule Clash do
        def f(xs) do
          mutare_piped = 2
          xs |> Enum.take(mutare_piped) |> Enum.reject(& &1)
        end
      end
      """

      %{metamutant: meta} =
        Mutare.Transform.transform_string_with_sites(source,
          mutators: [Mutare.Mutators.Collection]
        )

      # The canonical name is taken, so the generated closure param is salted away.
      refute meta =~ ~r/\(fn mutare_piped ->/
      assert meta =~ ~r/\(fn mutare_piped_\d+ ->/
      # …and the source's own `mutare_piped` still reaches the stage argument.
      assert meta =~ "Enum.take(mutare_piped)"
      assert_compiles(meta)
    end
  end
end
