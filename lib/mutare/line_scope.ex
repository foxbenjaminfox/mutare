defmodule Mutare.LineScope do
  @moduledoc false

  # The `:only_lines` scope (`--line`, `--since`, `only_lines:` in `.mutare.exs`), read in one
  # place. An entry names a whole line, `{file, line}`, or one position on it,
  # `{file, line, column}`: the `line:column` a `Mutare.Site` is keyed at
  # (`Mutare.Site.position/1`), which the human report prints and a user pastes back. A
  # position selects every mutant keyed there — nested nodes that start at one character
  # share it, so it narrows a line rather than naming one mutant.
  #
  # The schema's site filter and the count pass's selection both match through `selects?/4`,
  # so the ids the metamutant emits are exactly the sites the run keeps.

  @type entry :: {String.t(), pos_integer()} | {String.t(), pos_integer(), pos_integer()}
  @type t :: MapSet.t(entry())

  @doc "The files a scope names."
  @spec files(t()) :: MapSet.t(String.t())
  def files(scope), do: MapSet.new(scope, &elem(&1, 0))

  @doc "Whether `scope` selects a mutant in `file` keyed at `line`/`column`."
  @spec selects?(t(), String.t(), pos_integer() | nil, pos_integer() | nil) :: boolean()
  def selects?(scope, file, line, column),
    do: MapSet.member?(scope, {file, line}) or MapSet.member?(scope, {file, line, column})

  @doc """
  The entries of `scope` on one of `lines` (`{file, line}` pairs, as `Mutare.Changes`
  reports them) — `--since` narrowing an explicit scope.
  """
  @spec within_lines(t(), MapSet.t({String.t(), pos_integer()})) :: t()
  def within_lines(scope, lines),
    do: MapSet.filter(scope, &MapSet.member?(lines, {elem(&1, 0), elem(&1, 1)}))
end
