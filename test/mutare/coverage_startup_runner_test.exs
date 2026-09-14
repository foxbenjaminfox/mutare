defmodule Mutare.CoverageStartupRunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Mutare.{Coverage, RuntimeId}
  alias Mutare.Coverage.Recorder
  alias Mutare.Test.Project

  @moduletag :runner
  @moduletag timeout: 180_000

  test "a mutation rejected during project evaluation is killed" do
    %{project: root, sandbox: sandbox} =
      Project.build(:project_refusal, %{
        "mix.exs" => """
        Code.require_file("lib/settings.ex", __DIR__)
        defmodule ProjectRefusal.MixProject do
          use Mix.Project
          def project do
            if Settings.setting() > 2, do: raise("setting must be small")
            [app: :project_refusal, version: "0.1.0"]
          end
        end
        """,
        "lib/settings.ex" => """
        defmodule Settings do
          def setting, do: 2 - 1
        end
        """,
        "test/settings_test.exs" => """
        defmodule SettingsTest do
          use ExUnit.Case
          test "setting", do: assert Settings.setting() == 1
        end
        """
      })

    log =
      capture_log(fn ->
        assert {:ok, run} =
                 Mutare.run(root,
                   sandbox: sandbox,
                   mutators: [:arithmetic],
                   max_harness_error_rate: 0
                 )

        assert [%{status: :killed, output: output}] = run.results
        assert output =~ "** (RuntimeError) setting must be small"
        refute output =~ "Could not start application"
      end)

    assert log =~ "project evaluation"
  end

  for {kind, failure, header} <- [
        {:error, ~s|raise("setting rejected")|, "** (RuntimeError) setting rejected"},
        {:exit, "exit(:setting_rejected)", "** (exit) :setting_rejected"},
        {:throw, "throw(:setting_rejected)", "** (throw) :setting_rejected"}
      ] do
    test "a deep #{kind} in a required project retains kill attribution without stack frames" do
      %{project: root, sandbox: sandbox} =
        Project.build(:required_project_refusal, %{
          # No inline module: the inference hook declines, but project evidence
          # must still cover failures in the externally required definition.
          "mix.exs" => ~s|Code.require_file("project.exs", __DIR__)\n|,
          "project.exs" => """
          Code.require_file("lib/settings.ex", __DIR__)
          defmodule SettingsCalls do
            #{Enum.map_join(1..20, "\n", fn n -> "def call_#{n}(), do: call_#{n + 1}() + 1" end)}
            def call_21() do
              if Settings.setting() > 2, do: #{unquote(failure)}, else: 1
            end
          end
          defmodule RequiredProjectRefusal.MixProject do
            use Mix.Project
            def project, do: [app: :required_project_refusal, version: "0.1.0"]
          end
          IO.write("Evaluating project...")
          SettingsCalls.call_1()
          """,
          "lib/settings.ex" => """
          defmodule Settings do
            def setting, do: 2 - 1
          end
          """,
          "test/settings_test.exs" => """
          defmodule SettingsTest do
            use ExUnit.Case
            test "setting", do: assert Settings.setting() == 1
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(root,
                 sandbox: sandbox,
                 keep_sandbox: unquote(kind) != :throw,
                 mutators: [:arithmetic],
                 max_harness_error_rate: 0
               )

      assert [%{status: :killed, output: output}] = run.results
      assert output =~ unquote(header)
      assert output =~ "SettingsCalls.call_20/0"
      marker = Mutare.Sandbox.ProjectEvaluation.failure_marker()
      assert output =~ marker

      without_frames =
        output
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(&1, "    "))
        |> Enum.join("\n")

      assert Mutare.Sandbox.Command.outcome(1, without_frames) == :app_start_failure

      assert Mutare.Sandbox.Command.outcome(1, String.replace(without_frames, marker, "")) ==
               :harness_error
    end
  end

  test "selection and probe mode precede prebuilt closures and waiting workers" do
    %{project: root, sandbox: sandbox} =
      Project.build(:coverage_startup, %{
        "mix.exs" => """
        defmodule CoverageStartup.MixProject do
          use Mix.Project
          def project, do: [app: :coverage_startup, version: "0.1.0", config_path: "conf/custom.exs"]
          def application, do: [mod: {CoverageStartup, []}]
        end
        """,
        "conf/custom.exs" => "import Config\n",
        "lib/application.ex" => """
        defmodule CoverageStartup do
          use Application
          def start(_, _) do
            mode = :persistent_term.get(:mutare_probe, :unset)
            expected_mode = System.get_env("MUTARE_COVERAGE") not in [nil, ""]
            if mode != expected_mode, do: raise("mode not initialized before application startup")
            if :ets.whereis(:mutare_cov_agg) != :undefined, do: raise("tables have the wrong owner")
            :persistent_term.put(:startup_mode, mode)
            :persistent_term.put(:startup_closure, StartupCapture.make())
            parent = self()
            worker = spawn_link(fn -> StartupCapture.wait(parent) end)
            receive do {:ready, ^worker} -> :ok end
            :persistent_term.put(:startup_worker, worker)
            # Later helper prefixes must not restart or shorten an armed deadline.
            if System.get_env("MUTARE_TIMEOUT"), do: System.put_env("MUTARE_TIMEOUT", "1")
            Supervisor.start_link([], strategy: :one_for_one)
          end
        end
        """,
        "lib/capture.ex" => """
        defmodule StartupCapture do
          def make, do: fn x -> x + 2 end
          def wait(parent) do
            send(parent, {:ready, self()})
            receive do
              {:go, caller} -> send(caller, {:value, 1 + 2})
            end
          end
        end
        """,
        "test/test_helper.exs" => """
        # Runtime mode must not be re-read from mutable environment after startup.
        System.delete_env("MUTARE_COVERAGE")
        System.put_env("MUTARE_ACTIVE_MUTANT", "999")
        ExUnit.start()
        """,
        "test/startup_test.exs" => """
        defmodule StartupCaptureTest do
          use ExUnit.Case
          test "prestarted code" do
            assert :persistent_term.get(:mutare_probe) == :persistent_term.get(:startup_mode)
            fun = :persistent_term.get(:startup_closure)
            assert fun.(3) == 5
            send(:persistent_term.get(:startup_worker), {:go, self()})
            assert_receive {:value, 3}
          end
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(root, sandbox: sandbox, keep_sandbox: true, mutators: [:arithmetic])

    assert Enum.map(run.results, & &1.status) == [:killed, :killed]

    assert {:ok, coverage} =
             Coverage.read_dump(
               Path.join(sandbox, Recorder.dump_file()),
               RuntimeId.index(run.schema.sites)
             )

    assert coverage.aggregate == MapSet.new(Enum.map(run.schema.sites, & &1.id))
  end

  test "a mutation looping during application startup is contained before test helpers" do
    %{project: root, sandbox: sandbox} =
      Project.build(:startup_loop, %{
        "mix.exs" => """
        defmodule StartupLoop.MixProject do
          use Mix.Project
          def project, do: [app: :startup_loop, version: "0.1.0"]
          def application, do: [mod: {StartupLoopApp, []}]
        end
        """,
        "lib/application.ex" => """
        defmodule StartupLoopApp do
          use Application
          def start(_, _) do
            # Bound a defective implementation too, so this regression cannot leave
            # an unbounded child process behind if the early watchdog goes missing.
            # Armed only for a real mutant: the baseline and the coverage probe run
            # this same app at id 0, and a backstop that could halt *them* would
            # surface as a baffling harness error on a loaded machine. Well clear of
            # the 2s cap under test, so the watchdog always wins when it is present.
            if System.get_env("MUTARE_ACTIVE_MUTANT") not in [nil, "", "0"] do
              spawn(fn -> Process.sleep(60_000); System.halt(73) end)
            end
            StartupLoop.count_down(2)
            Supervisor.start_link([], strategy: :one_for_one)
          end
        end
        """,
        "lib/loop.ex" => """
        defmodule StartupLoop do
          def count_down(0), do: :done
          def count_down(n), do: count_down(n - 1)
        end
        """,
        "test/loop_test.exs" => """
        defmodule StartupLoopTest do
          use ExUnit.Case
          test "counts down", do: assert StartupLoop.count_down(2) == :done
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(root, sandbox: sandbox, timeout: 2_000, mutators: [:arithmetic])

    assert Enum.map(run.results, & &1.status) == [:timeout]
  end

  test "a mutation that stops the application from starting is killed, not a harness error" do
    %{project: root, sandbox: sandbox} =
      Project.build(:startup_refusal, %{
        "mix.exs" => """
        defmodule StartupRefusal.MixProject do
          use Mix.Project
          def project, do: [app: :startup_refusal, version: "0.1.0"]
          def application, do: [mod: {StartupRefusalApp, []}]
        end
        """,
        "lib/application.ex" => """
        defmodule StartupRefusalApp do
          use Application
          def start(_, _) do
            if StartupRefusal.pool_size() > 2, do: raise("pool_size must be small")
            Supervisor.start_link([], strategy: :one_for_one)
          end
        end
        """,
        "lib/pool.ex" => """
        defmodule StartupRefusal do
          def pool_size, do: 2 - 1
        end
        """,
        "test/pool_test.exs" => """
        defmodule StartupRefusalTest do
          use ExUnit.Case
          test "pool size", do: assert StartupRefusal.pool_size() == 1
        end
        """
      })

    # `2 - 1` → `2 + 1` makes `Application.start/2` raise, so `mix test` dies in
    # `app.start` before it loads a test. Mix's `Could not start application` banner
    # is the detection: the baseline boots this very sandbox green, so the mutation is
    # the only thing that changed. Charged as a kill — never as a harness error, which
    # would drop it from the score *and* count toward the run-level abort guard.
    log =
      capture_log(fn ->
        assert {:ok, run} = Mutare.run(root, sandbox: sandbox, mutators: [:arithmetic])
        assert Enum.map(run.results, & &1.status) == [:killed]
      end)

    assert log =~ "would not start with this mutation active"
  end

  for config_path <- ["config/config.exs", "conf/custom.exs"] do
    test "a mutation rejected by runtime configuration is killed with #{config_path}" do
      config_path = unquote(config_path)
      runtime_path = Path.join(Path.dirname(config_path), "runtime.exs")

      %{project: root, sandbox: sandbox} =
        Project.build(:runtime_config_refusal, %{
          "mix.exs" => """
          defmodule RuntimeConfigRefusal.MixProject do
            use Mix.Project
            def project do
              [app: :runtime_config_refusal, version: "0.1.0", config_path: #{inspect(config_path)}]
            end
          end
          """,
          config_path => "import Config\n",
          runtime_path => """
          import Config
          IO.puts("Loading runtime configuration")
          if RuntimeConfigRefusal.pool_size() > 2, do: raise("pool_size must be small")
          config :runtime_config_refusal, :pool_size, RuntimeConfigRefusal.pool_size()
          """,
          "lib/pool.ex" => """
          defmodule RuntimeConfigRefusal do
            def pool_size, do: 2 - 1
          end
          """,
          "test/pool_test.exs" => """
          defmodule RuntimeConfigRefusalTest do
            use ExUnit.Case
            test "pool size", do: assert RuntimeConfigRefusal.pool_size() == 1
          end
          """
        })

      # The baseline and probe configure successfully; `2 - 1` → `2 + 1` raises
      # before Application.start/2, without Mix's could-not-start banner.
      log =
        capture_log(fn ->
          assert {:ok, run} = Mutare.run(root, sandbox: sandbox, mutators: [:arithmetic])
          assert [%{status: :killed, output: output}] = run.results
          assert output =~ "** (RuntimeError) pool_size must be small"
          assert output =~ runtime_path
          refute output =~ "Could not start application"
        end)

      assert log =~ "runtime configuration"
    end

    test "a library exception during runtime configuration is killed with #{config_path}" do
      config_path = unquote(config_path)
      runtime_path = Path.join(Path.dirname(config_path), "runtime.exs")

      %{project: root, sandbox: sandbox} =
        Project.build(:runtime_config_library, %{
          "mix.exs" => """
          defmodule RuntimeConfigLibrary.MixProject do
            use Mix.Project
            def project do
              [app: :runtime_config_library, version: "0.1.0", config_path: #{inspect(config_path)}]
            end
          end
          """,
          config_path => "import Config\n",
          runtime_path => """
          import Config
          config :runtime_config_library, :configured, true
          IO.write("Loading runtime configuration...")
          SettingsCalls.call_1()
          """,
          "lib/settings.ex" => """
          defmodule Settings do
            def setting, do: 8 / 1
          end
          """,
          "lib/settings_calls.ex" => """
          defmodule SettingsCalls do
            #{Enum.map_join(1..20, "\n", fn n -> "def call_#{n}(), do: call_#{n + 1}() + 1" end)}
            def call_21(), do: Settings.setting()
          end
          """,
          "test/settings_test.exs" => """
          defmodule SettingsTest do
            use ExUnit.Case
            test "setting", do: assert Settings.setting() == 8
          end
          """
        })

      # The 1 → 0 mutant raises beneath deep non-tail library calls. It must
      # remain a kill without tripping the run-level harness-error-rate abort.
      assert {:ok, run} =
               Mutare.run(root,
                 sandbox: sandbox,
                 keep_sandbox: config_path == "config/config.exs",
                 paths: ["lib/settings.ex"],
                 mutators: [:integer],
                 max_harness_error_rate: 0
               )

      assert Enum.map(run.results, & &1.status) == List.duplicate(:killed, 5)

      assert [%{output: output}] =
               Enum.filter(run.results, &String.contains?(&1.output, "** (ArithmeticError)"))

      assert output =~ "Settings.setting/0"
      refute output =~ "Config.__eval__!/3"
      refute output =~ "Could not start application"
      assert output =~ Mutare.Sandbox.RuntimeConfig.failure_marker()

      # Some evaluators append a runtime.exs frame when our wrapper re-raises.
      # Neither that frame nor Config's evaluator is required to retain the kill.
      without_frames =
        output
        |> String.split("\n")
        |> Enum.reject(&String.contains?(&1, [runtime_path, "Config.__eval__!/3"]))
        |> Enum.join("\n")

      assert Mutare.Sandbox.Command.outcome(1, without_frames) == :app_start_failure

      without_marker =
        String.replace(without_frames, Mutare.Sandbox.RuntimeConfig.failure_marker(), "")

      assert Mutare.Sandbox.Command.outcome(1, without_marker) == :harness_error
    end
  end

  for {kind, failure, reason} <- [
        {:exit, "GenServer.call(:missing_config_server, :read)",
         "GenServer.call(:missing_config_server, :read, 5000)"},
        {:throw, "throw(:configuration_rejected)", ":configuration_rejected"}
      ] do
    test "a deep #{kind} during runtime configuration counts as a kill" do
      %{project: root, sandbox: sandbox} =
        Project.build(:runtime_config_nonerror, %{
          "config/config.exs" => "import Config\n",
          "config/runtime.exs" => "import Config\nSettingsCalls.call_1()\n",
          "lib/settings.ex" => """
          defmodule Settings do
            def setting, do: 2 - 1
          end
          """,
          "lib/settings_calls.ex" => """
          defmodule SettingsCalls do
            #{Enum.map_join(1..20, "\n", fn n -> "def call_#{n}(), do: call_#{n + 1}() + 1" end)}
            def call_21() do
              if Settings.setting() > 2, do: #{unquote(failure)}, else: 1
            end
          end
          """,
          "test/settings_test.exs" => """
          defmodule SettingsTest do
            use ExUnit.Case
            test "setting", do: assert Settings.setting() == 1
          end
          """
        })

      assert {:ok, run} =
               Mutare.run(root,
                 sandbox: sandbox,
                 paths: ["lib/settings.ex"],
                 mutators: [:arithmetic],
                 max_harness_error_rate: 0
               )

      assert [%{status: :killed, output: output}] = run.results
      assert output =~ "** (#{unquote(kind)})"
      assert output =~ unquote(reason)
      assert output =~ "SettingsCalls.call_20/0"
      assert output =~ Mutare.Sandbox.RuntimeConfig.failure_marker()

      # The marker must retain the phase even when the deep call stack loses
      # Config's evaluator and the script frame appended by some Elixir versions.
      without_frames =
        output
        |> String.split("\n")
        |> Enum.reject(&String.contains?(&1, ["runtime.exs", "Config.__eval__!/3"]))
        |> Enum.join("\n")

      assert Mutare.Sandbox.Command.outcome(1, without_frames) == :app_start_failure
    end
  end

  test "fixture capture and teardown leave the outer probe's state and dump intact" do
    fixture = Recorder.runtime(:fixture)
    template = File.read!(Path.expand("../../lib/mutare/coverage/helper_template.ex", __DIR__))
    mode = Macro.to_string(Recorder.mode_ast(:fixture))
    tables = Macro.to_string(Recorder.tables_ast(:fixture))

    %{project: root, sandbox: sandbox} =
      Project.build(:coverage_isolation, %{
        "lib/helper_template.ex" => template,
        "lib/subject.ex" => "defmodule IsolationSubject do\n def run(x), do: x + 2\nend\n",
        "test/isolation_test.exs" => """
        defmodule CoverageIsolationTest do
          use ExUnit.Case
          alias Mutare.Coverage.HelperTemplate, as: H
          test "fixture isolation" do
            assert IsolationSubject.run(3) == 5
            outer_mode = :persistent_term.get(:mutare_probe)
            outer_ready = :persistent_term.get(:mutare_track, false)
            outer_dump = System.get_env("MUTARE_COV_DUMP")
            outer_cache = Process.get({:mutare_cov_seen, "lib/subject.ex"})
            System.put_env(#{inspect(fixture.env_var)}, "1")
            #{mode}
            #{tables}
            H.hit([999_999])
            assert :ets.member(H.agg_table(), 999_999)
            :persistent_term.put(#{inspect(fixture.track_key)}, false)
            System.put_env(H.dump_path_env(), "fixture.terms")
            H.dump(:done)
            File.rm!("fixture.terms")
            for key <- [:agg_table, :attr_table, :unlabeled_table, :test_table, :wholefile_table] do
              :ets.delete(Map.fetch!(H.runtime(:fixture), key))
            end
            assert :persistent_term.get(:mutare_probe) == outer_mode
            assert :persistent_term.get(:mutare_track, false) == outer_ready
            assert System.get_env("MUTARE_COV_DUMP") == outer_dump
            assert Process.get({:mutare_cov_seen, "lib/subject.ex"}) == outer_cache
            if outer_mode do
              assert :ets.member(:mutare_cov_agg, {"lib/subject.ex", 1})
            end
          end
        end
        """
      })

    assert {:ok, run} =
             Mutare.run(root,
               sandbox: sandbox,
               keep_sandbox: true,
               paths: ["lib/subject.ex"],
               mutators: [:arithmetic]
             )

    assert Enum.map(run.results, & &1.status) == [:killed]

    assert {:ok, coverage} =
             Coverage.read_dump(
               Path.join(sandbox, Recorder.dump_file()),
               RuntimeId.index(run.schema.sites)
             )

    assert coverage.aggregate == MapSet.new([1])
  end
end
