# Bound to a variable first: `defmodule <remote-call>` is rejected by the compiler
# ("invalid module name"), but `defmodule <var>` resolving to an atom is accepted.
fixture_module = Mutare.Coverage.Recorder.fixture_module()

defmodule fixture_module do
  @moduledoc false
  # Test-only stand-in for the coverage helper `Mutare.Sandbox` writes into each
  # sandbox (see `Mutare.Coverage.Recorder.helper_source/0`). Every selector
  # catch-all the transform emits references this internal helper; Mutare's own
  # unit tests compile those bare metamutants in *this* VM, where the real helper
  # is absent. The call is gated behind the probe flag (`:mutare_track`) these
  # tests never set, so it is never actually invoked at baseline — this module
  # exists only so the reference resolves and no "undefined module" warning is
  # emitted.
  #
  # Its name comes from `Recorder.fixture_module/0`, not a literal `:mutare_cov`:
  # in this VM the override env is unset so it *is* `:mutare_cov` (the bare
  # metamutants' `hit/1` calls resolve here). But when Mutare runs on a copy of
  # itself, the sandbox already holds the real helper module named `:mutare_cov`
  # (written by `Mutare.Sandbox`, with a `dump/1` the probe needs) — so
  # `Mutare.Sandbox.Command` sets the override and this stand-in compiles under a
  # private name there. Transforms built by the suite call this stand-in too, so
  # their fixture ids cannot contaminate the real helper's coverage dump.
  # See `Mutare.Coverage.Recorder`'s moduledoc and NOTES "Self-hosting
  # coverage".
  def hit(_ids), do: true
  def hit(_namespace, _ids), do: true
end
