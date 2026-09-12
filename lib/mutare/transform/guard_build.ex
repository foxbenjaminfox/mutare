defmodule Mutare.Transform.GuardBuild do
  @moduledoc false

  # Construction of the dispatch guards that gate a mutant clause on the active mutant id —
  # shared by lifted functions, anonymous functions, receives, and tupled cases.
  # Pure AST builders with no `Ctx`: each
  # takes the per-file dispatch variable (`var`) and ids and returns a guard expression.
  #
  # Every operator this module generates is an explicit `:erlang` call (`Mutare.AST.erlang_call/2`)
  # — the gate, the exclusions, and the conjunctions that join them — so a target that narrows or
  # replaces `Kernel`'s imports cannot change what a generated guard means. `Mutare.Manifest`
  # recognises the gate in that form; the two must move together. The conjunctions
  # (`:erlang.andalso`/`orelse`, what `Kernel.and`/`or` expand to in a guard) are legal *only* in
  # a guard, which every caller of this module emits into; a body-position short-circuit is a
  # `case` (`Recorder.record_ast/3`).
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
  def gate(id, var),
    do: erlang(:"=:=", [Recorder.catch_all_pattern(var), AST.literal(id)])

  @doc """
  AND `gate` into a guard expression, distributing over a top-level `when` (`a when b` is the
  guard's OR) so each alternative becomes `gate and <alt>` — a `when` may never appear *inside*
  `and`, so we recurse to the leaves. `nil` (no original guard) leaves just the gate.
  """
  @spec and_into(Macro.t(), Macro.t() | nil) :: Macro.t()
  def and_into(gate, nil), do: gate

  def and_into(gate, {:when, meta, alts}),
    do: {:when, meta, Enum.map(alts, &and_into(gate, &1))}

  def and_into(gate, expr), do: both(gate, expr)

  @doc """
  Collapse a clause's guard list (`[]` or a single expr; multiple is a defensive `and`-fold)
  into one expression, or `nil` when empty.
  """
  @spec combine([Macro.t()]) :: Macro.t() | nil
  def combine([]), do: nil
  def combine([guard]), do: guard
  def combine([g | rest]), do: Enum.reduce(rest, g, &both(&2, &1))

  @doc """
  Exclude exactly the supplied integer ids, preserving holes (including poison-skipped ids).

  Consecutive runs of seven or more become `<var> < first or <var> > last`; shorter runs
  retain strict `!==` comparisons. One shared non-integer escape preserves strict inequality
  for floats and every other term. Exclusion operators use explicit Erlang calls so a target's
  displaced Kernel imports cannot change them. Seven saves source AST nodes even after that
  qualification and the escape. Conjunctions are balanced so scattered ids do not produce a left-deep guard.
  `nil` for no ids. No literal id lists are emitted (small lists can render as charlists).
  """
  @spec exclusion([non_neg_integer()], atom()) :: Macro.t() | nil
  def exclusion([], _var), do: nil

  def exclusion(ids, var) do
    active = Recorder.catch_all_pattern(var)
    runs = ids |> Enum.sort() |> Enum.dedup() |> consecutive_runs()

    expressions =
      Enum.flat_map(runs, fn {first, last} ->
        if last - first >= 6 do
          [
            either(
              erlang(:<, [active, AST.literal(first)]),
              erlang(:>, [active, AST.literal(last)])
            )
          ]
        else
          Enum.map(first..last, &erlang(:"=/=", [active, AST.literal(&1)]))
        end
      end)

    excluded = balanced_and(expressions)

    if Enum.any?(runs, fn {first, last} -> last - first >= 6 end) do
      either(erlang(:not, [erlang(:is_integer, [active])]), excluded)
    else
      excluded
    end
  end

  defp either(left, right), do: erlang(:orelse, [left, right])
  defp both(left, right), do: erlang(:andalso, [left, right])
  defp erlang(name, args), do: AST.erlang_call(name, args)

  defp consecutive_runs([first | rest]) do
    rest
    |> Enum.reduce([{first, first}], fn
      id, [{first, last} | runs] when id == last + 1 -> [{first, id} | runs]
      id, runs -> [{id, id} | runs]
    end)
    |> Enum.reverse()
  end

  defp balanced_and([expr]), do: expr

  defp balanced_and(expressions) do
    expressions
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [left, right] -> both(left, right)
      [last] -> last
    end)
    |> balanced_and()
  end

  @doc "Merge an exclusion guard with the clause's own guard (either may be `nil`)."
  @spec merge(Macro.t() | nil, Macro.t() | nil) :: Macro.t() | nil
  def merge(nil, orig), do: orig
  def merge(excl, nil), do: excl
  def merge(excl, orig), do: and_into(excl, orig)
end
