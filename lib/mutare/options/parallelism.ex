defmodule Mutare.Options.Parallelism do
  @moduledoc false
  # How the per-mutant phase divides the machine: `:workers` concurrent `mix test` BEAMs, each
  # trimmed to `:schedulers` scheduler threads, so that `workers × schedulers ≈ budget` and the
  # runs do not oversubscribe the CPU. The two options depend on each other, so neither can be
  # defaulted by its own validator; `Mutare.Options` resolves the pair here, once, after both
  # are validated. Why this shape, and what it replaced: NOTES "Parallel workers".
  #
  # The budget is `System.schedulers_online/0` — what *this* BEAM was allotted, which already
  # honours a container's CPU quota and a `+S` the user passed to Mutare itself. So an inherited
  # `+S` shrinks what is divided rather than being overridden or parsed.

  @typedoc "A worker BEAM's scheduler count; `:all` passes no `+S`, leaving it every scheduler."
  @type schedulers :: pos_integer() | :all

  # With nothing to go on, workers stay a small constant: each is a whole BEAM (memory measured
  # at ~1 GB on a large target), boots against the same singletons as its siblings, and — under
  # `:partition_env` — needs a database of its own.
  @max_default_workers 4

  @doc """
  Resolve the pair from what the user gave (`nil` = not given) and the scheduler `budget`.

  Whatever was given is returned untouched; a missing side is derived from the other so the
  product stays within the budget (floored — a spare core is kinder than an oversubscribed
  one), and never below one. Resolving an already-resolved pair returns it unchanged.

      iex> Mutare.Options.Parallelism.resolve(nil, nil, 16)
      {4, 4}
      iex> Mutare.Options.Parallelism.resolve(8, nil, 16)
      {8, 2}
      iex> Mutare.Options.Parallelism.resolve(nil, 2, 16)
      {8, 2}
      iex> Mutare.Options.Parallelism.resolve(nil, :all, 16)
      {4, :all}
  """
  @spec resolve(pos_integer() | nil, schedulers() | nil, pos_integer()) ::
          {pos_integer(), schedulers()}
  def resolve(nil, nil, budget) do
    workers = default_workers(budget)
    {workers, share(budget, workers)}
  end

  def resolve(nil, :all, budget), do: {default_workers(budget), :all}
  def resolve(nil, schedulers, budget), do: {share(budget, schedulers), schedulers}
  def resolve(workers, nil, budget), do: {workers, share(budget, workers)}
  def resolve(workers, schedulers, _budget), do: {workers, schedulers}

  @doc """
  How many times over `runs` concurrent BEAMs of `schedulers` threads each ask for a
  `machine` of that many cores. Above 1 only for `:all` (every run takes the whole machine)
  or for counts the user chose whose product exceeds it — more workers than cores included.

      iex> Mutare.Options.Parallelism.oversubscription(4, 4, 16)
      1.0
      iex> Mutare.Options.Parallelism.oversubscription(4, :all, 16)
      4.0
  """
  @spec oversubscription(non_neg_integer(), schedulers(), pos_integer()) :: float()
  def oversubscription(runs, :all, _machine), do: runs * 1.0
  def oversubscription(runs, schedulers, machine), do: runs * schedulers / machine

  defp default_workers(budget), do: budget |> div(2) |> min(@max_default_workers) |> max(1)

  defp share(budget, parts), do: budget |> div(parts) |> max(1)
end
