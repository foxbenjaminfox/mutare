defmodule Mutare.Site do
  @moduledoc """
  One mutant: a single mutation applied at a single source location.

  A "site" in the source (e.g. one `>=` occurrence) may yield several `Site`
  structs — one per mutation the mutators emit there — each with its own `id`.
  The `id` is what the metamutant switches on at runtime (`0` = baseline).
  """

  @type t :: %__MODULE__{
          id: pos_integer(),
          file: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          range: Sourceror.Range.t() | nil,
          mutator: atom(),
          kind: :in_place | :lifted,
          operation: :replace | :delete,
          ignored: boolean(),
          ignore_reason: String.t() | nil,
          poisoned: boolean(),
          original_op: atom() | nil,
          mutated_op: atom() | nil,
          original_code: String.t(),
          mutated_code: String.t(),
          original_node: Macro.t(),
          mutated_node: Macro.t() | nil,
          note: String.t() | nil,
          block_macro: {atom(), non_neg_integer()} | nil
        }

  defstruct [
    :id,
    :file,
    :line,
    :column,
    :range,
    :mutator,
    :kind,
    :original_op,
    :mutated_op,
    :original_code,
    :mutated_code,
    :original_node,
    :mutated_node,
    operation: :replace,
    ignored: false,
    ignore_reason: nil,
    poisoned: false,
    # An optional advisory note recorded with the mutation and surfaced in the report
    # (e.g. a hosting mutator flagging "kill may require NULL/boundary data"). Distinct from
    # `ignore_reason` (which suppresses the mutant): a noted mutant is live and scored, the note
    # is just extra signal for a survivor. Set via `in_place/7`; `nil` for an ordinary mutation.
    note: nil,
    # The `{name, nid}` identity of the *unknown* module-level block macro
    # invocation whose `do` body this mutation lives in, or `nil`. The transform
    # mutates such a body on the guess that the DSL unquotes it into a function, but
    # the injected selector `case` may be illegal in the DSL and poison the single
    # build. The tag lets poison recovery skip the *whole* block at once
    # (`Mutare.Runner`) — the runtime-stable equivalent of marking it `:skip` —
    # instead of dropping one mutant at a time and re-hitting the next selector. The
    # `nid` (the block-macro statement node's stable DFS identity) makes it
    # **per-invocation**: a poison in `guarded :guard do …` must not suppress a
    # sibling `guarded :body do …` of the same macro that expands differently. A
    # *registered* macro is left untagged: the user's `:macros` routing is honoured,
    # never auto-skipped.
    block_macro: nil
  ]

  # === construction ==========================================================
  #
  # Named constructors own the struct's shape — how each field is derived from
  # the mutation (op extraction, code rendering, location). `Mutare.Transform`
  # decides *which* one to call from a node's position; it never stuffs fields.

  @doc """
  An in-place mutation: an operator swapped behind a selector `case` in a
  function body. `range` locates the original node; `mutator` is the
  `Mutare.Mutator.Spec` that produced `mutated_node` (its `name` is recorded).
  An optional `note` is recorded on the site for the report (a hosting mutator's
  advisory, e.g. "kill may require NULL/boundary data") — `nil` for an ordinary mutation.
  """
  @spec in_place(
          pos_integer(),
          String.t(),
          Sourceror.Range.t(),
          Macro.t(),
          Macro.t(),
          Mutare.Mutator.Spec.t(),
          String.t() | nil
        ) :: t()
  def in_place(id, file, range, original_node, mutated_node, mutator, note \\ nil) do
    %{replace(id, file, range, original_node, mutated_node, mutator, :in_place) | note: note}
  end

  @doc """
  A mutation delivered by lifting (a single id-gated clause in the lifted private
  function behind a dispatcher) rather than by an in-place selector `case` — because
  the mutated node sits where a `case` is illegal: inside a `when` guard, or inside a
  clause *head* pattern (a literal swap). Same replacement shape as `in_place/6`,
  recorded as `:lifted`; `mutator` (a `Mutare.Mutator.Spec`) distinguishes a guard
  operator swap (`:relational`, …) from a head-pattern literal swap (`:literal`, …).
  """
  @spec lifted_replace(
          pos_integer(),
          String.t(),
          Sourceror.Range.t(),
          Macro.t(),
          Macro.t(),
          Mutare.Mutator.Spec.t()
        ) :: t()
  def lifted_replace(id, file, range, original_node, mutated_node, mutator) do
    replace(id, file, range, original_node, mutated_node, mutator, :lifted)
  end

  @doc """
  A dropped function clause — a `:lifted`, `:delete` mutation. The clause is
  removed entirely, so there is no mutated node, op, or code.
  """
  @spec clause_drop(pos_integer(), String.t(), Sourceror.Range.t(), Macro.t()) :: t()
  def clause_drop(id, file, range, clause_node) do
    %__MODULE__{
      id: id,
      file: file,
      line: range.start[:line],
      column: range.start[:column],
      range: range,
      mutator: :clause_drop,
      kind: :lifted,
      operation: :delete,
      original_op: nil,
      mutated_op: nil,
      original_code: clause_code(clause_node),
      mutated_code: "",
      original_node: clause_node,
      mutated_node: nil
    }
  end

  @doc """
  A `rescue` clause dropped from an explicit `try` — a `:delete` mutation delivered
  **in place** by the whole-`try` selector (not by lifting, so `:in_place`, unlike
  `clause_drop/4`). The clause is removed entirely, so there is no mutated node, op,
  or code; `mutator` is the family spec (`RescueType`) whose name the report and the
  `# mutare:ignore[...]` filter read.
  """
  @spec in_place_drop(
          pos_integer(),
          String.t(),
          Sourceror.Range.t(),
          Macro.t(),
          Mutare.Mutator.Spec.t()
        ) :: t()
  def in_place_drop(id, file, range, clause_node, mutator) do
    %__MODULE__{
      id: id,
      file: file,
      line: range.start[:line],
      column: range.start[:column],
      range: range,
      mutator: mutator.name,
      kind: :in_place,
      operation: :delete,
      original_op: nil,
      mutated_op: nil,
      original_code: clause_code(clause_node),
      mutated_code: "",
      original_node: clause_node,
      mutated_node: nil
    }
  end

  # The `original_code` renderer shared by both delete-site constructors
  # (`clause_drop/4`, `in_place_drop/5`). A `rescue` clause is a bare `->` node, which
  # `Sourceror.to_string/1` renders in call form (`->(head, body)`); render it in arrow
  # syntax (`head -> body`) for the one-line `describe/1`/report summary. (The `-`/`+`
  # diff reads source lines by range, so it is unaffected.) Rescue clauses carry one
  # pattern and no `when` guard; anything else — a dropped `def`/`defp` function clause
  # included — falls back to the default rendering.
  defp clause_code({:->, _meta, [[head], body]}),
    do: "#{Sourceror.to_string(head)} -> #{Sourceror.to_string(body)}"

  defp clause_code(node), do: Sourceror.to_string(node)

  @doc """
  A return-value mutation: a function clause's tail expression replaced with a
  constant (`nil`/`0`/`""`/`[]`) behind an in-place selector `case`. Structural
  (the transform names the tail; there is no node-level mutator), so there are no
  operator atoms — but it *is* `:in_place` (a tail is a body position), with the
  original tail and the replacement constant kept for the diff. `mutator` is the
  producing `Mutare.Mutator.Spec` (`ReturnValue` or a custom return mutator), and the
  site records its `name`.
  """
  @spec return_value(
          pos_integer(),
          String.t(),
          Sourceror.Range.t(),
          Macro.t(),
          Macro.t(),
          Mutare.Mutator.Spec.t()
        ) :: t()
  def return_value(id, file, range, original_node, mutated_node, mutator) do
    %__MODULE__{
      id: id,
      file: file,
      line: range.start[:line],
      column: range.start[:column],
      range: range,
      mutator: mutator.name,
      kind: :in_place,
      operation: :replace,
      original_op: nil,
      mutated_op: nil,
      original_code: Sourceror.to_string(original_node),
      mutated_code: Sourceror.to_string(mutated_node),
      original_node: original_node,
      mutated_node: mutated_node
    }
  end

  # In-place and lifted sites differ only in `kind`: both are a node replacement
  # recorded with the original/mutated nodes, their ops, and rendered code. (For a
  # literal swap the "op" is `:__block__` — the same as an in-place literal site.)
  defp replace(id, file, range, original_node, mutated_node, mutator, kind) do
    # When the mutated node is a *keyword-list key* (`trim:`), its recorded `range`
    # spans the `name:` source — colon included — so the report's textual patch must
    # render it in keyword form too. `Sourceror.to_string/1` of the bare atom node
    # gives `:trim`, which spliced over that span yields invalid `:mutare true`; the
    # decision is read from the *original* node, since a mutated atom carries fresh,
    # format-less meta. (`true`/`false`/`nil` keys included — they are atoms too.)
    keyword_key? = keyword_key?(original_node)

    %__MODULE__{
      id: id,
      file: file,
      line: range.start[:line],
      column: range.start[:column],
      range: range,
      mutator: mutator.name,
      kind: kind,
      original_op: elem(original_node, 0),
      mutated_op: elem(mutated_node, 0),
      original_code: render_code(original_node, keyword_key?),
      mutated_code: render_code(mutated_node, keyword_key?),
      original_node: original_node,
      mutated_node: mutated_node
    }
  end

  defp keyword_key?({:__block__, meta, [atom]}) when is_atom(atom), do: meta[:format] == :keyword
  defp keyword_key?(_node), do: false

  defp render_code({:__block__, _meta, [atom]}, true) when is_atom(atom),
    do: Macro.inspect_atom(:key, atom)

  defp render_code(node, _keyword_key?), do: Sourceror.to_string(node)

  @doc """
  Human-readable one-liner, e.g. `relational  >= → >` or
  `clause_drop  (drop) <clause>`.

      iex> Mutare.Site.describe(%Mutare.Site{
      ...>   mutator: :relational,
      ...>   operation: :replace,
      ...>   original_code: "a >= b",
      ...>   mutated_code: "a > b"
      ...> })
      "relational  a >= b → a > b"

      iex> Mutare.Site.describe(%Mutare.Site{
      ...>   mutator: :clause_drop,
      ...>   operation: :delete,
      ...>   original_code: "def f(_), do: :ok"
      ...> })
      "clause_drop  (drop) def f(_), do: :ok"
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{operation: :delete} = site) do
    "#{site.mutator}  (drop) #{one_line(site.original_code)}"
  end

  def describe(%__MODULE__{} = site) do
    "#{site.mutator}  #{one_line(site.original_code)} → #{one_line(site.mutated_code)}"
  end

  # Sourceror renders a multi-line node (a dropped `case` clause, a wrapped tuple,
  # a multi-line return) as multi-line code. `describe/1` promises a *one*-liner —
  # and its consumers depend on it: the live status block counts list elements, not
  # physical rows, so an embedded newline in the in-flight activity line would
  # under-erase and leave stale rows on screen; a SARIF message wants one line too.
  # Collapse each newline (plus the indentation around it) to a single space; spaces
  # *within* a line (e.g. inside a string literal) are left intact. The raw
  # `original_code`/`mutated_code` fields stay multi-line for the diff/JSON reports.
  defp one_line(code) do
    code |> String.replace(~r/\s*\n\s*/, " ") |> String.trim()
  end
end
