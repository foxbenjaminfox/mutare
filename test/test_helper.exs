# Runner tests start nested Mix subprocesses and property soaks compile many
# fixtures; neither is suitable for running once per dogfood mutant. Coverage
# helper tests use isolated fixture state and can now run inside the outer probe.
if System.get_env("MUTARE_ACTIVE_MUTANT"),
  do: ExUnit.configure(exclude: [:runner, :property])

# The modules that spend their time in `mix` subprocesses (`*_runner_test` and kin) are async
# members of three ExUnit groups, `:subprocess_1` to `:subprocess_3`. A group runs one module at a
# time, so at most three drive subprocesses at once, beside the in-process tests; the groups are
# balanced by measured wall time. Run serially they left the machine idle (a full run averaged
# one core), and run freely they would start dozens of `mix` processes at once. The ones whose
# verdicts hang on wall-clock timing (`timeout_test`, `heap_cap_test`, `compile_timeout_test`)
# and `mix_task_test` (the global `:stderr` device and `Mix.shell`) stay `async: false`.

# Skip the compiler's "redefining module" check. For every `defmodule` it runs
# `:code.ensure_loaded/1`, which for a fresh name searches the whole code path on disk inside
# the VM's single code server — the suite's one serial resource once it compiles thousands of
# fixtures concurrently. Runtime fixture names are kept apart by `Mutare.Test.Compile.Names`
# instead, and the warning carried no signal for a test (NOTES "The suite runs concurrently").
Code.put_compiler_option(:ignore_module_conflict, true)

# A fixture name is owned by one module execution for one suite run, and
# `--repeat-until-failure` runs every module again, in this VM, as a new execution.
ExUnit.after_suite(fn _result -> Mutare.Test.Compile.Names.reset() end)

# Capture Logger output globally: the lib emits `Logger.warning` on a few
# analysis decisions (non-consecutive clauses, augmented-by-metaprogramming defs,
# coverage-dump fallbacks), most of which are *expected* during tests. With
# `capture_log: true` these are swallowed and only surfaced for a *failing* test.
# Tests that assert on a specific log still use `with_log/1` / `capture_log/1`,
# which nest fine under the global capture.
ExUnit.start(capture_log: true)
