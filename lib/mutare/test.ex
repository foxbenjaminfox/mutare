defmodule Mutare.Test do
  @moduledoc """
  Test helpers for projects that implement their own `Mutare.Mutator`.

  A custom-mutator project wants to assert two things: what a single mutator offers for a
  parsed node (the pure-AST path, `Mutare.Mutator.mutations/3`), and what the *whole*
  transform records for a source string (`Mutare.transform_string/2`, which adds
  alias/import resolution, pipe handling, and equivalent-sibling suppression). Both wrap
  parse-in / render-out around Mutare's public surface, so without these every such
  project re-implements the same harness — and pulls in `:sourceror` only to do it.

  These route through `Mutare.AST.parse!/1` and `Mutare.AST.to_string/1`, so a consumer
  needs neither a direct `:sourceror` dependency nor any private Mutare internals.

  `import Mutare.Test` in an `ExUnit.Case` to use them:

      defmodule MyMutatorTest do
        use ExUnit.Case, async: true
        import Mutare.Test

        test "swaps + for -" do
          assert node_mutations("1 + 2", MyApp.PlusMutator) == ["1 - 2"]
        end
      end

  ## Which helper to reach for

    * `node_mutations/3` — the **node** path. Offers one (or more) mutators a single parsed
      node directly, with no transform pre-pass, so only *qualified* calls resolve and no
      structural siblings (`return_value`, `clause_drop`) appear. The tightest unit test of
      a mutator's `mutate/1`·`mutate/2`.
    * `diffs/2` / `diffs_for/3` — the **source** path. Drives the real
      `Mutare.transform_string/2`, so alias/import resolution, pipe handling, and
      equivalent-sibling suppression are all exercised exactly as in a `mix mutare` run.
    * `assert_metamutant_compiles/2` — the single-build safety net: every mutant a source
      produces is embedded in one program that must compile.
  """

  import ExUnit.Assertions

  @typedoc """
  A mutator entry the **source** helpers accept — anything `:mutators` takes: a family
  atom (`:arithmetic`), a custom module, a `{module, opts}` pair, or an already-resolved
  `Mutare.Mutator.Spec`.
  """
  @type mutator ::
          atom() | module() | {atom() | module(), term()} | Mutare.Mutator.Spec.t()

  @doc """
  The rendered mutations a single mutator (or list) offers for a parsed top-level node —
  the pure-AST path (`Mutare.Mutator.mutations/3`), with no transform pre-pass, so only
  *qualified* calls resolve and no structural siblings are added.

  `mutators` is a module or `Mutare.Mutator.Spec` (or a list of them) — *not* a family
  atom, since this path skips the registry that would resolve one. `pipe_mode` defaults to
  `:unpiped`; pass `:piped` to exercise a `|>` right-hand side, where the piped value is an
  implicit extra argument and the effective arity is one higher than the written call.

      iex> import Mutare.Test
      iex> node_mutations("1 + 2", Mutare.Mutators.Arithmetic)
      ["1 - 2"]

  The `pipe_mode` flag is what an arity-changing mutator reads to recover the effective
  arity, so a written call and the equivalent pipe stage produce the same mutant:

      iex> import Mutare.Test
      iex> node_mutations("Enum.sort(coll)", Mutare.Mutators.CollectionArity)
      ["Enum.reverse(coll)"]
      iex> node_mutations("Enum.sort()", Mutare.Mutators.CollectionArity, :piped)
      ["Enum.reverse()"]
  """
  @spec node_mutations(
          String.t(),
          module() | Mutare.Mutator.Spec.t() | [module() | Mutare.Mutator.Spec.t()],
          :piped | :unpiped
        ) :: [String.t()]
  def node_mutations(snippet, mutators, pipe_mode \\ :unpiped) do
    node = Mutare.AST.parse!(snippet)
    context = %{pipe_mode: pipe_mode}

    for {_spec, mutated} <- Mutare.Mutator.mutations(node, List.wrap(mutators), context),
        do: Mutare.AST.to_string(mutated)
  end

  @doc """
  Every recorded mutation site for `source` as `{mutator_name, original_code, mutated_code}`,
  in the order the transform records them.

  Drives the real transform pipeline (`Mutare.transform_string/2`), so resolution, pipe
  handling, and equivalent-sibling suppression are all exercised exactly as in a `mix mutare`
  run — and the structural families the transform also records (`return_value`, `clause_drop`,
  …) show up alongside yours. Use `diffs_for/3` to isolate one family.

      iex> import Mutare.Test
      iex> diffs("def f(a, b), do: a + b", [Mutare.Mutators.Arithmetic])
      [{:arithmetic, "a + b", "a - b"}]
  """
  @spec diffs(String.t(), [mutator()]) :: [{atom(), String.t(), String.t()}]
  def diffs(source, mutators) do
    {_metamutant, sites, _next_id} = Mutare.transform_string(source, mutators: mutators)
    for site <- sites, do: {site.mutator, site.original_code, site.mutated_code}
  end

  @doc """
  The `{original_code, mutated_code}` pairs `name` produced for `source`, isolating that one
  family from any structural sibling (`return_value`, `clause_drop`, …) the transform also
  records.

  `name` is the recorded family name — a built-in's `Mutare.Mutator.name/0`, or the `:as`
  override when the mutator was configured under one.

      iex> import Mutare.Test
      iex> mutators = [Mutare.Mutators.Arithmetic, Mutare.Mutators.ReturnValue]
      iex> diffs_for("def f(a, b), do: a + b", mutators, :arithmetic)
      [{"a + b", "a - b"}]
  """
  @spec diffs_for(String.t(), [mutator()], atom()) :: [{String.t(), String.t()}]
  def diffs_for(source, mutators, name) do
    for {mutator, original, mutated} <- diffs(source, mutators),
        mutator == name,
        do: {original, mutated}
  end

  @doc """
  Assert the metamutant embedding *every* mutant `source` produces compiles — the
  single-build safety net a custom mutator most needs, since one uncompilable mutant would
  sink the whole shared build.

  `source` must be a complete compilation unit (a `defmodule`, not a bare `def`); the
  metamutant is compiled as-is. Returns the `[{module, binary}]` that `Code.compile_string/1`
  produced, and purges them so repeated calls don't clash. Compiler output is captured so an
  expected undefined-stub warning never noises up the suite.

      defmodule MyMutatorTest do
        use ExUnit.Case, async: true
        import Mutare.Test

        test "every mutant still compiles" do
          assert_metamutant_compiles(
            "defmodule Sample do\\n  def f(a, b), do: a + b\\nend",
            [MyApp.PlusMutator]
          )
        end
      end
  """
  @spec assert_metamutant_compiles(String.t(), [mutator()]) :: [{module(), binary()}]
  def assert_metamutant_compiles(source, mutators) do
    {metamutant, _sites, _next_id} = Mutare.transform_string(source, mutators: mutators)

    {compiled, _io} =
      ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(metamutant) end)

    assert compiled != [],
           "metamutant compiled to no modules — is the source a complete `defmodule`?"

    for {module, _binary} <- compiled do
      :code.purge(module)
      :code.delete(module)
    end

    compiled
  end
end
