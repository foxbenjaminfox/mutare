defmodule Mutare.Test do
  @moduledoc """
  Test helpers for projects that implement their own `Mutare.Mutator`.

  Import this module into an `ExUnit.Case` to test a mutator at three levels:

    * `node_mutations/3` tests the replacements returned for one parsed node;
    * `diffs/2` and `diffs_for/3` test sites produced by the full source transform;
    * `compile_metamutant/3` and `with_active_mutant/2` verify that selecting a mutant changes
      the compiled program's behaviour.

  > #### Selection is process-global {: .warning}
  >
  > Tests that call `with_active_mutant/2` must use `async: false`, because the active mutant is
  > shared across the VM.

  `import Mutare.Test` in an `ExUnit.Case` to use them:

      defmodule MyMutatorTest do
        use ExUnit.Case, async: true
        import Mutare.Test

        test "swaps + for -" do
          assert node_mutations("1 + 2", MyApp.PlusMutator) == ["1 - 2"]
        end
      end

  ## Driving a live mutant in-process

  The semantic check — *does the mutant actually run?* — compiles a metamutant once, then flips
  the selection switch per id:

      defmodule MyQueryTest do
        use ExUnit.Case, async: false
        import Mutare.Test

        test "the mutant changes the result, not just the source" do
          {[mod], sites} =
            compile_metamutant("defmodule Q do\\n  def n, do: 1 + 1\\nend", [MyApp.PlusMutator])

          id = site_id(sites, {"1 + 1", "1 - 1"})

          assert mod.n() == 2                              # baseline
          assert with_active_mutant(id, fn -> mod.n() end) == 0   # the mutant is live
          assert mod.n() == 2                              # restored
        end
      end
  """

  import ExUnit.Assertions

  alias Mutare.MutationSite
  alias Mutare.Selector

  @typedoc """
  A mutator entry the **source** helpers accept — anything `:mutators` takes: a family
  atom (`:arithmetic`), a custom module, a `{module, opts}` pair, or an already-resolved
  `Mutare.Mutator.Spec`.
  """
  @type mutator ::
          atom() | module() | {atom() | module(), term()} | Mutare.Mutator.Spec.t()

  @doc """
  Returns the rendered node-level mutations for a parsed source snippet.

  This helper calls mutators directly without the transform's resolution passes or
  structural mutations. `mutators` must therefore be a module, a resolved
  `Mutare.Mutator.Spec`, or a list of either; family atoms are not accepted.

  `pipe_mode` defaults to `:unpiped`. Use `:piped` when the snippet represents the
  right side of a pipe and therefore has one implicit argument.

      iex> import Mutare.Test
      iex> node_mutations("1 + 2", Mutare.Mutators.Arithmetic)
      ["1 - 2"]

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

    for {_spec, mutated, _note, _variant} <-
          Mutare.Mutator.Dispatch.mutations(node, List.wrap(mutators), context),
        do: Mutare.AST.to_string(mutated)
  end

  @doc """
  Returns every recorded mutation as
  `{family_name, original_code, mutated_code}`.

  This helper uses the complete transform pipeline, including name resolution, pipe
  handling, overlap suppression, and structural families.

      iex> import Mutare.Test
      iex> diffs("def f(a, b), do: a + b", [Mutare.Mutators.Arithmetic])
      [{:arithmetic, "a + b", "a - b"}]
  """
  @spec diffs(String.t(), [mutator()]) :: [{atom(), String.t(), String.t()}]
  def diffs(source, mutators) do
    result = Mutare.transform_string(source, mutators: mutators)
    for site <- result.mutants, do: {site.mutator, site.original_code, site.mutated_code}
  end

  @doc """
  Returns the `{original_code, mutated_code}` pairs recorded for one family.

  `name` is the recorded family name, including any configured `:as` override.

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
  Transforms `source`, compiles the complete metamutant, and returns its compiled
  `{module, binary}` pairs.

  `source` must contain a complete compilation unit such as a `defmodule`. The
  helper compiles it inside a unique wrapper, captures compiler output, and purges
  all compiled modules before returning.

      defmodule MyMutatorTest do
        use ExUnit.Case, async: true
        import Mutare.Test

        test "every mutant compiles" do
          assert_metamutant_compiles(
            "defmodule Sample do\n  def f(a, b), do: a + b\nend",
            [MyApp.PlusMutator]
          )
        end
      end
  """
  @spec assert_metamutant_compiles(String.t(), [mutator()]) :: [{module(), binary()}]
  def assert_metamutant_compiles(source, mutators) do
    %{metamutant: metamutant} = Mutare.transform_string(source, mutators: mutators)
    {compiled, wrapper} = compile_metamutant_source!(metamutant, true)

    for {module, _binary} <- compiled, do: purge(module)
    purge(wrapper)

    compiled
  end

  @doc """
  Render `source` to its metamutant, compile it, and return `{modules, mutants}`.

  By default, compilation occurs inside a uniquely named wrapper module. This
  prevents module-name collisions and keeps ordinary self-references working.
  Compiled modules are purged when the test process exits.

  Wrapper nesting can capture references to a real module with the same leading
  namespace, and it cannot resolve a forward reference to a later sibling module.
  Use self-contained fixtures with short module names. When top-level names are
  required, pass `uniquify: false` and manage collisions explicitly.

  Each isolated compilation creates permanent module-name atoms, so this helper is
  intended for a bounded set of fixtures rather than an unbounded generated test.

  Options are forwarded to `Mutare.transform_string/2`. `:uniquify` is consumed by
  this helper, and the `mutators` argument overrides any `:mutators` option.

  `modules` are the metamutant's own compiled module atoms (the empty wrapper shell excluded), in
  compilation order — typically a single-element list for a single `defmodule`; `mutants` are
  public `Mutare.MutationSite` DTOs, used to resolve a mutant's id from its logical diff
  (`site_id/2` / `site_by/3`). All compiled modules are purged when the test exits.

      {[module], mutants} =
        compile_metamutant(
          "defmodule Q do\n  def n, do: 1 + 1\nend",
          [MyApp.PlusMutator]
        )

      assert module.n() == 2
      id = site_id(mutants, {"1 + 1", "1 - 1"})
      assert with_active_mutant(id, fn -> module.n() end) == 0
  """
  @spec compile_metamutant(String.t(), [mutator()], keyword()) :: {[module()], [MutationSite.t()]}
  def compile_metamutant(source, mutators, opts \\ []) do
    {isolate?, transform_opts} = Keyword.pop(opts, :uniquify, true)

    result = Mutare.transform_string(source, Keyword.put(transform_opts, :mutators, mutators))

    {compiled, wrapper} = compile_metamutant_source!(result.metamutant, isolate?)
    modules = for {module, _binary} <- compiled, do: module
    loaded = if wrapper, do: [wrapper | modules], else: modules

    ExUnit.Callbacks.on_exit(fn -> Enum.each(loaded, &purge/1) end)

    {modules, result.mutants}
  end

  # Compile a rendered metamutant, capturing stderr (a custom mutator's mutant may warn) and
  # asserting it produced at least one module of its own. The shared core of
  # `compile_metamutant/3` and `assert_metamutant_compiles/2`. Returns `{own_modules, wrapper}`,
  # where `wrapper` is the isolating shell module (`nil` when `isolate?` is false) — the caller
  # keeps it to purge, but it is never reported as a metamutant module.
  #
  # Isolation is by *nesting*, not renaming: the metamutant is wrapped in `defmodule <unique> do
  # … end`, so (a) two compiles of one fixture never redefine a single module name through the
  # global `Code.compile_string`, and (b) a plainly-named top-level `Foo` nests to `<unique>.Foo`
  # and can't collide with a real top-level `Foo`. Elixir's nested-alias rule rebinds a fixture's
  # short-name self-references and backward sibling references (`Foo.b()`, `%Foo{}`, `defimpl`,
  # `__MODULE__`) to the nested name, so the common single-`defmodule` fixture compiles untouched —
  # no source rewriting, no fragile regex. The sharp edge (see the `compile_metamutant/3` doc): the
  # alias rebinds a defined module's *leading* segment, so a namespaced fixture referencing a real
  # same-prefix module, or forward-referencing a later sibling, captures that reference into the
  # wrapper and fails — `uniquify: false` is the escape hatch. The empty wrapper shell is dropped
  # from the returned list (the empties check is on the metamutant's *own* modules, so a
  # non-`defmodule` source still fails — only the shell would compile).
  defp compile_metamutant_source!(metamutant, isolate?) do
    {to_compile, wrapper} =
      if isolate? do
        wrapper = Module.concat(Mutare.Test.Sandbox, :"M#{System.unique_integer([:positive])}")
        {"defmodule #{inspect(wrapper)} do\n#{metamutant}\nend", wrapper}
      else
        {metamutant, nil}
      end

    {compiled, _io} =
      ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(to_compile) end)

    own = Enum.reject(compiled, fn {module, _binary} -> module == wrapper end)

    if own == [] do
      # The wrapper shell still loaded, so purge everything that compiled before raising — the
      # caller never reaches its own purge, and a leaked resident module would otherwise survive.
      for {module, _binary} <- compiled, do: purge(module)

      flunk("metamutant compiled to no modules — is the source a complete `defmodule`?")
    end

    {own, wrapper}
  end

  # Unload a compiled module, reclaiming its code: `delete` makes the current code "old", then
  # `purge` frees it. (The reverse order — `purge` then `delete` — leaves the just-compiled code
  # resident as "old", never reclaimed.) Names are unique per compile, so this only frees memory;
  # it never has to clear the way for a same-name redefinition.
  defp purge(module) do
    :code.delete(module)
    :code.purge(module)
  end

  @doc """
  Runs zero-arity `fun` with mutant `id` selected, then restores the previous
  selection.

  The selector uses VM-wide `:persistent_term` state. Tests that call this helper
  must therefore run with `async: false`; restoration prevents leakage between
  sequential calls but does not isolate concurrent processes.
  """
  @spec with_active_mutant(non_neg_integer(), (-> result)) :: result when result: var
  def with_active_mutant(id, fun) when is_integer(id) and id >= 0 and is_function(fun, 0) do
    previous = Selector.active()
    Selector.put(id)

    try do
      fun.()
    after
      Selector.put(previous)
    end
  end

  @doc """
  Returns the id of the single site matching `{original_code, mutated_code}`.

  A string matches exactly. A `Regex` matches the corresponding code field by
  pattern, and either side may use a different match type. The lookup fails when
  zero or multiple sites match and lists the candidates in the failure message.

  Use `site_by/3` when code matching cannot identify the site.
  """
  @spec site_id([MutationSite.t()], {pattern, pattern}) :: pos_integer()
        when pattern: String.t() | Regex.t()
  def site_id(sites, {original_code, mutated_code}) do
    sites
    |> site_by(inspect({original_code, mutated_code}), fn site ->
      match_code?(site.original_code, original_code) and
        match_code?(site.mutated_code, mutated_code)
    end)
    |> Map.fetch!(:id)
  end

  defp match_code?(code, %Regex{} = pattern), do: code =~ pattern
  defp match_code?(code, pattern) when is_binary(pattern), do: code == pattern

  @doc """
  Returns the single site for which `predicate` returns true.

  `label` identifies the lookup in failure messages. The lookup fails and lists
  candidates when zero or multiple sites match.
  """
  @spec site_by([MutationSite.t()], String.t(), (MutationSite.t() -> boolean())) ::
          MutationSite.t()
  def site_by(sites, label, pred) when is_function(pred, 1) do
    case Enum.filter(sites, pred) do
      [site] ->
        site

      [] ->
        flunk("no site matching #{label}\nrecorded sites:\n#{render_sites(sites)}")

      many ->
        flunk("ambiguous: #{length(many)} sites match #{label}\n#{render_sites(many)}")
    end
  end

  defp render_sites(sites) do
    Enum.map_join(sites, "\n", fn site ->
      "  id=#{site.id} #{site.mutator}: #{inspect(site.original_code)} -> #{inspect(site.mutated_code)}"
    end)
  end
end
