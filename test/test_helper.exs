# Runner tests start nested Mix subprocesses and property soaks compile many
# fixtures; neither is suitable for running once per dogfood mutant. Coverage
# helper tests use isolated fixture state and can now run inside the outer probe.
if System.get_env("MUTARE_ACTIVE_MUTANT"),
  do: ExUnit.configure(exclude: [:runner, :property])

# Capture Logger output globally: the lib emits `Logger.warning` on a few
# analysis decisions (non-consecutive clauses, augmented-by-metaprogramming defs,
# coverage-dump fallbacks), most of which are *expected* during tests. With
# `capture_log: true` these are swallowed and only surfaced for a *failing* test.
# Tests that assert on a specific log still use `with_log/1` / `capture_log/1`,
# which nest fine under the global capture.
ExUnit.start(capture_log: true)
