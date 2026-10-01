defmodule Mutare.CoverageAttribution do
  @moduledoc """
  Capability behaviour for telling Mutare which test a process is working for.

  Mutare runs each mutant against only the tests that executed its line. The
  coverage probe finds the test from the process the line ran in: the test process
  itself, or a process it started, through a `Task`'s `$callers` or a process's
  `$ancestors`. A process with none of those links to a test records coverage no
  test owns, and each mutant it covers runs the whole suite. A web server's request
  process in a browser-driven test (Wallaby, Hound, Playwright) is the usual case:
  the test's browser sent the request, but nothing the probe can read says so.

  A library that does know, because the request carries something the test put
  there, can say so with `attribute_to/1`. An extension implementing this behaviour
  installs whatever makes that call — typically `:telemetry` handlers on events the
  library already emits — from `c:attach_attribution/1`, and is listed under
  `:extensions`:

      # .mutare.exs
      [extensions: [Mutare.Phoenix.Ecto]]

  Mutare calls `c:attach_attribution/1` in the coverage probe's test VM, after the
  project's own `test_helper.exs` has run and before any test, and nowhere else: a
  plain `mix test`, the baseline run, and the per-mutant runs never call it.

  The extension module is loaded in the run that reads `.mutare.exs` and in the
  probe's test VM alike, so it belongs in a dependency available to both (`only:
  [:dev, :test]`), not in the project's `test/support`.
  """

  @anchor_key Mutare.Coverage.Recorder.runtime(:harness).anchor_key

  @doc """
  Installs the hooks that declare owners with `attribute_to/1`, then returns `:ok`.

  Called with the options of the extension's `{module, opts}` entry (`[]` for a
  bare module), so options must be plain data: atoms, numbers, strings, and lists,
  tuples and maps of them. An umbrella evaluates each app's test helper in one VM,
  so the call may come once per app; a second call must leave the hooks installed
  once. A raise, or a return other than `:ok`, fails the probe run, which Mutare
  then retries once before degrading to running every mutant against the whole
  suite.
  """
  @callback attach_attribution(opts :: keyword()) :: :ok

  @doc """
  Declares that the calling process is doing work for `owner`, so the coverage it
  records is attributed to the test `owner` belongs to. `nil` withdraws the
  declaration.

  `owner` is resolved the way the calling process would be: its own test label,
  else the processes it acts for (its declared owner, its `$callers`, its
  `$ancestors`). So it may be the test process or anything that test started — the
  owner process `Ecto.Adapters.SQL.Sandbox.start_owner!/2` starts resolves through
  its `$ancestors` — or another process that declared an owner. The attribution
  holds while that test is alive; after it exits, the process's coverage counts as
  owned by no test again, which is the conservative side.

  It lasts until the next call, so a process that works for one owner after
  another — a keep-alive connection serving successive requests — declares each
  one, and withdraws the last (`nil`) where it starts work no owner is known for;
  otherwise that work is attributed to the previous owner's test. A process it
  spawns resolves through it like any caller, taking the declaration in force when
  the spawned process first records coverage, until the test found through it
  exits.

  Only the probe reads the declaration; everywhere else it is an unread
  process-dictionary entry. The claim is trusted: it is only safe when the named
  test can observe the work, as it can a request its own browser sent.
  """
  @spec attribute_to(pid() | nil) :: :ok
  def attribute_to(owner) when is_pid(owner) do
    Process.put(@anchor_key, owner)
    :ok
  end

  def attribute_to(nil) do
    Process.delete(@anchor_key)
    :ok
  end
end
