# When this suite runs *inside a Mutare sandbox* — i.e. Mutare is being
# dogfooded on itself — skip the `:runner`, `:property`, and `:coverage_tables`
# tests. The `:runner` tests shell out to real `mix test` subprocesses; spawning
# those once per mutant would be catastrophic (a fork bomb of nested suites). The
# `:property` soaks render/compile/run a stream of generated modules (~2 min each),
# so running them once per mutant would be just as ruinous. The `:coverage_tables`
# tests alter the process-global `:mutare_track` flag or `:mutare_cov_*` ETS tables
# (create/`:ets.delete` them) — the *same* state the dogfood coverage probe uses across
# the whole suite; left to run, they disable recording or wipe the probe's data,
# compromising test selection. `MUTARE_ACTIVE_MUTANT` is set on every per-mutant run
# (and the baseline/probe) but never on a normal `mix test`, so it cleanly marks "we
# are the suite-under-mutation" without affecting ordinary local/CI runs. (The cost,
# as for `:runner`, is that code reached only by these excluded tests has no
# in-process coverage and so survives rather than scoring `:no_coverage`.)
if System.get_env("MUTARE_ACTIVE_MUTANT"),
  do: ExUnit.configure(exclude: [:runner, :property, :coverage_tables])

# Capture Logger output globally: the lib emits `Logger.warning` on a few
# analysis decisions (non-consecutive clauses, augmented-by-metaprogramming defs,
# coverage-dump fallbacks), most of which are *expected* during tests. With
# `capture_log: true` these are swallowed and only surfaced for a *failing* test.
# Tests that assert on a specific log still use `with_log/1` / `capture_log/1`,
# which nest fine under the global capture.
ExUnit.start(capture_log: true)
