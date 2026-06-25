defmodule Mutare.Transform.Uses.EnvMirror do
  @moduledoc false
  # Mirrors `Mix.env()` to the sandbox env (`:test`) while a `use`'s `__using__` body is expanded,
  # so a macro that branches on `Mix.env()` injects the directives that will be in scope when the
  # metamutant compiles — not the scan-env ones. The metamutant is compiled and run under
  # `MIX_ENV=test` (`Mutare.Sandbox.Command`), but the scan/transform usually runs in the task's
  # `:dev` env. (Compile-time config baked into already-loaded modules can't be re-mirrored
  # in-process — only a runtime `Mix.env()` read is.) `Mutare.Transform.Uses` wraps its whole walk
  # in `with_sandbox_env/1`; this module is the concurrency mechanism that wrap rests on, split out
  # so the seqlock can be audited in isolation.
  #
  # `Mix.env/1` mutates **global** (node-wide ETS) state, so concurrent callers must not corrupt
  # each other's view. The design splits into a lock-free fast path and a serialized swap:
  #
  #   * **Fast path** when the *stable* base env is already the sandbox env: no mutation, no lock.
  #     The test suite and the sandbox run *in* `:test`, so every concurrent transform there (async
  #     tests, parallel library callers, the property soaks) skips the swap — and crucially, in a
  #     `:test` base **no swap ever runs** (nothing reads a non-`:test` env), so the global is never
  #     mutated and the fast path is contention-free.
  #   * **Serialize** the swap (the CLI's `:dev`) behind a node-local `:global` lock, held for the
  #     *whole* expansion. Concurrent swappers run one at a time, each reading the true previous env
  #     and restoring it.
  #
  # The subtlety the obvious version gets wrong: a swapper in a `:dev` base transiently sets the
  # global to `:test`, so a *second* concurrent transform reading `Mix.env()` could see that
  # transient `:test`, wrongly take the lock-free fast path, and keep expanding an env-sensitive
  # `__using__` after the first swapper restores `:dev` — harvesting directives for the wrong env.
  # So the fast-path test is **not** a bare `Mix.env() == :test`: it is guarded by a node-local
  # **seqlock** (`@seq_key`, an `:atomics` counter the swap bumps to *odd* on entry and back to
  # *even* on exit, both **inside** the lock and bracketing the env mutation). A reader samples
  # `seq → Mix.env() → seq` and only trusts a `:test` reading when the seq was **even and unchanged**
  # across it — i.e. no swap was active for even an instant of the read. A transient `:test` is only
  # ever set while seq is odd, so it can never be mistaken for the stable base. (`Mix.State`'s ETS
  # and `:atomics` are each internally synchronized, so the swapper's `odd` bump is visible to any
  # reader that observes its `:test`.) In a `:test` base seq stays `0`, so the guard is two atomic
  # reads — no lock, no contention.
  #
  # `Mix.env/0` raises if Mix hasn't been *started* — the public `transform_string/2` API embedded
  # in a plain process that never ran Mix — in which case there's no sandbox env to mirror, so we
  # run unmirrored (the fallback keeps the library API working without Mix).

  # The env the metamutant is compiled and tested under, as an atom for `Mix.env` mirroring during
  # `__using__` expansion. The canonical value is `Mutare.Sandbox.Command.mix_env/0` (the `"test"`
  # string set as `MIX_ENV`); this is its atom twin, kept local rather than reaching across the
  # transform→execution layer boundary for a compile-time dependency.
  @sandbox_env :test

  # The `:persistent_term` key holding the env-mirror **seqlock** — a one-slot `:atomics` counter
  # the swap bumps to mark itself in-flight, so a concurrent reader can tell a stable base `:test`
  # from a swapper's transient one.
  @seq_key {__MODULE__, :env_seq}

  @doc """
  Run `fun` with `Mix.env()` mirrored to the sandbox env (`:test`) for its duration, restoring the
  previous env afterward, and return its result. A no-op wrapper when the base env is already the
  sandbox env (the fast path) or when Mix isn't started; otherwise a serialized swap. See the
  module comment for the seqlock that makes the fast path safe under concurrency.
  """
  @spec with_sandbox_env((-> result)) :: result when result: var
  def with_sandbox_env(fun) do
    case classify_env() do
      :sandbox -> fun.()
      :other -> swap(fun)
      :unavailable -> fun.()
    end
  end

  # Classify the *stable* base env, immune to a concurrent swapper's transient `:test`: `:sandbox`
  # (fast path) only when `Mix.env()` reads the sandbox env **and** the seqlock shows no swap
  # touched the global across the read (even and unchanged). Anything else is `:other` (swap path) —
  # including a `:test` reading caught mid-swap, which then blocks on the lock and mirrors correctly.
  # `:unavailable` when Mix isn't started (`Mix.env/0` raises).
  defp classify_env do
    ref = seq_ref()
    s0 = :atomics.get(ref, 1)
    env = Mix.env()
    s1 = :atomics.get(ref, 1)

    if env == @sandbox_env and s0 == s1 and rem(s0, 2) == 0,
      do: :sandbox,
      else: :other
  rescue
    _ -> :unavailable
  end

  # The seqlock counter — a one-slot `:atomics`, created once and shared via `:persistent_term`.
  # The one-time creation is serialized by a `:global` lock so concurrent first-callers converge on
  # a single ref (a lock-free create-and-put would let one process bump a ref another never sees);
  # every later call is a bare `:persistent_term.get`.
  defp seq_ref do
    case :persistent_term.get(@seq_key, :missing) do
      :missing -> create_seq_ref()
      ref -> ref
    end
  end

  defp create_seq_ref do
    :global.trans({{__MODULE__, :env_seq_init}, self()}, fn ->
      case :persistent_term.get(@seq_key, :missing) do
        :missing ->
          ref = :atomics.new(1, signed: false)
          :persistent_term.put(@seq_key, ref)
          ref

        ref ->
          ref
      end
    end)
  end

  # The `:global.trans` id is `{ResourceId, LockRequesterId}`. The lock is keyed on the
  # **ResourceId** (`{__MODULE__, :sandbox_env}` — a constant, *shared* across processes, so two
  # callers contend for the same lock and serialize). `LockRequesterId` is the requester *identity*
  # and **must stay `self()`**: `:global` grants a lock re-entrantly to the *same* requester, so a
  # process-independent (constant) requester id would make every process the same requester and
  # grant them all at once — defeating the mutex. (Counter-intuitive but verified; the concurrent
  # transform test in `uses_env_test.exs` guards it.)
  #
  # The seqlock bumps bracket the env mutation: `add → odd` *before* `Mix.env(@sandbox_env)`, and
  # `add → even` *after* the restore (in `after`, so a raising `fun` still leaves it even). Both run
  # inside the lock, so swaps never interleave their bumps — seq cycles `even → odd → even` cleanly.
  defp swap(fun) do
    ref = seq_ref()

    :global.trans({{__MODULE__, :sandbox_env}, self()}, fn ->
      :atomics.add(ref, 1, 1)
      previous = Mix.env()
      Mix.env(@sandbox_env)

      try do
        fun.()
      after
        Mix.env(previous)
        :atomics.add(ref, 1, 1)
      end
    end)
  end
end
