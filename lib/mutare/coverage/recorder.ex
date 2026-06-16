defmodule Mutare.Coverage.Recorder do
  @moduledoc """
  The generated-code side of coverage capture: the contract the metamutant and
  the test bootstrap share to record coverage **synchronously, in the test
  process**, with no race.

  `Mutare.Coverage` reads what this produces; this module owns *how it is
  produced*. There are three pieces, all emitted into generated code:

    * `record_ast/1` — spliced by `Mutare.Transform` into every selector
      catch-all. At baseline, under a tracking flag, it records the site's mutant
      ids into shared ETS — in whatever process runs the line, including the test
      process. (`Mutare.Selector` owns the *selection* contract the same way.)
    * `helper_source/0` — a dependency-free helper module
      (`Mutare.Sandbox` writes it into the sandbox) holding the ETS writes and the
      end-of-suite dump, so the per-site code stays a single call and the
      OTP-version-tolerant label read lives in one place.
    * `setup_ast/0` and `after_suite_ast/0` — injected around the target's
      `test_helper.exs`; when the probe env var is set, setup creates the tables
      and flips the tracking flag before user helper code runs, while the
      after-suite hook is registered after the helper has started ExUnit.

  ## Why this, not `:cover`

  `:cover`'s counters live in a single global table keyed `{module, line}` — there
  is no per-process partition, so attributing coverage to a test in *one* run
  needs a snapshot at each test boundary, and the only global per-test signal
  ExUnit emits is an **async cast to formatters** that races test execution
  (fast `async: false` modules' coverage is lost). The metamutant, by contrast,
  *is* code we generate and that runs synchronously in the test process. So the
  capture lives there, accumulate-only (never reset), keyed by mutant id directly.

  ## The gate (why it is inert outside the probe)

  The spliced expression is `mutare_active == 0 and
  :persistent_term.get(:mutare_track, false) and <helper>.hit([<ids>])`:

    * per-mutant runs (`mutare_active != 0`) short-circuit on the integer compare —
      ~zero hot-loop cost;
    * the baseline green run and Mutare's own unit tests (`:mutare_track` unset)
      short-circuit on the persistent-term read — the helper is never *called*;
    * only the probe run (`MUTARE_COVERAGE` set → `:mutare_track` true,
      `mutare_active == 0`) records.

  The helper's `hit/1` returns `true` so the `and` chain stays boolean (an `:ets`
  call returns an int/`true` and would raise `BadBooleanError` mid-`and`).
  """

  @env_var "MUTARE_COVERAGE"
  @track_key :mutare_track
  @agg_table :mutare_cov_agg
  @attr_table :mutare_cov_attr
  @dump_file "mutare_cov.terms"
  @helper_module :mutare_cov

  # The catch-all binds the selector subject to this variable so `record_ast/1`
  # can reuse it (no second `:persistent_term` read). `Mutare.Transform` uses
  # `catch_all_pattern/0`; both must agree on the name.
  @var_name :mutare_active

  @doc "Env var the probe sets to turn coverage recording on for one run."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "The `:persistent_term` flag the spliced record reads (`false` by default)."
  @spec track_key() :: atom()
  def track_key, do: @track_key

  @doc "The file (relative to the sandbox) the end-of-suite dump is written to."
  @spec dump_file() :: String.t()
  def dump_file, do: @dump_file

  @doc "The dependency-free helper module emitted into the sandbox."
  @spec helper_module() :: module()
  def helper_module, do: @helper_module

  @doc """
  The catch-all clause pattern that binds the selector subject: `mutare_active`.

  `Mutare.Transform` uses this in place of the old `_` so `record_ast/1` can read
  the active id without a second `:persistent_term` lookup.
  """
  @spec catch_all_pattern() :: Macro.t()
  def catch_all_pattern, do: {@var_name, [], nil}

  @doc """
  The expression `Mutare.Transform` prepends to a catch-all body to record that
  this selector's mutant `ids` ran (see the moduledoc for the gate).

  Hand-built (not `quote`d) to share the `mutare_active` binding `catch_all_pattern/0`
  introduces and to splice `ids` as a plain literal list.
  """
  @spec record_ast([pos_integer()]) :: Macro.t()
  def record_ast(ids) when is_list(ids) do
    active_zero = {:==, [], [{@var_name, [], nil}, 0]}
    track_read = {{:., [], [:persistent_term, :get]}, [], [@track_key, false]}
    hit_call = {{:., [], [@helper_module, :hit]}, [], [ids]}

    {:and, [], [{:and, [], [active_zero, track_read]}, hit_call]}
  end

  @doc """
  Source of the dependency-free coverage helper `Mutare.Sandbox` writes into
  the sandbox (compiled once, with the app).

  `hit/1` records into the shared ETS tables; `dump/1` (run by `after_suite`)
  serialises them to `dump_file/0`, mapping each test module to its source file.
  The label read is OTP-version-tolerant: `:proc_lib.get_label/1` on OTP 27+,
  the `:"$process_label"` process-dictionary key on OTP 26.
  """
  @spec helper_source() :: String.t()
  def helper_source do
    agg = @agg_table
    attr = @attr_table
    dump_file = @dump_file
    helper = @helper_module

    quote do
      defmodule unquote(helper) do
        @moduledoc false

        def hit(ids) do
          label = label()

          Enum.each(ids, fn id ->
            :ets.insert(unquote(agg), {id})

            case label do
              {mod, _name} when is_atom(mod) -> :ets.insert(unquote(attr), {{mod, id}})
              _ -> :ok
            end
          end)

          true
        end

        def dump(_suite_result) do
          # Serialise plain data (lists, not `MapSet`s) so the reader makes no
          # assumption about a struct's wire representation.
          aggregate = for {id} <- :ets.tab2list(unquote(agg)), do: id

          by_file =
            Enum.reduce(:ets.tab2list(unquote(attr)), %{}, fn {{mod, id}}, acc ->
              case source_file(mod) do
                nil -> acc
                file -> Map.update(acc, file, [id], &[id | &1])
              end
            end)

          payload = %{aggregate: aggregate, by_file: by_file}
          File.write!(unquote(dump_file), :erlang.term_to_binary(payload))
        end

        defp label do
          # `apply/3`, not a direct call: `:proc_lib.get_label/1` exists only on
          # OTP 27+, and a static reference warns "undefined" on OTP 26 (where the
          # `function_exported?` guard already routes us to the proc-dict key the
          # OTP 26 `Process.set_label/1` writes).
          if function_exported?(:proc_lib, :get_label, 1) do
            apply(:proc_lib, :get_label, [self()])
          else
            Process.get(:"$process_label")
          end
        end

        defp source_file(mod) do
          with {:module, _} <- Code.ensure_loaded(mod),
               info when is_list(info) <- mod.module_info(:compile),
               source when not is_nil(source) <- Keyword.get(info, :source) do
            source |> to_string() |> Path.relative_to_cwd()
          else
            _ -> nil
          end
        end
      end
    end
    |> Macro.to_string()
  end

  @doc """
  The setup snippet `Mutare.Sandbox` prepends before the target's test helper.

  Inert unless `env_var/0` is set: only the probe run creates the tables and sets
  the tracking flag. This runs before user helper code so coverage caused by app
  startup or helper setup is not missed. The tables are owned by the test-helper
  process, which hosts the `at_exit` suite run and so outlives it.
  """
  @spec setup_ast() :: Macro.t()
  def setup_ast do
    env_var = @env_var
    track_key = @track_key
    agg = @agg_table
    attr = @attr_table

    quote do
      if System.get_env(unquote(env_var)) not in [nil, ""] do
        # An umbrella runs every app's `test_helper.exs` in one BEAM, so the tables
        # must be created once and shared. Guard on the aggregate table's existence
        # (both are created together) so the second app's setup is a no-op rather
        # than an `:ets.new` `:badarg`.
        if :ets.whereis(unquote(agg)) == :undefined do
          :ets.new(unquote(agg), [:named_table, :public, :set, write_concurrency: true])
          :ets.new(unquote(attr), [:named_table, :public, :set, write_concurrency: true])
        end

        :persistent_term.put(unquote(track_key), true)
      end
    end
  end

  @doc """
  The after-suite snippet `Mutare.Sandbox` appends after the target's test helper.

  `ExUnit.after_suite/1` requires ExUnit to have been started, so registration
  stays after the user's helper even though coverage tracking starts before it.
  """
  @spec after_suite_ast() :: Macro.t()
  def after_suite_ast do
    env_var = @env_var
    helper = @helper_module

    quote do
      if System.get_env(unquote(env_var)) not in [nil, ""] do
        ExUnit.after_suite(&unquote(helper).dump/1)
      end
    end
  end

  @doc """
  Combined coverage bootstrap kept for callers that do not need to split setup
  from after-suite registration.
  """
  @spec bootstrap_ast() :: Macro.t()
  def bootstrap_ast do
    quote do
      unquote(setup_ast())
      unquote(after_suite_ast())
    end
  end
end
