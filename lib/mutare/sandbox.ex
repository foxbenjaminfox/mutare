defmodule Mutare.Sandbox do
  @moduledoc """
  Materialise a schema as a runnable copy of the target project.

  We copy the project to a dedicated directory (excluding build output), write
  each metamutant over its original, and inject a tiny bootstrap into
  `test/test_helper.exs` that reads `MUTANT_UNDER_TEST` into `:persistent_term`
  before the suite starts. The bootstrap is plain Erlang/Elixir with no
  dependency on Mutare, so the sandbox needs nothing added to its deps.

  Full-copy isolation is the simplest correct choice; swapping it for a shared
  build path is an open question (see DESIGN.md) to settle by measuring on a
  large umbrella.
  """

  alias Mutare.Schema

  @excluded ~w(_build .git .elixir_ls .lexical cover)

  # Kept in sync with Mutare.Selector so the bootstrap matches what the
  # metamutant reads.
  @bootstrap """
  # ---- injected by Mutare: select the active mutant from the environment ----
  :persistent_term.put(
    #{inspect(Mutare.Selector.key())},
    case System.get_env(#{inspect(Mutare.Selector.env_var())}) do
      nil -> #{Mutare.Selector.baseline()}
      "" -> #{Mutare.Selector.baseline()}
      raw -> String.to_integer(raw)
    end
  )
  # ---------------------------------------------------------------------------
  """

  @doc """
  Prepare a sandbox for `schema` taken from `root`. Returns the sandbox path.

  Options: `:sandbox` — target directory (default: a fresh temp dir).
  """
  @spec prepare(Path.t(), Schema.t(), keyword()) :: Path.t()
  def prepare(root, %Schema{} = schema, opts \\ []) do
    sandbox = Keyword.get_lazy(opts, :sandbox, &default_sandbox/0)

    File.rm_rf!(sandbox)
    File.mkdir_p!(sandbox)

    copy_project(root, sandbox)
    write_metamutants(sandbox, schema)
    inject_bootstrap(sandbox)

    sandbox
  end

  @doc "The bootstrap snippet prepended to the sandbox's test helper."
  @spec bootstrap() :: String.t()
  def bootstrap, do: @bootstrap

  # --- internals -----------------------------------------------------------

  defp default_sandbox do
    Path.join(System.tmp_dir!(), "mutare_sandbox_#{System.unique_integer([:positive])}")
  end

  defp copy_project(root, sandbox) do
    for entry <- File.ls!(root), entry not in @excluded do
      File.cp_r!(Path.join(root, entry), Path.join(sandbox, entry))
    end
  end

  defp write_metamutants(sandbox, %Schema{metamutants: metamutants}) do
    for {rel, source} <- metamutants do
      path = Path.join(sandbox, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end
  end

  defp inject_bootstrap(sandbox) do
    helper = Path.join(sandbox, "test/test_helper.exs")
    File.mkdir_p!(Path.dirname(helper))
    existing = if File.exists?(helper), do: File.read!(helper), else: "ExUnit.start()\n"
    File.write!(helper, @bootstrap <> "\n" <> existing)
  end
end
