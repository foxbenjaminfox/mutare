defmodule Mutare.Mutators.IntegerLiteral do
  @moduledoc """
  Integer-literal mutations: `n` → `n + 1`, `n - 1`, and `0` (the "off-by-one" boundary plus the zero sentinel), deduplicated and never equal to `n`.

  Only literals in *runtime* positions are mutated, never pattern literals. Mutations that would reproduce the original value are dropped (`0` is not re-emitted for the literal `0`; `n - 1` and `0` collapse for `n = 1`).

  An integer literal in a known **timeout/duration position** (`Process.sleep/1`, the third argument of `Process.send_after/3`, the `GenServer.call/3` timeout, `Task.async_stream`'s `:timeout` option, …) is left unmutated — a near-unkillable equivalent mutant that also risks minting false `:timeout` kills. This family owns that knowledge: `c:Mutare.Mutator.argument_marks/1` asks the transform to mark those positions with the `:timeout` label, and `mutate/2` declines when the mark is present. A *computed* duration (`base * 2`) is not a literal at the marked node, so it still mutates. (`Mutare.Mutators.AtomLiteral` reuses the same table to leave `:infinity` alone there.)

  **Configuring extra positions.** Add project-specific timeout positions with the `argument_marks:`
  option in `.mutare.exs` — entries have the declaration shape this table is written in
  (`{module, function, arity, positions, label}`; `positions` lists effective argument indices and
  `{:keyword, key}` option keys), and the `:timeout` label gives them exactly this family's reaction:

      [argument_marks: [
        {MyApp.Cache, :put, 3, [2], :timeout},                       # a TTL argument
        {MyApp.Http, :get, 2, [{:keyword, :recv_timeout}], :timeout}
      ]]

  `Mutare.Mutators.AtomLiteral` reacts to the same label, so a configured position also keeps its
  `:infinity` alone. To leave a position alone for *every* family regardless of value, route it
  `:raw` in `call_routes:` instead (see `Mutare.CallRouting`).

  Integer literals are pervasive, so this is the highest-volume built-in — the cost is paid in the denominator, the benefit is catching constants the suite never pins down. The integer sibling of `Mutare.Mutators.FloatLiteral` (`step` 1, `zero` 0); the boolean flip that used to share this family now lives in `Mutare.Mutators.BooleanLiteral`.

  Filterable variants — qualify a `# mutare:ignore` filter with `:label` to suppress just one kind (`c:Mutare.Mutator.variants/0`): `zero`, `succ`, `pred`.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # The shared mark label for a duration/timeout literal. Public so `Mutare.Mutators.AtomLiteral`
  # reacts to the same label on the same positions (see `argument_marks/1`).
  @timeout_mark :timeout

  # The timeout/duration argument positions this family (and AtomLiteral) leaves alone, keyed by
  # the call's **effective** arity — a piped receiver counts as argument 0, and an arity whose
  # trailing list is data rather than options (`Task.async_stream/4`, the MFA callback-args form) is
  # deliberately absent. `{module, function, effective_arity, [effective_index]}`.
  @timeout_positional [
    {Process, :sleep, 1, [0]},
    {:timer, :sleep, 1, [0]},
    {Process, :send_after, 3, [2]},
    {Process, :send_after, 4, [2]},
    {GenServer, :call, 3, [2]},
    # `multi_call/3` is `(nodes, name, request)` — the third arg is the request, not the timeout, so
    # only `/4` `(nodes, name, request, timeout)` carries one.
    {GenServer, :multi_call, 4, [3]},
    {GenServer, :stop, 3, [2]},
    # Agent's `get`/`get_and_update`/`update` carry a trailing timeout: the fun form at `/3` (index 2)
    # and the MFA form at `/5` (index 4 — the `args` list at index 3 is data and still mutates).
    {Agent, :get, 3, [2]},
    {Agent, :get, 5, [4]},
    {Agent, :get_and_update, 3, [2]},
    {Agent, :get_and_update, 5, [4]},
    {Agent, :update, 3, [2]},
    {Agent, :update, 5, [4]},
    {Agent, :stop, 3, [2]},
    {Supervisor, :stop, 3, [2]},
    {DynamicSupervisor, :stop, 3, [2]},
    {Task, :await, 2, [1]},
    {Task, :await_many, 2, [1]},
    {Task, :yield, 2, [1]},
    {Task, :yield_many, 2, [1]},
    {Task, :shutdown, 2, [1]},
    # Duration *constructors*, not timeout positions: `:timer.seconds(5)` is `5 * 1000`, so every
    # argument is a magnitude that is opaque wherever the result flows — the `5` in
    # `Process.sleep(:timer.seconds(5))` is as unmutatable as the `5000` in `Process.sleep(5000)`.
    {:timer, :seconds, 1, [0]},
    {:timer, :minutes, 1, [0]},
    {:timer, :hours, 1, [0]},
    {:timer, :hms, 3, [0, 1, 2]},
    # `:timer` scheduling functions — the delay/interval is always the *first* argument (index 0),
    # unlike `Process.send_after`'s third. (`apply_after/2` and `apply_interval/2`, the fun forms,
    # are OTP 27+; harmless where absent, since the match is syntactic against the target's source.)
    {:timer, :apply_after, 2, [0]},
    {:timer, :apply_after, 4, [0]},
    {:timer, :apply_interval, 2, [0]},
    {:timer, :apply_interval, 4, [0]},
    {:timer, :send_after, 2, [0]},
    {:timer, :send_after, 3, [0]},
    {:timer, :send_interval, 2, [0]},
    {:timer, :send_interval, 3, [0]},
    {:timer, :exit_after, 2, [0]},
    {:timer, :exit_after, 3, [0]},
    {:timer, :kill_after, 1, [0]},
    {:timer, :kill_after, 2, [0]}
  ]

  # The trailing-keyword timeout *options*, keyed by effective arity for the same reason — only the
  # option-bearing arities appear. `{module, function, effective_arity, [option_key]}`.
  @timeout_keyword [
    {Task, :async_stream, 3, [:timeout]},
    {Task, :async_stream, 5, [:timeout]},
    {Task.Supervisor, :async_stream, 4, [:timeout]},
    {Task.Supervisor, :async_stream, 6, [:timeout]},
    # `async_stream_nolink` is the unlinked twin with the identical options surface (only on
    # `Task.Supervisor`; `Task` has no such variant).
    {Task.Supervisor, :async_stream_nolink, 4, [:timeout]},
    {Task.Supervisor, :async_stream_nolink, 6, [:timeout]},
    {Task, :yield_many, 2, [:timeout]}
  ]

  @impl Mutare.Mutator
  def name, do: :integer

  @doc """
  The built-in timeout/duration argument marks (the `:timeout` label), config-independent. Public so
  `Mutare.Mutators.AtomLiteral` can declare the identical positions — keeping the two value families'
  view of "an opaque timeout literal" in one place.
  """
  @spec timeout_marks() :: [
          {module(), atom(), arity(), [non_neg_integer() | {:keyword, atom()}], atom()}
        ]
  def timeout_marks do
    Enum.map(@timeout_positional, fn {mod, fun, arity, indices} ->
      {mod, fun, arity, indices, @timeout_mark}
    end) ++
      Enum.map(@timeout_keyword, fn {mod, fun, arity, keys} ->
        {mod, fun, arity, Enum.map(keys, &{:keyword, &1}), @timeout_mark}
      end)
  end

  # The built-in timeout table. Project-specific positions arrive through the `argument_marks:`
  # option (a run-level declarer in `Mutare.Transform.Resolve.ArgumentMarks`), not through this
  # family's own config.
  @impl Mutare.Mutator
  def argument_marks(_config), do: timeout_marks()

  # Decline at a marked timeout position (an integer there is a magic duration constant the suite
  # can't pin — a near-unkillable equivalent mutant); otherwise mutate the node normally. `mutate/2`
  # takes precedence over `mutate/1` at dispatch, so the gate applies to every offer while the
  # node-level `mutate/1` clauses below stay reusable (and directly callable in tests).
  @impl Mutare.Mutator
  def mutate(node, context) do
    if Mutare.Mutator.marked?(context, @timeout_mark), do: :skip, else: mutate(node)
  end

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}) when is_integer(n), do: Helpers.numeric_mutations(n, 1, 0)

  def mutate(_node), do: :skip

  # Variant vocabulary for `# mutare:ignore[integer:<label>]`: the *semantic kind* of the change,
  # not the resulting value (which is unbounded). `succ` = `n + 1`, `pred` = `n - 1`, `zero` = the
  # `0` sentinel (all three tagged by `Helpers.numeric_mutations/3` at production). The label(s) ride
  # on each `Mutare.Mutator.Mutation` rather than being re-derived — when the off-by-one collapses
  # *onto* `0` (`n = 1` ⇒ `n - 1 = 0`), that one deduped mutant carries *both* `pred` and `zero`, so
  # either qualifier suppresses it.
  @impl Mutare.Mutator
  def variants, do: ~w(zero succ pred)
end
