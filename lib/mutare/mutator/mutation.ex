defmodule Mutare.Mutator.Mutation do
  @moduledoc """
  One mutant carrying per-mutant metadata — an advisory `note` and/or a `# mutare:ignore`
  `variant` label — the enriched form of a value a mutator (or a selector host) returns.

  Wherever a mutator yields a replacement it may yield either a **bare node** (the common
  case, no metadata) or a `%Mutare.Mutator.Mutation{}` — a `node` plus optional `note`/`variant`.
  This is the *only* enriched form accepted: a bare `%{node:, …}` map is rejected (a quoted map
  literal `%{a: 1}` is an ordinary mutation *node*, so a bare map can't unambiguously mean
  "enriched mutant"; the struct is unambiguous).

  Two independent pieces of metadata, both surfaced on the mutant's `Mutare.Site`:

    * **`note`** — an advisory string the report shows on a survivor (e.g. a hosting mutator
      flagging "kill may require NULL/boundary data"). Distinct from a `# mutare:ignore` reason
      (which *suppresses* a mutant): a noted mutant is live and scored.
    * **`variant`** — the `# mutare:ignore[family:label]` variant label(s) (see
      `c:Mutare.Mutator.variants/0`), attached **at production time** by a mutator that knows
      which *kind* of mutation it just produced — the alternative to deriving the label from the
      node afterwards via `c:Mutare.Mutator.variant/2`. A value family (`Literal`/`StringLiteral`/…)
      tags here, where the semantic kind (`zero`/`empty`/`sentinel`) is known at construction; an
      operator family leaves it `nil` and lets `variant/2` read it off the swapped node. `nil` (no
      tag), a single label, or a list of labels — normalized downstream like `variant/2`'s return.

  Used in two places, normalized by the one `Mutare.Mutator.Dispatch.normalize_mutant/1`:

    * a `c:Mutare.Mutator.mutate/1`/`c:Mutare.Mutator.mutate/2` return-list element
      (alongside a bare node, or `nil` to drop that slot — see `t:Mutare.Mutator.mutation/0`),
      and
    * a selector host target's `:mutants` entry (`c:Mutare.Mutator.MacroAware.host/2`).
  """

  @typedoc "A produced mutation's variant label(s): `nil`, one label, or a list (see `c:Mutare.Mutator.variant/2`)."
  @type variant :: nil | String.t() | atom() | [String.t() | atom()]

  @enforce_keys [:node]
  defstruct [:node, note: nil, variant: nil]

  @type t :: %__MODULE__{node: Macro.t(), note: String.t() | nil, variant: variant()}

  @doc """
  Build a `Mutare.Mutator.Mutation` for replacement `node` with an optional `note`.

  A thin constructor so a mutator reads `Mutation.new(mutated, "kill needs NULL data")`
  rather than the struct literal; `new(node)` (no note) is just the bare node wrapped. To
  attach a variant label instead of a note, use `tagged/2`.
  """
  @spec new(Macro.t(), String.t() | nil) :: t()
  def new(node, note \\ nil) when is_binary(note) or is_nil(note),
    do: %__MODULE__{node: node, note: note}

  @doc """
  Build a `Mutare.Mutator.Mutation` tagging replacement `node` with its `# mutare:ignore`
  `variant` label(s) (see the `variant` field) — the production-time alternative to
  `c:Mutare.Mutator.variant/2`. A value family reads cleaner as
  `Mutation.tagged(AST.literal(0), "zero")` than re-deriving the label afterwards.
  """
  @spec tagged(Macro.t(), variant()) :: t()
  def tagged(node, variant), do: %__MODULE__{node: node, variant: variant}
end
