defmodule Mutare.Mutator.Mutation do
  @moduledoc """
  A replacement AST node with optional report metadata.

  Mutators normally return a bare replacement node. Return a `Mutation` when the replacement also
  needs either of these fields:

    * `note` — text shown with a surviving mutant. It does not suppress the mutant or change its
      score.
    * `variant` — one or more labels used by `# mutare:ignore[family:label]`. A mutator may attach
      the label here or derive it with `c:Mutare.Mutator.variant/2`.

  `Mutation` values are accepted by `c:Mutare.Mutator.mutate/1`,
  `c:Mutare.Mutator.mutate/2`, and `c:Mutare.Mutator.MacroHost.host/2`. Use this struct rather than
  a plain map, because a map is also a valid replacement AST node.
  """

  @typedoc "A produced mutation's variant label(s): `nil`, one label, or a list (see `c:Mutare.Mutator.variant/2`)."
  @type variant :: nil | String.t() | atom() | [String.t() | atom()]

  @enforce_keys [:node]
  defstruct [:node, note: nil, variant: nil]

  @type t :: %__MODULE__{node: Macro.t(), note: String.t() | nil, variant: variant()}

  @doc """
  Build a `Mutare.Mutator.Mutation` for replacement `node`, optionally carrying per-mutant metadata.

  The terse common case is a bare node, or a node plus an advisory `note` string — a thin
  constructor so a mutator reads `Mutation.new(mutated, "kill needs NULL data")` rather than the
  struct literal:

      Mutation.new(mutated)                          # the bare node wrapped, no metadata
      Mutation.new(mutated, "kill needs NULL data")  # node + note

  To attach a `# mutare:ignore` `variant` label as well as — or instead of — a note, pass a
  keyword list (both keys optional). This is the form a custom mutator reaches for when it wants a
  mutant that is **both** noted *and* tagged (e.g. an equivalence-sensitive family that classifies
  the kind of mutant it just produced):

      Mutation.new(mutated, note: "kill needs NULL data", variant: "zero")
      Mutation.new(mutated, variant: "zero")         # variant only — same as `tagged/2`

  `note` must be a string or `nil`; `variant` is a `t:variant/0` (`nil`, one label, or a list of
  labels). An unknown key raises `ArgumentError`. `tagged/2` is the variant-only shorthand.
  """
  @spec new(Macro.t(), String.t() | nil | keyword()) :: t()
  def new(node, note_or_opts \\ nil)

  def new(node, note) when is_binary(note) or is_nil(note),
    do: %__MODULE__{node: node, note: note}

  def new(node, opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:note, :variant])
    note = opts[:note]

    unless is_binary(note) or is_nil(note) do
      raise ArgumentError, "Mutation.new/2 :note must be a string or nil, got: #{inspect(note)}"
    end

    %__MODULE__{node: node, note: note, variant: opts[:variant]}
  end

  @doc """
  Build a `Mutare.Mutator.Mutation` tagging replacement `node` with its `# mutare:ignore`
  `variant` label(s) (see the `variant` field) — the production-time alternative to
  `c:Mutare.Mutator.variant/2`. A value family reads cleaner as
  `Mutation.tagged(AST.literal(0), "zero")` than re-deriving the label afterwards.
  """
  @spec tagged(Macro.t(), variant()) :: t()
  def tagged(node, variant), do: %__MODULE__{node: node, variant: variant}
end
