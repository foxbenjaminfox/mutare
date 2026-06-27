defmodule Mutare.Test do
  @moduledoc """
  Test helpers for projects that implement their own `Mutare.Mutator`.

  A custom-mutator project wants to assert three things: what a single mutator offers for a
  parsed node (the pure-AST path, `node_mutations/3` below), what the *whole* transform
  records for a source string (`Mutare.transform_string/2`, which adds alias/import
  resolution, pipe handling, and equivalent-sibling suppression), and — the *semantic* check —
  that a recorded mutant is **live**: that flipping its id actually changes what the compiled
  code does, not just the source on disk. The first two wrap parse-in / render-out around
  Mutare's public surface; the third compiles a real metamutant and drives the selection switch.
  Without these every such project re-implements the same harness — and reaches into the private
  `:persistent_term` selection contract to do it.

  The AST helpers route through `Mutare.AST.parse!/1` and `Mutare.AST.to_string/1`, so a
  consumer needs no direct `:sourceror` dependency; the live-mutant helpers manage the
  selection key for you, so a consumer never hardcodes it or its baseline — both are
  Mutare-internal and resolved at runtime (the key is even reconfigurable under self-hosting).
  Depend on these, not on the contracts behind them.

  > #### Selection is process-global {: .warning}
  >
  > `with_active_mutant/2` flips the active mutant by writing a
  > VM-wide `:persistent_term` slot every compiled metamutant reads. A test module that drives a
  > live mutant must therefore be `use ExUnit.Case, async: false` — two `async` modules sharing
  > the one slot would clobber each other's active id. (Mutare's own `selector_test.exs` is
  > `async: false` for exactly this reason.)

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
    * `compile_metamutant/3` — the **live** path's workhorse: render `source`, compile it inside a
      uniquely-named wrapper module (so two compiles never redefine one module name through the
      global compiler, and the fixture's modules can't collide with real top-level ones), and
      return `{modules, sites}`. The compiled modules are purged on test exit. Look a mutant's id
      up from `sites` with `site_id/2` / `site_by/3`.
    * `with_active_mutant/2` — run a body with a chosen mutant id active (restored
      after), against modules you already compiled with `compile_metamutant/3`. The
      compile-once / run-under-many-ids pattern a semantic test wants. Requires `async: false`
      (see the warning above).

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

  alias Mutare.Selector
  alias Mutare.Site

  @typedoc """
  A mutator entry the **source** helpers accept — anything `:mutators` takes: a family
  atom (`:arithmetic`), a custom module, a `{module, opts}` pair, or an already-resolved
  `Mutare.Mutator.Spec`.
  """
  @type mutator ::
          atom() | module() | {atom() | module(), term()} | Mutare.Mutator.Spec.t()

  @doc """
  The rendered mutations a single mutator (or list) offers for a parsed top-level node —
  the pure-AST path, with no transform pre-pass, so only
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

    for {_spec, mutated, _note} <-
          Mutare.Mutator.Dispatch.mutations(node, List.wrap(mutators), context),
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

  `name` is the recorded family name — a built-in's `c:Mutare.Mutator.name/0`, or the `:as`
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

  `source` must be a complete compilation unit (a `defmodule`, not a bare `def`); the metamutant
  is compiled inside a uniquely-named wrapper module — the same isolation `compile_metamutant/3`
  uses, so a self-referential fixture compiles and repeated calls never clash — then purged.
  Returns the `[{module, binary}]` the metamutant's own modules compiled to (the wrapper shell
  excluded). Compiler output is captured so a mutant's compile-time warning never noises up the
  suite.

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
    {compiled, wrapper} = compile_metamutant_source!(metamutant, true)

    for {module, _binary} <- compiled, do: purge(module)
    purge(wrapper)

    compiled
  end

  @doc """
  Render `source` to its metamutant, compile it, and return `{modules, sites}`.

  The render-and-compile half of a semantic test: it compiles the rendered metamutant inside a
  uniquely-named wrapper module, so compiling the same fixture more than once never redefines a
  single module name through the global `Code.compile_string`, and a plainly-named fixture can't
  collide with a real top-level module. Isolation is by *nesting*: a metamutant `Foo` nests to
  `<wrapper>.Foo`, and Elixir's nested-alias rule rebinds a fixture's short-name self-references
  and *backward* sibling references (`Q.f()`, `%Q{}`, `__MODULE__`, a sibling defined earlier in
  the source) to the nested name — so the common single-`defmodule` fixture compiles untouched, no
  source rewriting.

  The nesting has one sharp edge, since that alias rebinds a defined module's *leading* segment: a
  fixture under a multi-segment namespace that references a **real same-prefix** module
  (`defmodule MyApp.Worker` calling `MyApp.Config.f()`), or that **forward-references** a
  later-defined sibling, has that reference captured into the wrapper's namespace
  (`<wrapper>.MyApp.Config`) and fails to resolve — and at runtime `__MODULE__` is the nested name,
  not the written one. Keep a fixture self-contained under a plain name, or pass `uniquify: false`
  (below) to compile at the real top-level names and manage collisions yourself.

  Each call also mints a fresh wrapper atom (plus the nested module atoms the metamutant compiles
  to), and atoms are never reclaimed — so this is for a bounded number of fixtures, not a
  generative (PropCheck/StreamData) loop that would compile thousands of distinct sources.

  `modules` are the metamutant's own compiled module atoms (the empty wrapper shell excluded), in
  compilation order — typically a single-element list for a single `defmodule`; `sites` are the
  `Mutare.Site`s, used to resolve a mutant's id from its logical diff (`site_id/2` / `site_by/3`).
  All compiled modules are purged when the test exits.

  Needs no coverage setup: every metamutant module carries an
  `@compile {:no_warn_undefined, …}` for the coverage helper it references, and that `hit/1` is
  gated off at baseline, so the reference compiles clean and never fires here.

  `opts` are forwarded to `Mutare.transform_string/2` (e.g. `:expand_uses`, `:macros`,
  `:start_id`), except:

    * `:uniquify` — compile inside the isolating wrapper (default `true`; pass `false` to compile
      the metamutant at its own top-level names, when you manage isolation yourself). A passed-in
      `:mutators` is overridden by the `mutators` argument.

      defmodule MyMutatorTest do
        use ExUnit.Case, async: false
        import Mutare.Test

        test "the mutant runs" do
          {[mod], sites} =
            compile_metamutant("defmodule Q do\\n  def n, do: 1 + 1\\nend", [MyApp.PlusMutator])

          assert mod.n() == 2
          assert with_active_mutant(site_id(sites, {"1 + 1", "1 - 1"}), fn -> mod.n() end) == 0
        end
      end
  """
  @spec compile_metamutant(String.t(), [mutator()], keyword()) :: {[module()], [Site.t()]}
  def compile_metamutant(source, mutators, opts \\ []) do
    {isolate?, transform_opts} = Keyword.pop(opts, :uniquify, true)

    {metamutant, sites, _next_id} =
      Mutare.transform_string(source, Keyword.put(transform_opts, :mutators, mutators))

    {compiled, wrapper} = compile_metamutant_source!(metamutant, isolate?)
    modules = for {module, _binary} <- compiled, do: module
    loaded = if wrapper, do: [wrapper | modules], else: modules

    ExUnit.Callbacks.on_exit(fn -> Enum.each(loaded, &purge/1) end)

    {modules, sites}
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
  Run `fun` with mutant `id` active, restoring the previous active id afterwards.

  Sets the selection switch on the same runtime-resolved key the
  metamutant reads, so this is correct even under self-hosting (it never hardcodes
  `:mutare_active`) — runs the zero-arity `fun` (typically building/calling into modules you
  compiled with `compile_metamutant/3`), and restores whatever was active before, so one
  assertion can't leak an active id into the next.

  The slot is VM-wide — one `:persistent_term` shared by every process — so the enclosing test
  module must be `async: false` (see the module warning); the save/restore only sequences calls
  *within* one process.

      {[mod], sites} = compile_metamutant(source, mutators)
      baseline = mod.run()                                       # id 0
      mutant   = with_active_mutant(site_id(sites, diff), fn -> mod.run() end)
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
  The id of the single site whose recorded diff matches `{original_code, mutated_code}`.

  Sites carry the *logical* before/after a report would show (`a + b` → `a - b`), never any
  selector/scaffolding, so a semantic test names a mutant the way the report does and resolves it
  to the id the switch selects on. Each slot matches by its **type**: a string matches **exactly**
  — `{"1 + 1", "1 - 1"}` can't accidentally resolve to a `"11 + 1"` site — while a `Regex` matches
  by pattern, for the whole-statement diffs a fragment can't name verbatim (an in-place mutator
  that replaces a large node records the whole enclosing expression): `{~r/limit: 2/, ~r/limit:
  3/}`. The two slots opt in independently, so you can pin `original` exactly and loosen only
  `mutated`; anchor a regex (`~r/\\b1 \\+ 1\\b/`) to recover exactness within the loose mode.
  Either way it flunks (listing the candidates) on zero *or* multiple matches, so a fixture whose
  mutation silently stopped being emitted — or whose pattern grew an unexpected sibling — fails
  loudly instead of resolving to the wrong mutant. Reach for `site_by/3` when even a regex pair
  can't express the match.
  """
  @spec site_id([Site.t()], {pattern, pattern}) :: pos_integer()
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
  The single site satisfying `pred`, returned whole (read `.id` for the selector id).

  The same exactly-one guarantee as `site_id/2`, for the cases an `{original, mutated}` pair can't
  express even as regexes — e.g. matching on `.mutator` (or another field), or a mutant recognized
  by the *absence* of a token in its output.
  `label` names the lookup in the failure message. Flunks (listing the candidates) on zero *or*
  multiple matches, so an ad-hoc `Enum.find/2` can't silently resolve to the first of several.
  """
  @spec site_by([Site.t()], String.t(), (Site.t() -> boolean())) :: Site.t()
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
