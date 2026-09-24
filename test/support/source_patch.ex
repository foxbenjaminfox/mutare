defmodule Mutare.Test.SourcePatch do
  @moduledoc """
  The report's contract, checked end to end: patching the **original source** at a site's range
  with its `mutated_code` yields a program that behaves as the metamutant does with that mutant
  active — and the unpatched source as the metamutant with none.

  That is what a survivor's diff promises a user, and it is independent of how the mutant was
  delivered: a test that only compares `original_code`/`mutated_code` strings cannot notice a
  range that covers the wrong span, or a rendering that does not mean what was compiled.

  Selects mutants through `Mutare.Test.with_active_mutant/2`, on the test module's private
  key (`Mutare.Test.isolate_selector/0`, taken before the transform), so callers may run
  `async: true`.
  """
  import ExUnit.Assertions

  alias Mutare.Test.Compile

  @typedoc "A call to make on the fixture module: `{function, arguments}`."
  @type call :: {atom(), [term()]}

  @doc """
  Transform and compile `source` (one `defmodule`), then check every site — and the baseline —
  against its source patch over `calls`. Returns the sites.
  """
  @spec assert_patches(String.t(), [Mutare.Test.mutator()], [call()], keyword()) :: [
          Mutare.Site.t()
        ]
  def assert_patches(source, mutators, calls, opts \\ []) do
    Mutare.Test.isolate_selector()
    {[module], sites} = Mutare.Test.compile_metamutant(source, mutators, opts)

    for site <- [nil | sites] do
      patched = if site, do: patch(source, site), else: source
      {reference, compiled} = compile_reference!(patched, site)

      try do
        id = if site, do: site.id, else: 0

        for call <- calls do
          got = Mutare.Test.with_active_mutant(id, fn -> outcome(module, call) end)
          expected = outcome(reference, call)

          assert got == expected, """
          #{describe(site)} diverges from its source patch on #{inspect(call)}:
            metamutant: #{inspect(got)}
            patched:    #{inspect(expected)}
          patched source:
          #{patched}
          """
        end
      after
        Enum.each(compiled, &purge/1)
      end
    end

    sites
  end

  @doc "The original source with `site`'s change applied at its range."
  @spec patch(String.t(), Mutare.Site.t()) :: String.t()
  def patch(source, site) do
    change = if site.operation == :delete, do: "", else: site.mutated_code
    Sourceror.patch_string(source, [%{range: site.range, change: change}])
  end

  # Nest the patched source in a uniquely named shell, as `compile_metamutant/3` does, and
  # return the fixture module inside it.
  defp compile_reference!(patched, site) do
    shell = Module.concat(__MODULE__, :"R#{System.unique_integer([:positive])}")

    case Compile.string_result("defmodule #{inspect(shell)} do\n#{patched}\nend") do
      {{:ok, compiled}, _diagnostics} ->
        [module] = for {module, _binary} <- compiled, module != shell, do: module
        {module, Enum.map(compiled, &elem(&1, 0))}

      {{:error, _exception}, diagnostics} ->
        flunk("""
        #{describe(site)}: its source patch does not compile.
        #{Enum.map_join(Compile.messages(diagnostics), "\n", &("  " <> &1))}
        patched source:
        #{patched}
        """)
    end
  end

  defp outcome(module, {fun, args}) do
    {:ok, apply(module, fun, args)}
  rescue
    exception -> {:raised, exception.__struct__}
  catch
    kind, reason -> {kind, reason}
  end

  defp describe(nil), do: "the baseline"

  defp describe(site),
    do: "mutant #{site.id} (#{site.mutator}: #{site.original_code} → #{site.mutated_code})"

  defp purge(module) do
    :code.delete(module)
    :code.purge(module)
  end
end
