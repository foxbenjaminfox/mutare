defmodule Mutare.Sandbox.Command.InvocationTest do
  # Not async: the inert-watcher check touches the process-global timeout env var.
  use ExUnit.Case, async: false

  alias Mutare.Sandbox
  alias Mutare.Sandbox.Command
  alias Mutare.Sandbox.Command.Invocation

  setup do
    on_exit(fn ->
      System.delete_env(Invocation.timeout_env())
      System.delete_env(Invocation.compile_timeout_env())
    end)
  end

  test "the sandbox environment constants" do
    assert Invocation.mix_env() == "test"
    assert Invocation.timeout_env() == "MUTARE_TIMEOUT"
    assert Invocation.compile_timeout_env() == "MUTARE_COMPILE_TIMEOUT"
    assert Invocation.owner_watch_env() == "MUTARE_OWNER_WATCH"
  end

  test "reserved_env_names/0 lists the variables Mutare sets on every sandbox mix" do
    names = Invocation.reserved_env_names()
    # The base env and the cap vars are always reserved (a `:partition_env` colliding
    # with one of these is rejected by `Mutare.Options`).
    assert "MIX_ENV" in names
    assert Invocation.timeout_env() in names
    assert Invocation.compile_timeout_env() in names
    assert Invocation.owner_watch_env() in names
    # Carries the `:max_heap_mb` cap when that option is on.
    assert "ELIXIR_ERL_OPTIONS" in names
    # Set on the one compile (`CompilerOptions.compiler_env/0`), which appends the
    # partition entry after it — so a `:partition_env` naming it would duplicate the key.
    assert "ERL_COMPILER_OPTIONS" in names
    assert Enum.all?(Mutare.Sandbox.CompilerOptions.compiler_env(), fn {k, _} -> k in names end)
    # Sourced from the accessors that build the env, so no duplicates can creep in.
    assert names == Enum.uniq(names)
  end

  describe "heap_cap_env/1 (the :max_heap_mb per-process heap cap)" do
    setup do
      original = System.get_env("ELIXIR_ERL_OPTIONS")

      on_exit(fn ->
        case original do
          nil -> System.delete_env("ELIXIR_ERL_OPTIONS")
          value -> System.put_env("ELIXIR_ERL_OPTIONS", value)
        end
      end)

      %{original: original}
    end

    test "nil (the default) sets no cap" do
      assert Invocation.heap_cap_env(nil) == []
    end

    test "an MB value becomes a +hmax flag in words" do
      System.delete_env("ELIXIR_ERL_OPTIONS")
      words = div(1024 * 1_048_576, :erlang.system_info(:wordsize))
      assert Invocation.heap_cap_env(1024) == [{"ELIXIR_ERL_OPTIONS", "+hmax #{words}"}]
    end

    test "a pre-existing ELIXIR_ERL_OPTIONS is preserved, the cap appended after it" do
      # Later emulator flags win, so appending keeps the user's flags *and*
      # applies the cap on top — never silently clobbers their environment.
      System.put_env("ELIXIR_ERL_OPTIONS", "+S 2")
      assert [{"ELIXIR_ERL_OPTIONS", merged}] = Invocation.heap_cap_env(1)
      assert merged =~ ~r/^\+S 2 \+hmax \d+$/
    end
  end

  test "watcher AST carries the timeout env var and exit code" do
    rendered = Macro.to_string(Invocation.watcher_ast())

    assert rendered =~ ~s|System.get_env("#{Invocation.timeout_env()}")|
    # The watcher signals the timeout via the exit code the Command contract decodes.
    assert rendered =~ "System.halt(#{Command.timeout_exit()})"
  end

  test "watcher AST is inert when no cap is set" do
    System.delete_env(Invocation.timeout_env())
    # nil branch returns :ok and spawns nothing — safe to evaluate in-process.
    assert {:ok, _binding} = Code.eval_quoted(Invocation.watcher_ast())
  end

  test "sandbox renders the canonical watcher AST" do
    assert Sandbox.bootstrap() =~ Macro.to_string(Invocation.watcher_ast())
  end

  test "compile-watcher AST carries its own env var and the timeout exit code" do
    rendered = Macro.to_string(Invocation.compile_watcher_ast())

    # A dedicated variable, not `timeout_env/0`: this watcher lives in the config
    # prefix, evaluated on *every* sandbox boot, so it must arm only when the
    # runner's compile invocation sets it — never from a mutant run's test cap.
    assert rendered =~ ~s|System.get_env("#{Invocation.compile_timeout_env()}")|
    refute rendered =~ ~s|"#{Invocation.timeout_env()}"|
    assert rendered =~ "System.halt(#{Command.timeout_exit()})"
  end

  test "compile-watcher AST is inert when no cap is set" do
    System.delete_env(Invocation.compile_timeout_env())
    # nil branch returns :ok and spawns nothing — safe to evaluate in-process
    # (the boot path of every uncapped sandbox run).
    assert {:ok, _binding} = Code.eval_quoted(Invocation.compile_watcher_ast())
  end

  test "owner-watch AST carries the gate env var and exit code" do
    rendered = Macro.to_string(Invocation.owner_watch_ast())

    assert rendered =~ ~s|System.get_env("#{Invocation.owner_watch_env()}")|
    # The watcher signals owner death via the code the Command contract reserves.
    assert rendered =~ "System.halt(#{Command.owner_lost_exit()})"
  end

  test "owner-watch AST is inert when the gate is not set" do
    # Only `Invocation.mix/4` arms the gate: a manual `mix test` in a kept sandbox
    # (or CI with stdin at /dev/null, which would otherwise EOF instantly) must be
    # unaffected. The nil branch returns :ok and spawns nothing — safe to evaluate
    # in-process.
    System.delete_env(Invocation.owner_watch_env())
    assert {:ok, _binding} = Code.eval_quoted(Invocation.owner_watch_ast())
  end

  test "sandbox renders the canonical owner-watch AST" do
    assert Sandbox.bootstrap() =~ Macro.to_string(Invocation.owner_watch_ast())
  end

  if match?({:win32, _}, :os.type()) do
    @tag skip: "POSIX-only harness (a #!/bin/sh shim); mix/4 itself is OS-neutral"
  end

  test "mix/4 arms the owner-death gate on every sandbox run" do
    # Shadow `mix` with a shim that dumps its environment: `System.cmd/3` resolves
    # the executable from the *current* PATH, so prepending the shim dir observes
    # exactly the env `mix/4` assembles — no real mix run needed. Safe to mutate
    # PATH here: this module is `async: false`, and sync tests run serially.
    base = Path.join(System.tmp_dir!(), "mutare_gate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    dump = Path.join(base, "env.dump")
    shim = Path.join(base, "mix")
    File.write!(shim, "#!/bin/sh\nenv > \"#{dump}\"\n")
    File.chmod!(shim, 0o755)

    original_path = System.fetch_env!("PATH")
    System.put_env("PATH", base <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert {_output, 0} = Invocation.mix(base, ["compile"], 0)

    env = File.read!(dump)
    # The gate is part of the base env — set on *every* run (compile, baseline,
    # probe, mutant), not just capped ones.
    assert env =~ "#{Invocation.owner_watch_env()}=1"
    assert env =~ "MIX_ENV=test"
  end
end
