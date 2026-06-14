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

  @timeout_env "MUTARE_TIMEOUT"
  @timeout_exit 124

  # The timeout watcher is how Mutare enforces a per-mutant wall-clock cap
  # *portably*: instead of the runner killing a hung OS process tree (which
  # needs platform-specific signals), the mutant process halts *itself* after
  # the deadline. `System.halt/1` stops the VM immediately and uncatchably, and
  # the BEAM preempts a looping process so the watcher always gets to run; if the
  # suite finishes first the watcher dies with the VM. Exit 124 ⇒ timed out.
  @selector_bootstrap Macro.to_string(Mutare.Selector.bootstrap_ast())

  @bootstrap """
  # ---- injected by Mutare: select the active mutant from the environment ----
  #{@selector_bootstrap}

  # ---- injected by Mutare: per-mutant timeout (self-halt; no external kill) --
  case System.get_env(#{inspect(@timeout_env)}) do
    nil -> :ok
    "" -> :ok
    raw -> spawn(fn -> Process.sleep(String.to_integer(raw)); System.halt(#{@timeout_exit}) end)
  end
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

  @doc "Env var the runner sets to give a mutant run its wall-clock cap (ms)."
  @spec timeout_env() :: String.t()
  def timeout_env, do: @timeout_env

  @doc "Exit code the self-halt watcher uses, signalling a timed-out mutant."
  @spec timeout_exit() :: non_neg_integer()
  def timeout_exit, do: @timeout_exit

  @doc """
  Run `mix <args>` in `sandbox` as a fresh OS process, returning
  `{output, exit_status}`.

  `MIX_ENV=test` and `MUTANT_UNDER_TEST=<mutant_id>` are always set. `cap` (ms,
  or `nil`) is handed to the injected timeout watcher, which halts the run itself
  if it overruns — so there is no process tree to kill and nothing
  platform-specific.
  """
  @spec mix(Path.t(), [String.t()], String.t(), pos_integer() | nil) ::
          {String.t(), non_neg_integer()}
  def mix(sandbox, args, mutant_id, cap \\ nil) do
    env =
      [{"MIX_ENV", "test"}, {Mutare.Selector.env_var(), mutant_id}]
      |> maybe_cap(cap)

    System.cmd("mix", args, cd: sandbox, stderr_to_stdout: true, env: env)
  end

  @doc """
  Like `mix/4`, but wall-clock-timed: returns `{elapsed_ms, output, exit_status}`.
  """
  @spec timed_mix(Path.t(), [String.t()], String.t(), pos_integer() | nil) ::
          {non_neg_integer(), String.t(), non_neg_integer()}
  def timed_mix(sandbox, args, mutant_id, cap \\ nil) do
    {micros, {output, status}} = :timer.tc(fn -> mix(sandbox, args, mutant_id, cap) end)
    {div(micros, 1000), output, status}
  end

  # --- internals -----------------------------------------------------------

  defp maybe_cap(env, nil), do: env
  defp maybe_cap(env, cap), do: [{@timeout_env, Integer.to_string(cap)} | env]

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
