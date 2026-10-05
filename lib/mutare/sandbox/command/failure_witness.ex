defmodule Mutare.Sandbox.Command.FailureWitness do
  @moduledoc """
  Record, from inside a mutant's `mix test`, that one of its tests failed — evidence the
  exit code can lose.

  `--exit-status` (`Mutare.Sandbox.Command.Exit.failure/0`) is Mix's verdict on a
  suite that ran to its end. A run that crashes *after* a test failed never reaches that
  verdict: ExUnit stops its formatters after reading its statistics, and a formatter that
  crashed on the failure — ExUnit's own CLI formatter raises printing an assertion message
  that is not valid UTF-8 — takes the run down with it, so `mix test` exits `1`. The
  failure report would have been printed by the formatter that died, so the output holds
  none either. Without a witness such a run is a harness error, though the mutation was
  detected.

  So the test bootstrap adds one more formatter (`install_ast/0`, rendered by
  `Mutare.Sandbox` after the user's helper, so after its `ExUnit.start/1`). It counts a
  failure exactly where `ExUnit.RunnerStats` does — a finished test in state `:failed` or
  `:invalid`, or a test that passed in a module whose `setup_all` or `on_exit` then
  failed — and on the first one creates the file `env/0` names, before handling another
  event. `Mutare.Sandbox.Command.timed_test/4` chooses that path per run
  (`fresh_path/0`), arms it through the `:failure_witness` run option of
  `Mutare.Sandbox.Command.Invocation`, and reads it back with `take/1`.

  ## One-directional evidence

  Formatters receive events as casts, so the witness races whatever ends the run: the VM
  can halt before the file is written. A file that exists proves a test failed; a missing
  file proves nothing. `Mutare.Sandbox.Command.outcome/3` therefore reads the witness only
  to refine the harness-error bucket into a kill, and never uses its absence — a pass is
  still exit `0` and nothing else.

  The snippet appends to the formatters the user's helper configured (`mix test` touches
  that list only under `--formatter`, which Mutare never passes), and is inert unless
  `env/0` is set, so a manual `mix test` in a kept sandbox is unaffected.
  """

  @env "MUTARE_FAILURE_WITNESS"
  # The formatter module the snippet defines in the target's test VM — an Erlang-style
  # atom, so it cannot collide with a target's own module.
  @formatter :mutare_failure_witness

  @typedoc """
  What a run's witness file says: `:test_failed` when it exists, `:none` otherwise — which
  is no evidence either way.
  """
  @type t :: :test_failed | :none

  @doc "Env var naming the absolute path the witness creates when a test fails."
  @spec env() :: String.t()
  def env, do: @env

  @doc """
  A path no other run uses, outside the sandbox (so neither mode's materialisation ever
  sees it). Unique across concurrent Mutare processes by the OS pid, within one by the
  integer.
  """
  @spec fresh_path() :: Path.t()
  def fresh_path do
    Path.join(
      System.tmp_dir!(),
      "mutare_failure_witness_#{System.pid()}_#{System.unique_integer([:positive])}"
    )
  end

  @doc "Read the witness at `path` and remove it."
  @spec take(Path.t()) :: t()
  def take(path) do
    case File.rm(path) do
      :ok -> :test_failed
      {:error, :enoent} -> :none
    end
  end

  @doc """
  The dependency-free snippet that defines the witness formatter (once per VM: an umbrella
  evaluates every app's helper in one) and appends it to ExUnit's formatters.
  """
  @spec install_ast() :: Macro.t()
  def install_ast do
    env = @env
    formatter = @formatter

    quote do
      case System.get_env(unquote(env)) do
        nil ->
          :ok

        "" ->
          :ok

        _armed ->
          unless Code.ensure_loaded?(unquote(formatter)) do
            defmodule unquote(formatter) do
              @moduledoc false
              use GenServer

              @impl true
              def init(_opts), do: {:ok, System.fetch_env!(unquote(env))}

              # `ExUnit.RunnerStats`' failure count, read off the same two events.
              @impl true
              def handle_cast({:test_finished, %{state: {tag, _}}}, path)
                  when tag in [:failed, :invalid],
                  do: witness(path)

              def handle_cast({:module_finished, %{state: {:failed, _}, tests: tests}}, path) do
                if Enum.any?(tests, &is_nil(&1.state)), do: witness(path), else: {:noreply, path}
              end

              def handle_cast(_event, path), do: {:noreply, path}

              # Never `File.write!`: a formatter that raises ends the run at ExUnit's
              # teardown — the very failure this witness exists to see past.
              defp witness(path) do
                _ = File.write(path, "")
                {:noreply, path}
              end
            end
          end

          formatters = Keyword.get(ExUnit.configuration(), :formatters, [])

          ExUnit.configure(formatters: Enum.uniq(formatters ++ [unquote(formatter)]))
      end
    end
  end
end
