defmodule Mutare.Mutators.ConventionAtom do
  @moduledoc """
  Swap a **convention atom** for its **same-shape sibling** — `:ok` ↔ `:error`,
  `:cont` ↔ `:halt`, `:lt` ↔ `:gt` — rather than for the generic `:mutare` sentinel.
  Asks the question the sentinel can't: does any test distinguish the *success* path
  from the *error* path (or `:cont` from `:halt`, `:lt` from `:gt`) here?

  This is the semantic sibling of `Mutare.Mutators.ModeSwap`: where ModeSwap swaps a
  *mode/unit* atom for a sibling of a closed set in a known stdlib call, this swaps a
  *status/result tag* for its convention sibling wherever it appears as a literal —
  no call context needed, because a convention atom's identity is position-independent.
  It **replaces** `Mutare.Mutators.AtomLiteral`'s coverage of these specific atoms
  (which excludes them by guard, the way `Mutare.Mutators.Literal`/`Conditional` own
  `true`/`false`/`nil`), so a convention atom yields the high-signal sibling, not
  `:mutare`.

  ## Why a sibling beats `:mutare`

  `:mutare` is a guaranteed-never-real value, so where a `case` handles both
  `{:ok, _}` and `{:error, _}`, the mutant `{:mutare, _}` matches *no* clause →
  `CaseClauseError` → killed trivially, telling you nothing. `:error` is a
  *plausible* value the error branch **handles**, so a surviving `:ok` → `:error`
  mutant pinpoints a genuinely untested success/error distinction. The
  more-realistic mutant is the higher-signal one precisely because it is harder to
  kill by accident.

  ## Same-shape only

  A sibling is paired **only when it preserves the surrounding shape**, so the
  mutant is a *plausible alternative* rather than a malformed value:

    * `{:ok, payload}` ↔ `{:error, reason}` — both 2-tuples
    * `{:cont, acc}` ↔ `{:halt, acc}` — both 2-tuples (`Enum.reduce_while`,
      `Stream.transform`)
    * `:lt` ↔ `:gt` — both bare comparator results (`:eq`, the middle, is
      deliberately *unpaired* — its swap is the weaker, more-equivalent-prone
      mutant, so it keeps its `AtomLiteral` `:mutare` mutant)

  OTP return tags (`:reply`/`:noreply`/`:stop`) fail this test — `:reply` implies a
  3-tuple, so swapping the bare atom yields a malformed `{:reply, state}` that just
  crashes (no better than `:mutare`) — and are excluded. 3+ member conventions are
  carried as the **polarity pair only** (mirroring `Numeric`/`Relational`'s
  "complementary pairs, not a full mesh"), so the table stays a flat list of pairs.

  ## Configurable

  A codebase's own tag conventions are added via `{module, opts}` with a `:pairs`
  option (each a same-shape sibling pair), merged with the built-ins:

      [mutators: [..., {Mutare.Mutators.ConventionAtom, pairs: [[:active, :inactive]]}]]

  The parameters arrive in `mutate/2`'s context (`context.opts`). An unconfigured
  instance still gets the built-ins.

  Like `AtomLiteral`, it mutates a convention atom wherever an atom literal appears —
  value positions, `def`/`defp` head patterns, and `case` clause patterns — but never a
  bare atom that is a function name (`:upcase` in `String.upcase`). On by default.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  # Same-shape sibling pairs. Each is bidirectional; a 3+ member convention is carried as
  # its polarity pair only (`:lt`/`:gt`, not `:lt`/`:eq`/`:gt`), keeping signal high.
  @pairs [
    [:ok, :error],
    [:cont, :halt],
    [:lt, :gt]
  ]

  # {atom => [sibling, ...]}, built once at compile time.
  @swaps for pair <- @pairs, a <- pair, into: %{}, do: {a, pair -- [a]}

  # The flat set of built-in convention atoms — `Mutare.Mutators.AtomLiteral` reads this to
  # exclude them (the ownership split), so it stays the single source of truth.
  @members @pairs |> List.flatten() |> Enum.uniq()

  @impl Mutare.Mutator
  def name, do: :convention

  @doc """
  The built-in convention atoms, as a flat list. `Mutare.Mutators.AtomLiteral` excludes
  these so each yields its convention sibling here, not the `:mutare` sentinel.
  """
  @spec members() :: [atom()]
  def members, do: @members

  @impl Mutare.Mutator
  def mutate(node, %{opts: opts}) do
    case atom_value(node) do
      nil ->
        :skip

      atom ->
        case swaps(atom, opts) do
          [] -> :skip
          siblings -> Enum.map(siblings, &AST.literal/1)
        end
    end
  end

  # The sibling atoms for a swap: the built-in pairs plus any configured `:pairs`.
  defp swaps(atom, opts) do
    (Map.get(@swaps, atom, []) ++ user_swaps(atom, opts)) |> Enum.uniq()
  end

  # Siblings drawn from a `{module, pairs: [...]}` configuration; `[]` for an unconfigured
  # mutator or a non-keyword/ill-formed `:pairs`.
  defp user_swaps(atom, opts) do
    pairs = if Keyword.keyword?(opts), do: Keyword.get(opts, :pairs, []), else: []
    for pair <- pairs, is_list(pair), atom in pair, sib <- pair -- [atom], do: sib
  end

  # The atom carried by a *wrapped* literal node — `true`/`false`/`nil` are not convention
  # atoms, and a bare atom is a function name/operator the analyzer never offers as a value
  # (matched only block-wrapped, exactly like `AtomLiteral`).
  defp atom_value({:__block__, _meta, [a]}) when is_atom(a) and a not in [true, false, nil],
    do: a

  defp atom_value(_node), do: nil
end
