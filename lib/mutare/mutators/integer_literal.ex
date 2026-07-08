defmodule Mutare.Mutators.IntegerLiteral do
  @moduledoc """
  Integer-literal mutations: `n` → `n + 1`, `n - 1`, and `0` (the "off-by-one" boundary plus the zero sentinel), deduplicated and never equal to `n`.

  Only literals in *runtime* positions are mutated, never pattern literals. Mutations that would reproduce the original value are dropped (`0` is not re-emitted for the literal `0`; `n - 1` and `0` collapse for `n = 1`).

  An integer literal in a known **timeout/duration position** (`Process.sleep/1`, the third argument of `Process.send_after/3`, the `GenServer.call/3` timeout, `Task.async_stream`'s `:timeout` option, …) is left unmutated — a near-unkillable equivalent mutant that also risks minting false `:timeout` kills. This family owns that knowledge: `c:Mutare.Mutator.argument_marks/1` asks the transform to mark those positions with the `:timeout` label, and `mutate/2` declines when the mark is present. A *computed* duration (`base * 2`) is not a literal at the marked node, so it still mutates. (`Mutare.Mutators.AtomLiteral` reuses the same table to leave `:infinity` alone there.)

  **Configuring extra positions.** Add project-specific positions to leave alone with the `:skip_arguments` option — a list of `{module, function, arity, positions}`, where `positions` is a list of effective argument indices and `{:keyword, key}` option keys (the same shape as the built-in table):

      [mutators: [{Mutare.Mutators.IntegerLiteral, skip_arguments: [
        {MyApp.Cache, :put, 3, [2]},                      # a TTL argument
        {MyApp.Http, :get, 2, [{:keyword, :recv_timeout}]}
      ]}]]

  These are marked with this family's own label, so they suppress only *this* family (integers) at those positions; `Mutare.Mutators.AtomLiteral` takes the same option independently.

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
    {GenServer, :stop, 3, [2]},
    {Agent, :stop, 3, [2]},
    {Supervisor, :stop, 3, [2]},
    {Task, :await, 2, [1]},
    {Task, :await_many, 2, [1]},
    {Task, :yield, 2, [1]},
    {Task, :yield_many, 2, [1]},
    {Task, :shutdown, 2, [1]}
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

  # The built-in timeout table plus any `:skip_arguments` positions the user configured
  # (per-instance, read back by `Mutare.Mutator.self_marked?/1`).
  @impl Mutare.Mutator
  def argument_marks(config) do
    timeout_marks() ++ Mutare.Mutator.skip_arguments_marks(config)
  end

  # Decline at a marked timeout position (an integer there is a magic duration constant the suite
  # can't pin — a near-unkillable equivalent mutant) or a user-configured `:skip_arguments` position;
  # otherwise mutate the node normally. `mutate/2` takes precedence over `mutate/1` at dispatch, so
  # the gate applies to every offer while the node-level `mutate/1` clauses below stay reusable (and
  # directly callable in tests).
  @impl Mutare.Mutator
  def mutate(node, context) do
    if Mutare.Mutator.marked?(context, @timeout_mark) or Mutare.Mutator.self_marked?(context),
      do: :skip,
      else: mutate(node)
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
