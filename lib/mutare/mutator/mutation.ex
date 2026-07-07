defmodule Mutare.Mutator.Mutation do
  @moduledoc """
  A replacement AST node with optional report metadata.

  Mutators normally return a bare replacement node. Return a `Mutation` when the replacement also needs either of these fields:

    * `note` — text shown with a surviving mutant. It does not suppress the mutant or change its score.
    * `variant` — one or more labels used by `# mutare:ignore[family:label]`. A mutator may attach the label here or derive it with `c:Mutare.Mutator.variant/2`.
    * `producer` — the `Mutare.Mutator.Spec` this mutation is recorded under *instead of* the mutator that returned it. Set it only when relaying a mutation another family reasoned about — the selector-host sub-contract case, where `c:Mutare.Mutator.MacroHost.host/2` returns interior mutants collected from core's families via `Mutare.Analyze.expression_mutations/3`: the site (and its `# mutare:ignore` vocabulary) then belongs to the producing family, not the host. `nil` (the default) records the mutation under the returning mutator, exactly as before.
    * `attribution` — decouples *where the mutant is reported* from *what is spliced into the metamutant*. Set it when `:node` is a **whole-node rewrite** whose textual footprint is one inner clause — a `mutate/2` that rebuilds and returns an entire `from(...)` query but only changed its `order_by:`. Without it the site's line/column and before/after diff are pinned to the offered node (the whole `from`), so a multi-line rewrite reports every mutant at the `from` line and `# mutare:ignore` (line-keyed) cannot target the clause. Build one with `at/2` (a replacement clause) or `at_drop/1` (a removed clause); the metamutant is still built by splicing `:node`, attribution only moves the report. `nil` (the default) attributes to the offered node, exactly as before.

  `Mutation` values are accepted by `c:Mutare.Mutator.mutate/1`, `c:Mutare.Mutator.mutate/2`, and `c:Mutare.Mutator.MacroHost.host/2`. Use this struct rather than a plain map, because a map is also a valid replacement AST node.
  """

  defmodule Attribution do
    @moduledoc """
    A report-location override for a `Mutare.Mutator.Mutation` (see its `:attribution` field).

    Names the clause a whole-node rewrite should be *reported at*, independent of the node spliced
    into the metamutant. `original` is the clause before the change (its range locates the site and
    renders the diff's "before"); `mutated` is the clause after — a replacement node for `at/2`, or
    the atom `:drop` for `at_drop/1` (a removed clause, reported as a delete). Built only through
    `Mutare.Mutator.Mutation.at/2` and `Mutare.Mutator.Mutation.at_drop/1`.
    """

    @enforce_keys [:original, :mutated]
    defstruct [:original, :mutated]

    @type t :: %__MODULE__{original: Macro.t(), mutated: Macro.t() | :drop}
  end

  @typedoc "A produced mutation's variant label(s): `nil`, one label, or a list (see `c:Mutare.Mutator.variant/2`)."
  @type variant :: nil | String.t() | atom() | [String.t() | atom()]

  @enforce_keys [:node]
  defstruct [:node, note: nil, variant: nil, producer: nil, attribution: nil]

  @type t :: %__MODULE__{
          node: Macro.t(),
          note: String.t() | nil,
          variant: variant(),
          producer: Mutare.Mutator.Spec.t() | nil,
          attribution: Attribution.t() | nil
        }

  @doc """
  Builds a mutation for replacement `node`.

  The second argument may be a note string or a keyword list containing `:note`,
  `:variant`, `:producer`, and `:attribution`:

      Mutation.new(mutated)
      Mutation.new(mutated, "kill needs boundary data")
      Mutation.new(mutated, note: "kill needs boundary data", variant: "zero")
      Mutation.new(mutated, variant: "zero")
      Mutation.new(mutated, producer: literal_spec)
      Mutation.new(rebuilt_from, attribution: Mutation.at(order_by, flipped_order_by))

  `note` must be a string or `nil`. `variant` may be one label, a list of labels,
  or `nil`. `producer` must be a `Mutare.Mutator.Spec` or `nil` (see the moduledoc).
  `attribution` must be a `Mutare.Mutator.Mutation.Attribution` (from `at/2`/`at_drop/1`)
  or `nil`. Unknown options raise `ArgumentError`.

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
    opts = Keyword.validate!(opts, [:note, :variant, :producer, :attribution])
    note = opts[:note]
    producer = opts[:producer]
    attribution = opts[:attribution]

    unless is_binary(note) or is_nil(note) do
      raise ArgumentError, "Mutation.new/2 :note must be a string or nil, got: #{inspect(note)}"
    end

    unless is_nil(producer) or is_struct(producer, Mutare.Mutator.Spec) do
      raise ArgumentError,
            "Mutation.new/2 :producer must be a Mutare.Mutator.Spec or nil, " <>
              "got: #{inspect(producer)}"
    end

    unless is_nil(attribution) or is_struct(attribution, Attribution) do
      raise ArgumentError,
            "Mutation.new/2 :attribution must be built with Mutation.at/2 or Mutation.at_drop/1, " <>
              "got: #{inspect(attribution)}"
    end

    %__MODULE__{
      node: node,
      note: note,
      variant: opts[:variant],
      producer: producer,
      attribution: attribution
    }
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

  @doc """
  Builds a report-location override that shows `original` replaced by `mutated`.

  Pass the result as a mutation's `:attribution` (see the moduledoc). `original` and `mutated`
  are the clause **before** and **after** the change — the site is located at `original`'s range
  and its diff renders `original → mutated`, even though the mutation's `:node` splices a larger
  rewrite into the metamutant.

  ## Examples

      iex> alias Mutare.Mutator.Mutation
      iex> %Mutation.Attribution{mutated: :desc} = Mutation.at(:asc, :desc)
  """
  @spec at(Macro.t(), Macro.t()) :: Attribution.t()
  def at(original, mutated), do: %Attribution{original: original, mutated: mutated}

  @doc """
  Builds a report-location override that shows `original` **removed**.

  Pass the result as a mutation's `:attribution` (see the moduledoc). The site is located at
  `original`'s range and recorded as a deletion (a delete-style diff over the clause), even though
  the mutation's `:node` splices the rewritten, clause-less node into the metamutant.

  ## Examples

      iex> alias Mutare.Mutator.Mutation
      iex> Mutation.at_drop(:some_clause).mutated
      :drop
  """
  @spec at_drop(Macro.t()) :: Attribution.t()
  def at_drop(original), do: %Attribution{original: original, mutated: :drop}
end
