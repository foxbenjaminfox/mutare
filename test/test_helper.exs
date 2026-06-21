# When this suite runs *inside a Mutare sandbox* — i.e. Mutare is being
# dogfooded on itself — skip the `:runner` and `:property` tests. The `:runner`
# tests shell out to real `mix test` subprocesses; spawning those once per mutant
# would be catastrophic (a fork bomb of nested suites). The `:property` soaks
# render/compile/run a stream of generated modules (~2 min each), so running them
# once per mutant would be just as ruinous. `MUTANT_UNDER_TEST` is set on every
# per-mutant run (and the baseline) but never on a normal `mix test`, so it
# cleanly marks "we are the suite-under-mutation" without affecting ordinary
# local/CI runs.
if System.get_env("MUTANT_UNDER_TEST"),
  do: ExUnit.configure(exclude: [:runner, :property])

ExUnit.start()
