defmodule Mutare.Transform.GuardBuild do
  @moduledoc false

  # Construction of the dispatch guards that gate a mutant clause on the active mutant id —
  # shared by the lifted-function path (`__mutare_…` base clauses) and the `case`
  # tuple-the-scrutinee path in `Mutare.Transform`. Pure AST builders with no `Ctx`: each
  # takes the per-file dispatch variable (`var`) and ids and returns a guard expression.
  #
  # `var` is the (possibly salted) dispatch-variable name; `Recorder.catch_all_pattern/1`
  # renders it as the `mutare_active` node both the gate and the recorder read. Ids are
  # rendered with `AST.literal/1` (a clean-meta `{:__block__, [], [id]}`): a *bare* integer
  # makes Sourceror's normalizer assign a `:line` but no `:token`, which crashes the Elixir
  # formatter — the same rule literal mutators follow.

  alias Mutare.AST
  alias Mutare.Coverage.Recorder

  @doc "The `<var> === <id>` activation gate for a mutant clause."
  @spec gate(non_neg_integer(), atom()) :: Macro.t()
  def gate(id, var), do: {:===, [], [Recorder.catch_all_pattern(var), AST.literal(id)]}

  @doc """
  AND `gate` into a guard expression, distributing over a top-level `when` (`a when b` is the
  guard's OR) so each alternative becomes `gate and <alt>` — a `when` may never appear *inside*
  `and`, so we recurse to the leaves. `nil` (no original guard) leaves just the gate.
  """
  @spec and_into(Macro.t(), Macro.t() | nil) :: Macro.t()
  def and_into(gate, nil), do: gate

  def and_into(gate, {:when, meta, alts}),
    do: {:when, meta, Enum.map(alts, &and_into(gate, &1))}

  def and_into(gate, expr), do: {:and, [], [gate, expr]}

  @doc """
  Collapse a clause's guard list (`[]` or a single expr; multiple is a defensive `and`-fold)
  into one expression, or `nil` when empty.
  """
  @spec combine([Macro.t()]) :: Macro.t() | nil
  def combine([]), do: nil
  def combine([guard]), do: guard
  def combine([g | rest]), do: Enum.reduce(rest, g, &{:and, [], [&2, &1]})

  @doc """
  `<var> !== id1 and <var> !== id2 …` (chained `!==`, not `not in [list]` — a bare
  small-integer list can render as a charlist). `nil` for no ids.
  """
  @spec exclusion([non_neg_integer()], atom()) :: Macro.t() | nil
  def exclusion([], _var), do: nil

  def exclusion(ids, var) do
    ids
    |> Enum.map(&{:!==, [], [Recorder.catch_all_pattern(var), AST.literal(&1)]})
    |> Enum.reduce(&{:and, [], [&2, &1]})
  end

  @doc "Merge an exclusion guard with the clause's own guard (either may be `nil`)."
  @spec merge(Macro.t() | nil, Macro.t() | nil) :: Macro.t() | nil
  def merge(nil, orig), do: orig
  def merge(excl, nil), do: excl
  def merge(excl, orig), do: and_into(excl, orig)
end
