defmodule Mutare.Mutators.ConventionAtom do
  @moduledoc """
  Replaces convention atoms with a compatible alternative:

    * `{:ok, payload}` ↔ `{:error, reason}` — both 2-tuples
    * `{:cont, acc}` ↔ `{:halt, acc}` — both 2-tuples (`Enum.reduce_while`, `Stream.transform`)
    * `:lt` ↔ `:gt` — bare comparison results

  These atoms are excluded from `Mutare.Mutators.AtomLiteral`, so only the compatible replacement is emitted. `:eq` remains under `AtomLiteral`. OTP return tags such as `:reply`, `:noreply`, and `:stop` are not included because changing only the tag can produce an invalid return tuple.

  ## Configurable

  Add application-specific pairs with the `:pairs` option:

      [mutators: [..., {Mutare.Mutators.ConventionAtom, pairs: [[:active, :inactive]]}]]

  Custom pairs extend the built-in pairs; they do not replace them. For example, `pairs: [[:ok, :okay]]` makes `:ok` mutate to both `:error` and `:okay`.

  Set `call_option_keys: false` to skip atoms used as call-option names without changing ordinary atom values:

      {Mutare.Mutators.ConventionAtom, call_option_keys: false}

  The family applies in value positions and patterns, but not where an atom names a function. An `:ok` that is a unit-returning function's return tail — every return path of every clause literally `:ok` or `nil`, and the function not a behaviour callback — is not a value position and is left alone; there the atom spells "no value", not data (see the exclusions in `Mutare.Mutators.ReturnValue`). It is enabled by default.
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

  @impl Mutare.Mutator
  def mutate_call_option_keys?(opts) do
    not (Keyword.keyword?(opts) and Keyword.get(opts, :call_option_keys, true) == false)
  end

  @doc """
  Returns the built-in convention atoms.

  `Mutare.Mutators.AtomLiteral` excludes these atoms so this family can replace
  them with their configured convention sibling.
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
  # Additive by construction — `++` *extends* the built-ins, never replaces them, so a
  # configured pair only ever adds siblings (including to a built-in atom's own set).
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
