defmodule Mutare.Test.Metamutant do
  @moduledoc """
  Assertions and pins over what `Mutare.Transform` emits — the rendered metamutant string and
  its internal `%Mutare.Site{}`s.

  `import Mutare.Test.Metamutant` into a test module. Every compile here goes through
  `Mutare.Test.Compile`, so nothing touches the global `:stderr` device and all of it is safe
  under `async: true` (a test that *flips the selector* still needs `async: false` — that is
  `:persistent_term`, not the compile).

  The two pins (`lifted_pattern/3`, `selector_tuple/0`) are the one place a test spells the
  shape of generated code: a lifted group's private base name is derived from
  `Mutare.Transform.LiftedEmit.base_name/4`, so a change to that composition moves every
  assertion with it.
  """

  import ExUnit.Assertions

  alias Mutare.Coverage.Recorder
  alias Mutare.Test.Compile
  alias Mutare.Transform
  alias Mutare.Transform.LiftedEmit

  @doc """
  The internal `%Mutare.Site{}`s one family recorded for `source` — what `Mutare.Test.diffs_for/4`
  reads, kept as the core struct so the suite can assert on placement (`kind`, `Site.describe/1`)
  that the public `Mutare.MutationSite` deliberately omits. `mutators` and `opts` are as for
  `Mutare.Transform.transform_string_with_sites/2`.
  """
  def family_sites(source, mutators, name, opts \\ []) do
    {_meta, sites, _next_id} =
      Transform.transform_string_with_sites(source, Keyword.put(opts, :mutators, mutators))

    Enum.filter(sites, &(&1.mutator == name))
  end

  @doc "Asserts `meta` compiles to at least one module; returns the `[{module, binary}]` list."
  def assert_compiles(meta, file \\ "nofile") do
    assert [_ | _] = modules = Compile.string(meta, file)
    modules
  end

  @doc """
  Asserts that compiling `meta` fails with a `CompileError`, and that every substring in
  `message` (one, or a list — for tokens common to several Elixir phrasings) appears in the
  `:error` diagnostics. Returns those diagnostics' messages, newline-joined.
  """
  def assert_compile_error(meta, message \\ [], file \\ "nofile") do
    {result, diagnostics} = Compile.string_result(meta, file)
    assert {:error, %CompileError{}} = result

    errors =
      diagnostics
      |> Enum.filter(&(&1.severity == :error))
      |> Compile.messages()
      |> Enum.join("\n")

    for m <- List.wrap(message) do
      assert errors =~ m, "expected a compile error mentioning #{inspect(m)}, got:\n#{errors}"
    end

    errors
  end

  @doc """
  The compiler's *own* stderr for a `meta` that fails to compile (asserting it does fail with
  a `CompileError`, and that every substring in `message` appears in that output).

  This is the one helper here that captures the global `:stderr` device — for tests that hand
  the compiler's real output to `Mutare.Poison.ids/2`, whose contract *is* that text. The
  calling module must be `async: false`. Anything that only needs the messages wants
  `assert_compile_error/3` instead.
  """
  def compile_error_output(meta, message \\ [], file \\ "nofile") do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise CompileError, fn -> Code.compile_string(meta, file) end
      end)

    for m <- List.wrap(message) do
      assert stderr =~ m,
             "expected the compile error output to mention #{inspect(m)}, got:\n#{stderr}"
    end

    stderr
  end

  @doc """
  Asserts `meta` compiles; returns `{modules, warnings}` — the `[{module, binary}]` list and
  the warnings as one newline-joined string.
  """
  def compile_with_warnings(meta, file \\ "nofile") do
    {modules, diagnostics} = Compile.string_with_diagnostics(meta, file)
    assert [_ | _] = modules

    warnings =
      diagnostics
      |> Enum.filter(&(&1.severity == :warning))
      |> Compile.messages()
      |> Enum.join("\n")

    {modules, warnings}
  end

  @doc """
  Just the warnings of `compile_with_warnings/2`, for
  `refute compile_warnings(meta) =~ "is unused"`.
  """
  def compile_warnings(meta, file \\ "nofile"), do: meta |> compile_with_warnings(file) |> elem(1)

  @doc """
  Compiles `meta` (asserting it does) and purges `module` when the calling test exits, so a
  fixture name can be redefined by the next test without a redefinition warning.
  """
  def compile_purging(module, meta, file \\ "nofile") do
    modules = assert_compiles(meta, file)

    ExUnit.Callbacks.on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    modules
  end

  @doc """
  `compile_purging/3` with the metamutant's coverage sink swapped for `sink`: the emitted
  `Recorder.fixture_module().hit(ids)` calls are redirected to `sink.hit/1`, so a
  test observes which ids a call covers without the real (ETS) recorder. The coverage *gate*
  the transform generated is kept as is — only the sink changes.
  """
  def compile_observed(module, meta, sink) when is_atom(sink) do
    observed =
      String.replace(meta, "#{inspect(Recorder.fixture_module())}.hit(", "#{inspect(sink)}.hit(")

    compile_purging(module, observed)
  end

  @doc """
  The private base name lifting gives group `group` of `fun/arity` — e.g.
  `lifted_name(:classify, 1, 1)` is `"__mutare_classify_1_g1"`. `:prefix` overrides the
  canonical generated-name prefix (a file whose source already uses it gets a salted one).
  """
  def lifted_name(fun, arity, group, opts \\ []) when is_atom(fun) and is_integer(group) do
    LiftedEmit.base_name(fun, arity, group, Keyword.get(opts, :prefix, "__mutare_"))
  end

  @doc """
  A regex *fragment* matching the lifted base name of any group of `fun/arity` — the group
  number is unknown to a test that only cares the group was lifted. Interpolate it:

      assert meta =~ ~r/defp \#{lifted_pattern(:f, 1)}\\(mutare_active,/
  """
  def lifted_pattern(fun, arity, opts \\ []) do
    stem = fun |> lifted_name(arity, 0, opts) |> String.replace_suffix("0", "")
    Regex.escape(stem) <> "\\d+"
  end

  @doc """
  The opening of the in-place selector the transform weaves into a body: the outer `case`
  over the inner `case` that reads the active mutant. `assert meta =~ selector_tuple()`
  pins that a mutant was delivered in place (not lifted).
  """
  def selector_tuple, do: "case (case {mutare_active,"
end
