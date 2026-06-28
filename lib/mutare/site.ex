defmodule Mutare.Site do
  @moduledoc """
  One mutant: a single mutation applied at a single source location.

  A "site" in the source (e.g. one `>=` occurrence) may yield several `Site`
  structs — one per mutation the mutators emit there — each with its own `id`.
  The `id` is what the metamutant switches on at runtime (`0` = baseline).

  This is a **lean persisted DTO**: every field is something running or reporting
  needs *after* the transform has finished — id/location, the producing `mutator`
  and its `kind`/`operation`, the **rendered** before/after code, and small
  classification fields (`original_form`/`mutated_form`, `note`, `ignore_reason`,
  `poisoned`, `block_macro`). The original/mutated **AST nodes** are deliberately
  *not* retained: the constructors derive everything from them at build time (the
  `*_form` head tags and the `*_code` rendering), and no consumer reads a tree
  afterwards — the report patches the original source by `range`, not by re-rendering
  a node. Keeping the trees would duplicate the whole rewritten AST per mutant, which
  for a project with thousands of mutants is substantial retained memory for no use.

  ## Deferred diff code

  Rendering `original_code`/`mutated_code` via `Sourceror` *per mutant* dominates the
  build, yet only the handful of mutants a reporter actually shows ever need the diff
  text. So the constructors take a `render?` flag (default `true`): a `mix mutare` scan
  whose reporters show survivors alone passes `false`, leaving both fields `nil`, and the
  report re-derives them only for the sites it displays (`Mutare.Transform.render_sites/2`
  via `Mutare.Runner.Hydrate`). The flag gates *only* those two fields — `range`, the
  `*_form` tags, and `variant` (read for `# mutare:ignore` filtering) are always computed,
  so deferral changes no id, classification, or count. The public `transform_string/2` and
  the test helpers keep the default, so they always carry rendered code.

  ## Live summary

  The deferred path leaves `*_code` `nil`, but the live progress reporter still wants a
  one-line `orig -> mutated` for the *in-flight* mutant — and it can't defer, because it
  shows every mutant as it runs, not just the displayed handful. So a second, independent
  flag `summary?` builds `summary`: the same `describe/1`-style one-liner, but rendered with
  `Macro.to_string/1` (~8x cheaper than `Sourceror`, ample for an ephemeral spinner line)
  instead of the high-fidelity `Sourceror` the `*_code` fields and the reports use. A
  `mix mutare` run sets `summary?` for every site unless `--quiet` (no live block, so nothing
  reads it); `transform_string/2`, the count pass, and the test helpers leave it `nil`. Only
  the live activity line reads it (`summary_line/1`); every report uses `*_code`.
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
          original_form: atom() | nil,
          mutated_form: atom() | nil,
          original_code: String.t(),
          mutated_code: String.t(),
          summary: String.t() | nil,
          variant: [String.t()],
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
    :original_form,
    :mutated_form,
    :original_code,
    :mutated_code,
    # The cheap `Macro.to_string`-rendered `mutator  orig → mutated` one-liner for the live
    # in-flight activity line, or `nil` when not requested (the `summary?` flag — see the "Live
    # summary" section). Read only by `summary_line/1`; the reports use `*_code`.
    :summary,
    # The mutator-declared **variant label(s)** of this mutation (downcased), or `[]` when the
    # producing mutator did not opt in (no `c:Mutare.Mutator.variants/0` vocabulary) or this
    # mutation has no label (a delete site, or an unlabeled mutant). A list because one mutant may
    # belong to several kinds (`Mutare.Mutators.Literal`'s deduped `1 - 1`/`0` is both `pred` and
    # `zero`), and a qualified `# mutare:ignore[family:label]` filter matches if *any* of these
    # labels equals its token — declared by the mutator, *not* derived from the rendered AST (so
    # `relational:>` names the `>` swap, `return_value:empty` the empty constant). Set by
    # `Mutare.Mutator.Dispatch.variant/4` — the label the producing mutator tagged on its
    # `%Mutare.Mutator.Mutation{}`, else derived via `c:Mutare.Mutator.variant/2`.
    variant: [],
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

  `opts` carries the optional metadata (all absent for an ordinary mutation):

    * `:note` — a report advisory (a hosting mutator's, e.g. "kill may require NULL/boundary
      data").
    * `:variant` — the `# mutare:ignore` label(s) the producing mutator tagged at production time
      (`Mutare.Mutator.Mutation.tagged/2`); absent lets `replace/8` derive it via
      `c:Mutare.Mutator.variant/2`.
    * `:render?` — `false` defers the per-site diff render (the scan's optimisation — see the
      "Deferred diff code" section); defaults `true`.
    * `:summary?` — `true` builds the cheap `Macro`-rendered live one-liner (`summary`); defaults
      `false` (see the "Live summary" section).
  """
  @spec in_place(
          pos_integer(),
          String.t(),
          Sourceror.Range.t(),
          Macro.t(),
          Macro.t(),
          Mutare.Mutator.Spec.t(),
          keyword()
        ) :: t()
  def in_place(id, file, range, original_node, mutated_node, mutator, opts \\ []) do
    %{
      replace(id, file, range, original_node, mutated_node, mutator, :in_place, opts)
      | note: opts[:note]
    }
  end

  @doc """
  A mutation delivered by lifting (a single id-gated clause in the lifted private
  function behind a dispatcher) rather than by an in-place selector `case` — because
  the mutated node sits where a `case` is illegal: inside a `when` guard, or inside a
  clause *head* pattern (a literal swap). Same replacement shape as `in_place/6`,
  recorded as `:lifted`; `mutator` (a `Mutare.Mutator.Spec`) distinguishes a guard
  operator swap (`:relational`, …) from a head-pattern literal swap (`:literal`, …).
  `opts` carries the same optional metadata as `in_place/7` (`:note`, `:variant`, `:render?`).
  """
  @spec lifted_replace(
          pos_integer(),
          String.t(),
          Sourceror.Range.t(),
          Macro.t(),
          Macro.t(),
          Mutare.Mutator.Spec.t(),
          keyword()
        ) :: t()
  def lifted_replace(id, file, range, original_node, mutated_node, mutator, opts \\ []) do
    %{
      replace(id, file, range, original_node, mutated_node, mutator, :lifted, opts)
      | note: opts[:note]
    }
  end

  # The id/file/location fields every constructor sets identically from the mutant id, source file,
  # and Sourceror range. Extracted so a change to how a location is read (the `range` shape, a new
  # location field) touches one place, not every constructor; each constructor fills the rest with
  # the struct-update syntax.
  defp base_site(id, file, range) do
    %__MODULE__{
      id: id,
      file: file,
      line: range.start[:line],
      column: range.start[:column],
      range: range
    }
  end

  @doc """
  A dropped function clause — a `:lifted`, `:delete` mutation. The clause is
  removed entirely, so there is no mutated node, op, or code.

  `opts` carries the two render flags (`:render?`/`:summary?`, both `true` by default — see
  "Deferred diff code" and "Live summary").
  """
  @spec clause_drop(pos_integer(), String.t(), Sourceror.Range.t(), Macro.t(), keyword()) :: t()
  def clause_drop(id, file, range, clause_node, opts \\ []) do
    delete_site(id, file, range, clause_node, :clause_drop, :lifted, opts)
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
          Mutare.Mutator.Spec.t(),
          keyword()
        ) :: t()
  def in_place_drop(id, file, range, clause_node, mutator, opts \\ []) do
    delete_site(id, file, range, clause_node, mutator.name, :in_place, opts)
  end

  # The shared body of the two delete-site constructors (`clause_drop/4`, `in_place_drop/5`):
  # a `:delete` mutation removes the whole clause, so there is no mutated node, op, or code — the
  # constructors differ only in `mutator` and `kind`. One home so a change to how a delete site is
  # built (a new field, the `clause_code/1` rendering) lands once. `opts` carries the two render
  # flags (`:render?` for the `Sourceror` `original_code`, `:summary?` for the `Macro` summary).
  defp delete_site(id, file, range, clause_node, mutator_name, kind, opts) do
    %{
      base_site(id, file, range)
      | mutator: mutator_name,
        kind: kind,
        operation: :delete,
        original_form: nil,
        mutated_form: nil,
        original_code: clause_code(clause_node, Keyword.get(opts, :render?, true)),
        mutated_code: "",
        summary: delete_summary(mutator_name, clause_node, Keyword.get(opts, :summary?, false))
    }
  end

  # The `original_code` renderer shared by both delete-site constructors
  # (`clause_drop/4`, `in_place_drop/5`). A `rescue` clause is a bare `->` node, which
  # `Sourceror.to_string/1` renders in call form (`->(head, body)`); render it in arrow
  # syntax (`head -> body`) for the one-line `describe/1`/report summary. (The `-`/`+`
  # diff reads source lines by range, so it is unaffected.) Rescue clauses carry one
  # pattern and no `when` guard; anything else — a dropped `def`/`defp` function clause
  # included — falls back to the default rendering.
  # Lazy mode (`render?` false) records no diff text — the scan defers it, and the report
  # re-derives it for the few sites it actually shows (see `Mutare.Runner.Hydrate`).
  defp clause_code(_node, false), do: nil

  defp clause_code({:->, _meta, [[head], body]}, true),
    do: "#{Sourceror.to_string(head)} -> #{Sourceror.to_string(body)}"

  defp clause_code(node, true), do: Sourceror.to_string(node)

  # The live-summary builders (`summary?` true) — the cheap `Macro`-rendered counterparts of
  # `describe/1`, gated to `nil` when not requested. A replacement shows `mutator  orig → mutated`;
  # a delete shows `mutator  (drop) <clause>`. See the "Live summary" section.
  defp replace_summary(_mutator, _orig, _mutated, false), do: nil

  defp replace_summary(mutator, orig, mutated, true),
    do: "#{mutator}  #{one_line(macro(orig))} → #{one_line(macro(mutated))}"

  defp delete_summary(_mutator, _clause, false), do: nil

  defp delete_summary(mutator, clause, true),
    do: "#{mutator}  (drop) #{one_line(macro(clause))}"

  # Render a node to source via `Macro.to_string/1` for the live summary — far cheaper than
  # `Sourceror.to_string/1` and fine for an ephemeral one-liner (it normalises formatting, which
  # the report/JSON/SARIF can't tolerate but a spinner line can). A bare `->` clause (a dropped
  # `rescue`) renders in call form (`->(head, body)`); show it in arrow syntax, mirroring
  # `clause_code/2`'s handling of the same shape.
  defp macro({:->, _meta, [[head], body]}),
    do: "#{Macro.to_string(head)} -> #{Macro.to_string(body)}"

  defp macro(node), do: Macro.to_string(node)

  @doc """
  A return-value mutation: a function clause's tail expression replaced with a
  constant (`nil`/`0`/`""`/`[]`) behind an in-place selector `case`. Structural
  (the transform names the tail; there is no node-level mutator), so there are no
  operator atoms — but it *is* `:in_place` (a tail is a body position), with the
  original tail and the replacement constant kept for the diff. `mutator` is the
  producing `Mutare.Mutator.Spec` (`ReturnValue` or a custom return mutator), and the
  site records its `name`. `opts` carries the two render flags (`:render?`/`:summary?`).
  """
  @spec return_value(
          pos_integer(),
          String.t(),
          Sourceror.Range.t(),
          Macro.t(),
          Macro.t(),
          Mutare.Mutator.Spec.t(),
          keyword()
        ) :: t()
  def return_value(id, file, range, original_node, mutated_node, mutator, opts \\ []) do
    render? = Keyword.get(opts, :render?, true)
    summary? = Keyword.get(opts, :summary?, false)

    %{
      base_site(id, file, range)
      | mutator: mutator.name,
        kind: :in_place,
        operation: :replace,
        original_form: nil,
        mutated_form: nil,
        original_code: maybe_render(original_node, render?),
        mutated_code: maybe_render(mutated_node, render?),
        summary: replace_summary(mutator.name, original_node, mutated_node, summary?),
        variant: Mutare.Mutator.Dispatch.variant(mutator, original_node, mutated_node)
    }
  end

  # Render a node to source, or `nil` in lazy mode (`render?` false). The single gate the
  # node-rendering constructors share so deferral is one decision, not three.
  defp maybe_render(_node, false), do: nil
  defp maybe_render(node, true), do: Sourceror.to_string(node)

  # In-place and lifted sites differ only in `kind`: both are a node replacement
  # recorded with the original/mutated nodes, their AST *forms* (the node's head tag —
  # `:+`/`:==` for an operator swap, `:__block__` for a literal), and rendered code.
  defp replace(id, file, range, original_node, mutated_node, mutator, kind, opts) do
    variant = opts[:variant]
    render? = Keyword.get(opts, :render?, true)
    summary? = Keyword.get(opts, :summary?, false)

    # When the mutated node is a *keyword-list key* (`trim:`), its recorded `range`
    # spans the `name:` source — colon included — so the report's textual patch must
    # render it in keyword form too. `Sourceror.to_string/1` of the bare atom node
    # gives `:trim`, which spliced over that span yields invalid `:mutare true`; the
    # decision is read from the *original* node, since a mutated atom carries fresh,
    # format-less meta. (`true`/`false`/`nil` keys included — they are atoms too.)
    keyword_key? = keyword_key?(original_node)

    %{
      base_site(id, file, range)
      | mutator: mutator.name,
        kind: kind,
        original_form: elem(original_node, 0),
        mutated_form: elem(mutated_node, 0),
        original_code: render_code(original_node, keyword_key?, render?),
        mutated_code: render_code(mutated_node, keyword_key?, render?),
        summary: replace_summary(mutator.name, original_node, mutated_node, summary?),
        variant: Mutare.Mutator.Dispatch.variant(mutator, original_node, mutated_node, variant)
    }
  end

  defp keyword_key?({:__block__, meta, [atom]}) when is_atom(atom), do: meta[:format] == :keyword
  defp keyword_key?(_node), do: false

  defp render_code(_node, _keyword_key?, false), do: nil

  defp render_code({:__block__, _meta, [atom]}, true, true) when is_atom(atom),
    do: Macro.inspect_atom(:key, atom)

  defp render_code(node, _keyword_key?, true), do: Sourceror.to_string(node)

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

  @doc """
  The one-liner for the **live in-flight** activity line: the cheap `Macro`-rendered `summary`
  when present (a `mix mutare` run builds it for every site unless `--quiet`), else the
  `Sourceror`-based `describe/1` (the eager / hydrated path). Decoupled from `describe/1` so a
  deferred scan's un-hydrated site — `*_code` `nil` — never has to render to show progress.
  """
  @spec summary_line(t()) :: String.t()
  def summary_line(%__MODULE__{summary: nil} = site), do: describe(site)
  def summary_line(%__MODULE__{summary: summary}), do: summary

  # Sourceror renders a multi-line node (a dropped `case` clause, a wrapped tuple,
  # a multi-line return) as multi-line code. `describe/1` promises a *one*-liner —
  # and its consumers depend on it: the live status block counts list elements, not
  # physical rows, so an embedded newline in the in-flight activity line would
  # under-erase and leave stale rows on screen; a SARIF message wants one line too.
  # Collapse each newline (plus the indentation around it) to a single space; spaces
  # *within* a line (e.g. inside a string literal) are left intact. The raw
  # `original_code`/`mutated_code` fields stay multi-line for the diff/JSON reports.
  # `nil` (a deferred, un-hydrated site reached via `describe/1`) collapses to "" rather
  # than raising — the summary path is what such a site should use, but `describe/1` stays
  # total so a stray call can never crash the reporter that owns the terminal.
  defp one_line(nil), do: ""

  defp one_line(code) do
    code |> String.replace(~r/\s*\n\s*/, " ") |> String.trim()
  end
end
