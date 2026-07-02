defmodule Mutare.Mutator.Mutation do
  @moduledoc """
  A replacement AST node with optional report metadata.

  Mutators normally return a bare replacement node. Return a `Mutation` when the replacement also
  needs either of these fields:

    * `note` — text shown with a surviving mutant. It does not suppress the mutant or change its
      score.
    * `variant` — one or more labels used by `# mutare:ignore[family:label]`. A mutator may attach
      the label here or derive it with `c:Mutare.Mutator.variant/2`.
    * `producer` — the `Mutare.Mutator.Spec` this mutation is recorded under *instead of* the
      mutator that returned it. Set it only when relaying a mutation another family reasoned
      about — the selector-host sub-contract case, where `c:Mutare.Mutator.MacroHost.host/2`
      returns interior mutants collected from core's families via
      `Mutare.Analyze.expression_mutations/3`: the site (and its `# mutare:ignore` vocabulary)
      then belongs to the producing family, not the host. `nil` (the default) records the
      mutation under the returning mutator, exactly as before.

  `Mutation` values are accepted by `c:Mutare.Mutator.mutate/1`,
  `c:Mutare.Mutator.mutate/2`, and `c:Mutare.Mutator.MacroHost.host/2`. Use this struct rather than
  a plain map, because a map is also a valid replacement AST node.
  """

  @typedoc "A produced mutation's variant label(s): `nil`, one label, or a list (see `c:Mutare.Mutator.variant/2`)."
  @type variant :: nil | String.t() | atom() | [String.t() | atom()]

  @enforce_keys [:node]
  defstruct [:node, note: nil, variant: nil, producer: nil]

  @type t :: %__MODULE__{
          node: Macro.t(),
          note: String.t() | nil,
          variant: variant(),
          producer: Mutare.Mutator.Spec.t() | nil
        }

  @doc """
  Builds a mutation for replacement `node`.

  The second argument may be a note string or a keyword list containing `:note`,
  `:variant`, and `:producer`:

      Mutation.new(mutated)
      Mutation.new(mutated, "kill needs boundary data")
      Mutation.new(mutated, note: "kill needs boundary data", variant: "zero")
      Mutation.new(mutated, variant: "zero")
      Mutation.new(mutated, producer: literal_spec)

  `note` must be a string or `nil`. `variant` may be one label, a list of labels,
  or `nil`. `producer` must be a `Mutare.Mutator.Spec` or `nil` (see the moduledoc).
  Unknown options raise `ArgumentError`.

  ## Examples

      iex> alias Mutare.Mutator.Mutation
      iex> mutation = Mutation.new(:replacement, note: "needs a boundary test", variant: "zero")
      iex> {mutation.node, mutation.note, mutation.variant}
      {:replacement, "needs a boundary test", "zero"}

      iex> alias Mutare.Mutator.Mutation
      iex> Mutation.new(:replacement, "shown for survivors").note
      "shown for survivors"
  """
  @spec new(Macro.t(), String.t() | nil | keyword()) :: t()
  def new(node, note_or_opts \\ nil)

  def new(node, note) when is_binary(note) or is_nil(note),
    do: %__MODULE__{node: node, note: note}

  def new(node, opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:note, :variant, :producer])
    note = opts[:note]
    producer = opts[:producer]

    unless is_binary(note) or is_nil(note) do
      raise ArgumentError, "Mutation.new/2 :note must be a string or nil, got: #{inspect(note)}"
    end

    unless is_nil(producer) or is_struct(producer, Mutare.Mutator.Spec) do
      raise ArgumentError,
            "Mutation.new/2 :producer must be a Mutare.Mutator.Spec or nil, " <>
              "got: #{inspect(producer)}"
    end

    %__MODULE__{node: node, note: note, variant: opts[:variant], producer: producer}
  end

  @doc """
  Builds a mutation with one or more ignore-variant labels.

  This is equivalent to `new(node, variant: variant)`.

  ## Examples

      iex> alias Mutare.Mutator.Mutation
      iex> Mutation.tagged(:replacement, ["pred", "zero"]).variant
      ["pred", "zero"]
  """
  @spec tagged(Macro.t(), variant()) :: t()
  def tagged(node, variant), do: %__MODULE__{node: node, variant: variant}
end
