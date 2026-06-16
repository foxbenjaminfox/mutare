defmodule Mutare.Ignore.Directive do
  @moduledoc """
  One parsed `# mutare:ignore` directive: the line it suppresses, the mutators it
  admits, and an optional human reason.

    * `line` — the suppressed source line (already resolved from trailing-vs-
      standalone by `Mutare.Ignore`).
    * `mutators` — `:all` (no `[...]` filter ⇒ every mutator), or a `MapSet` of
      mutator-name strings (the `[...]` filter contents). A site matches only if
      its `mutator` name is in the set.
    * `reason` — the free-text explanation, or `nil`.
  """

  @type t :: %__MODULE__{
          line: pos_integer(),
          mutators: :all | MapSet.t(String.t()),
          reason: String.t() | nil
        }

  defstruct [:line, mutators: :all, reason: nil]

  @doc """
  Whether this directive suppresses a mutant produced by `mutator`.

  `:all` admits every mutator; a filter set admits a mutator iff its name
  (`to_string/1` of the family atom) is a member — so an unknown name or an empty
  filter admits nothing (filtering fails safe toward *running* the mutant).
  """
  @spec applies_to?(t(), atom()) :: boolean()
  def applies_to?(%__MODULE__{mutators: :all}, _mutator), do: true

  def applies_to?(%__MODULE__{mutators: %MapSet{} = set}, mutator),
    do: MapSet.member?(set, to_string(mutator))
end
