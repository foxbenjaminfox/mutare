defmodule Mutare.Mutator.Mutation do
  @moduledoc """
  One mutant carrying an advisory `note` — the noted form of a value a mutator (or a
  selector host) returns.

  Wherever a mutator yields a replacement it may yield either a **bare node** (the common
  case, no note) or a `%Mutare.Mutator.Mutation{}` — a `node` plus a `note` string the report
  surfaces on that mutant's `Mutare.Site`. This is the *only* noted form accepted: a bare
  `%{node:, note:}` map is rejected (a quoted map literal `%{a: 1}` is an ordinary mutation
  *node*, so a bare map can't unambiguously mean "noted mutant"; the struct is unambiguous).

  The `note` is distinct from a `# mutare:ignore` reason (which *suppresses* a mutant): a
  noted mutant is live and scored, the note is just extra signal on a survivor — e.g. a
  hosting mutator flagging "kill may require NULL/boundary data" on an equivalence-sensitive
  SQL comparison.

  Used in two places, normalized by the one `Mutare.Mutator.Dispatch.normalize_mutant/1`:

    * a `c:Mutare.Mutator.mutate/1`/`c:Mutare.Mutator.mutate/2` return-list element
      (alongside a bare node, or `nil` to drop that slot — see `t:Mutare.Mutator.mutation/0`),
      and
    * a selector host target's `:mutants` entry (`c:Mutare.Mutator.host/2`).
  """

  @enforce_keys [:node]
  defstruct [:node, note: nil]

  @type t :: %__MODULE__{node: Macro.t(), note: String.t() | nil}

  @doc """
  Build a `Mutare.Mutator.Mutation` for replacement `node` with an optional `note`.

  A thin constructor so a mutator reads `Mutation.new(mutated, "kill needs NULL data")`
  rather than the struct literal; `new(node)` (no note) is just the bare node wrapped.
  """
  @spec new(Macro.t(), String.t() | nil) :: t()
  def new(node, note \\ nil) when is_binary(note) or is_nil(note),
    do: %__MODULE__{node: node, note: note}
end
