defmodule MutareCov do
  @moduledoc false
  # Test-only stand-in for the coverage helper `Mutare.Sandbox` writes into each
  # sandbox (see `Mutare.Coverage.Recorder.helper_source/0`). Every selector
  # catch-all the transform emits references `MutareCov.hit/1`; Mutare's own unit
  # tests compile those bare metamutants in *this* VM, where the real helper is
  # absent. The call is gated behind the probe flag (`:mutare_track`) these tests
  # never set, so it is never actually invoked at baseline — this module exists
  # only so the reference resolves and no "undefined module" warning is emitted.
  def hit(_ids), do: true
end
