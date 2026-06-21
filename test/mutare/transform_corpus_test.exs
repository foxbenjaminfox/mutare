defmodule Mutare.TransformCorpusTest do
  @moduledoc """
  A table-driven *adversarial* corpus for the transform.

  `transform_test.exs` checks intended, well-behaved examples one assertion at a
  time. This file instead sweeps the syntactic corners where a context-classifying
  rewrite is most likely to go wrong — macros, bitstrings, patterns, module
  attributes, nested modules, alias/import/require directives, and non-consecutive
  clauses — and for *every* entry asserts the two invariants the whole tool rides
  on:

    1. **It compiles.** A metamutant that won't compile sinks the single build
       (the central bet), so the transform must emit valid Elixir for each context.
    2. **Baseline equivalence.** With no mutant active (id 0) the metamutant must
       be observationally identical to the original source. Each entry captures the
       *original's* behaviour by compiling it and running a set of probes, then
       compiles the *metamutant* and runs the same probes at baseline — the two
       outcome lists must be equal.

  As a guard against a context silently going inert — compiling and matching
  baseline only because nothing was rewritten — each entry also declares the
  minimum number of mutation sites the transform must still find in it. That is
  what turns "the metamutant compiles" into "the metamutant compiles *and still
  carries mutants* for this gnarly syntax".

  The modules are namespaced under `Mutare.Corpus.*` so entries never collide, and
  every probe is dispatched with `apply/3` so referencing a runtime-compiled
  fixture never trips a compile-time "undefined module" warning.
  """
  # Each entry compiles fixtures and flips the global `:persistent_term` selector,
  # so this file must not race other tests doing the same.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Mutare.Selector

  @corpus [
    %{
      name: "macros: defmacro/defmacrop bodies are inert; runtime uses still mutate",
      # The operators inside `quote` run at *expansion* time and must never get a
      # runtime selector; a private macro used internally and an imported macro
      # used across a module boundary must both survive the rewrite. The only
      # mutatable operator is the literal `+ 1` in `run/1`.
      source: """
      defmodule Mutare.Corpus.Macros.Lib do
        defmacro double(x), do: quote(do: unquote(x) * 2)
        defmacrop triple(x), do: quote(do: unquote(x) * 3)
        def via_private(x), do: triple(x)
      end

      defmodule Mutare.Corpus.Macros.Use do
        require Mutare.Corpus.Macros.Lib
        import Mutare.Corpus.Macros.Lib, only: [double: 1]

        def run(x), do: double(x) + 1
      end
      """,
      probes: [
        {Mutare.Corpus.Macros.Use, :run, [10]},
        {Mutare.Corpus.Macros.Lib, :via_private, [4]}
      ],
      min_sites: 1
    },
    %{
      name: "bitstrings: values and size args mutate; specifiers and separators do not",
      # The runtime value `n + 1` and the body `a + b` mutate; type atoms, the `-`
      # separators, `utf8`, and literal sizes must be left verbatim or the segment
      # stops being a legal specifier and the single build fails.
      source: """
      defmodule Mutare.Corpus.Bitstrings do
        def encode(n), do: <<n::size(16), (n + 1)::8>>
        def decode(<<a::size(8), b::size(8)>>), do: a + b
        def tagged(x), do: <<0x01, x::integer-big-size(32)>>
        def utf(s), do: <<s::utf8>>
      end
      """,
      probes: [
        {Mutare.Corpus.Bitstrings, :encode, [258]},
        {Mutare.Corpus.Bitstrings, :decode, [<<5, 9>>]},
        {Mutare.Corpus.Bitstrings, :tagged, [7]},
        {Mutare.Corpus.Bitstrings, :utf, [?A]}
      ],
      min_sites: 2
    },
    %{
      name: "patterns: heads/pins are not mutated; bodies and default-arg values are",
      # Destructuring heads, a map pattern, and a `^pin` are all patterns (no
      # mutation), but each *body* mutates and the call-time default `2 + 3` is a
      # runtime escape that must still mutate.
      source: """
      defmodule Mutare.Corpus.Patterns do
        def head([h | _]), do: h
        def pair({a, b}), do: a + b
        def mapget(%{count: c}), do: c * 2

        def pinned(x, y) do
          case y do
            ^x -> :same
            _ -> :diff
          end
        end

        def defaulted(a, b \\\\ 2 + 3), do: a + b
      end
      """,
      probes: [
        {Mutare.Corpus.Patterns, :head, [[7, 8]]},
        {Mutare.Corpus.Patterns, :pair, [{2, 3}]},
        {Mutare.Corpus.Patterns, :mapget, [%{count: 4}]},
        {Mutare.Corpus.Patterns, :pinned, [1, 1]},
        {Mutare.Corpus.Patterns, :pinned, [1, 2]},
        {Mutare.Corpus.Patterns, :defaulted, [10]},
        {Mutare.Corpus.Patterns, :defaulted, [10, 1]}
      ],
      min_sites: 4
    },
    %{
      name: "attributes: compile-time attribute values are frozen; reads in bodies mutate",
      # `@factor 3 * 4` and the `@offsets` list are compile-time and inert; the
      # bodies `n * @factor` and `Enum.sum(@offsets) + 1` are runtime and mutate.
      source: """
      defmodule Mutare.Corpus.Attributes do
        @moduledoc "fixture"
        @factor 3 * 4
        @offsets [1, 2, 3]

        def scale(n), do: n * @factor
        def total, do: Enum.sum(@offsets) + 1
      end
      """,
      probes: [
        {Mutare.Corpus.Attributes, :scale, [5]},
        {Mutare.Corpus.Attributes, :total, []}
      ],
      min_sites: 2
    },
    %{
      name: "nested modules: the inner module is rewritten (lifting included) through the outer",
      # The transform must recurse through the outer module into `Inner`, lift its
      # guarded `label/1`, mutate `inc/1`'s body, and mutate the outer `* 2` — all
      # in one rewrite, with both modules still callable at baseline.
      source: """
      defmodule Mutare.Corpus.Nested do
        defmodule Inner do
          def inc(x), do: x + 1
          def label(n) when n > 0, do: :pos
          def label(_), do: :nonpos
        end

        def outer(x), do: Inner.inc(x) * 2
        def classify(n), do: Inner.label(n)
      end
      """,
      probes: [
        {Mutare.Corpus.Nested.Inner, :inc, [5]},
        {Mutare.Corpus.Nested.Inner, :label, [3]},
        {Mutare.Corpus.Nested.Inner, :label, [0]},
        {Mutare.Corpus.Nested, :outer, [5]},
        {Mutare.Corpus.Nested, :classify, [-1]}
      ],
      min_sites: 6
    },
    %{
      name: "aliases/imports: alias/import/require directives survive and stay in order",
      # An aliased remote call, an imported function, and a `require`d guard-macro
      # used in a body must all keep working after the rewrite — the directives are
      # statements the transform must pass through untouched and in position.
      source: """
      defmodule Mutare.Corpus.Aliasing do
        alias Enum, as: E
        import List, only: [first: 1]
        require Integer

        def total(xs), do: E.sum(xs) + 1
        def head_or_zero(xs), do: first(xs) || 0
        def even?(n), do: Integer.is_even(n)
      end
      """,
      probes: [
        {Mutare.Corpus.Aliasing, :total, [[1, 2, 3]]},
        {Mutare.Corpus.Aliasing, :head_or_zero, [[9, 8]]},
        {Mutare.Corpus.Aliasing, :head_or_zero, [[]]},
        {Mutare.Corpus.Aliasing, :even?, [4]},
        {Mutare.Corpus.Aliasing, :even?, [3]}
      ],
      min_sites: 1
    },
    %{
      name: "non-consecutive clauses: split heads fall back to in-place and stay reachable",
      # `f/1`'s clauses are split by `g/1`, so the transform refuses to lift them
      # (a dispatcher would relocate bodies and shadow runs). Every `f/1` clause
      # must stay where it was written and remain reachable; only `g/1`'s body
      # mutates. The refusal is logged.
      source: """
      defmodule Mutare.Corpus.NonConsecutive do
        def f(x) when x > 0, do: :pos
        def g(y), do: y + 1
        def f(0), do: :zero
        def f(_), do: :other
      end
      """,
      probes: [
        {Mutare.Corpus.NonConsecutive, :f, [5]},
        {Mutare.Corpus.NonConsecutive, :f, [0]},
        {Mutare.Corpus.NonConsecutive, :f, [-1]},
        {Mutare.Corpus.NonConsecutive, :g, [2]}
      ],
      min_sites: 1,
      expect_log: ~r{clauses of f/1 are non-consecutive}
    },
    %{
      name: "try clauses: rescue/catch/else patterns are matches; their tails return",
      # Every `rescue`/`catch`/`else` clause *pattern* is a match, not runtime
      # code: the `e in RuntimeError` and the literal `1` below would each get a
      # selector `case` spliced into a pattern position (illegal Elixir, a
      # poison) if the analyzer treated them as runtime. The clause *bodies* are
      # return paths and do mutate; the `after` block is not a return path (its
      # value is discarded), but its body still mutates in place.
      source: """
      defmodule Mutare.Corpus.TryReturns do
        def run(x) do
          risky(x) + 0
        rescue
          e in RuntimeError -> {:rescued, Exception.message(e)}
        else
          1 -> :one
          n -> n * 2
        after
          :swallowed
        end

        defp risky(:boom), do: raise("boom")
        defp risky(n), do: n
      end
      """,
      probes: [
        {Mutare.Corpus.TryReturns, :run, [1]},
        {Mutare.Corpus.TryReturns, :run, [3]},
        {Mutare.Corpus.TryReturns, :run, [:boom]}
      ],
      min_sites: 6
    },
    %{
      name:
        "metaprogramming: a def created inside an if/for has its body mutated, the scaffold inert",
      # `feature/1` is conditionally defined, `code/n` gains heads from a comprehension
      # (constant name, `unquote` only in the pattern), and `code/1` also has a normal
      # top-level head. The `if @enabled` condition and the `1..3` generator run *once*,
      # at compile time, so a selector there could never activate — those stay verbatim;
      # every function *body* (`x * 2 + 1`, `53`, `unquote(n) * 10`) is runtime and
      # mutates, including the metaprogrammed heads and the plain head side by side.
      # Lifting is (correctly) refused for `code/1` — see the augmented-clauses note.
      source: """
      defmodule Mutare.Corpus.Meta do
        @enabled true

        if @enabled do
          def feature(x), do: x * 2 + 1
        end

        def code(0), do: 53

        for n <- 1..3 do
          def code(unquote(n)), do: unquote(n) * 10
        end
      end
      """,
      probes: [
        {Mutare.Corpus.Meta, :feature, [5]},
        {Mutare.Corpus.Meta, :code, [0]},
        {Mutare.Corpus.Meta, :code, [1]},
        {Mutare.Corpus.Meta, :code, [3]}
      ],
      min_sites: 6
    },
    %{
      name: "non-consecutive AND metaprogrammed: metaprogramming wins the diagnosis",
      # `f/1`'s literal heads straddle the `if` (non-consecutive) *and* the `if`
      # generates another `f/1` clause (metaprogrammed). Both independently force
      # in-place, but grouping the literal heads can't enable lifting — the
      # generated clause still blocks it. So the binding, accurate warning is the
      # metaprogrammed one; the misleading "group the clauses" non-consecutive
      # warning must be suppressed. Behaviour/baseline are unchanged either way.
      source: """
      defmodule Mutare.Corpus.NonConsecutiveMeta do
        @enabled true

        def f(0), do: :zero

        if @enabled do
          def f(1), do: :one
        end

        def f(2), do: :two
      end
      """,
      probes: [
        {Mutare.Corpus.NonConsecutiveMeta, :f, [0]},
        {Mutare.Corpus.NonConsecutiveMeta, :f, [1]},
        {Mutare.Corpus.NonConsecutiveMeta, :f, [2]}
      ],
      min_sites: 1,
      expect_log: ~r{clauses of f/1 are augmented by compile-time},
      refute_log: ~r{clauses of f/1 are non-consecutive}
    }
  ]

  setup do
    Selector.put(Selector.baseline())
    on_exit(fn -> Selector.put(Selector.baseline()) end)
    :ok
  end

  for entry <- @corpus do
    @entry entry
    test "compiles and stays baseline-equivalent — #{entry.name}" do
      assert_corpus_entry(@entry)
    end
  end

  # The whole corpus contract for one entry: the original's behaviour, the
  # transform, the central compile bet, a liveness floor, and baseline equivalence.
  defp assert_corpus_entry(%{name: name, source: source, probes: probes} = entry) do
    # A typo in the corpus source itself would surface as a transform failure;
    # rule that out first so a red test always points at the transform.
    assert {:ok, _} = Code.string_to_quoted(source), "corpus source for #{name} is invalid Elixir"

    # 1. Capture the original's observable behaviour.
    compile!(source, "original #{name}")
    original = Enum.map(probes, &probe/1)

    # 2. Transform → metamutant. Capture logs so the non-consecutive warning some
    #    entries deliberately provoke does not leak into test output (and can be
    #    asserted on).
    {{metamutant, sites, _next_id}, log} =
      with_log(fn -> Mutare.transform_string(source, file: name) end)

    if expected = entry[:expect_log] do
      assert log =~ expected, "expected a log matching #{inspect(expected)} for #{name}"
    end

    if refuted = entry[:refute_log] do
      refute log =~ refuted, "expected no log matching #{inspect(refuted)} for #{name}"
    end

    # 3. The central bet: the metamutant must parse and compile.
    assert {:ok, _} = Code.string_to_quoted(metamutant), "metamutant for #{name} does not parse"
    compile!(metamutant, "metamutant #{name}")

    # 4. Liveness: the context must not have gone inert under the rewrite.
    min_sites = Map.get(entry, :min_sites, 0)

    assert length(sites) >= min_sites,
           "expected at least #{min_sites} mutation sites for #{name}, got #{length(sites)}"

    # 5. Baseline equivalence: id 0 reproduces the original exactly.
    Selector.put(Selector.baseline())
    baseline = Enum.map(probes, &probe/1)

    assert baseline == original,
           """
           baseline metamutant diverged from the original for #{name}
             original: #{inspect(original)}
             baseline: #{inspect(baseline)}
           """
  end

  # Run one probe, capturing a normal return *or* a raise/throw/exit, so the
  # original and the baseline metamutant are compared on identical, total
  # outcomes — even for a fixture whose contract is to raise.
  defp probe({module, function, args}) do
    {:ok, apply(module, function, args)}
  rescue
    error -> {:raised, error.__struct__}
  catch
    kind, value -> {kind, value}
  end

  # Compile a source string, swallowing the "redefining module" warning the
  # original→metamutant recompile provokes (and any warning the adversarial
  # fixture itself emits), and turning a compile failure into a readable flunk
  # rather than a raw CompileError.
  defp compile!(source, label) do
    {result, _stderr} =
      with_io(:stderr, fn ->
        try do
          {:ok, Code.compile_string(source)}
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case result do
      {:ok, [_ | _] = modules} -> modules
      {:ok, []} -> flunk("#{label} compiled to no modules")
      {:error, message} -> flunk("#{label} failed to compile: #{message}")
    end
  end
end
