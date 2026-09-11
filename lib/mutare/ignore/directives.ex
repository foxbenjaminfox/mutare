defmodule Mutare.Ignore.Directives do
  @moduledoc false
  # One source file's parsed suppression directives, as `Mutare.Ignore.directives_from_ast/1`
  # returns them. Fields:
  #
  #   * `by_line` — the `:line`-scoped directives, grouped by suppressed line (the shape every
  #     per-site lookup starts from).
  #   * `scoped` — the `:file` and `{:region, first, last}` directives, in document order. Kept
  #     apart from `by_line` because they answer a *coverage* question (`Directive.covers?/2`),
  #     not a key lookup.
  #   * `scope_errors` — region-pairing mistakes, in document order. Parsing never raises (the
  #     scan's diagnostics passes must be able to walk any source); `Mutare.Ignore.validate_scopes!/2`
  #     turns the first error into a hard `Mutare.Ignore.SpecError` once a file name is in hand.
  #   * `unknown` — the comments that claim the reserved `mutare:` namespace without spelling a
  #     recognized directive, as `{comment_line, head}` pairs sorted by line (`head` is the
  #     `mutare:<verb>` text as written, echoed back in the warning): a typo'd verb, a
  #     colon-detached one, or a directive this version doesn't know — surfaced, never inert.
  #   * `end_lines` — for each line directive's suppressed line, the last line of the widest
  #     expression that starts there (`Mutare.Ignore.expression_end_lines/2`), the bound of the
  #     misplacement hint (`Mutare.Ignore.misplacement_hint/3`). A line no expression starts on
  #     has no entry.
  #
  # The last two ride along so the scan's directive diagnostics need no AST of their own: the
  # transform's count pass, which already parsed the file, harvests the whole container and
  # reports it to `Mutare.Schema` (`Mutare.Transform.count_report/2`) — nothing re-parses.

  alias Mutare.Ignore.Directive

  @type scope_error ::
          {:unmatched_end, pos_integer()}
          | {:nested_region, pos_integer(), pos_integer()}
          | {:unterminated_region, pos_integer()}

  @type t :: %__MODULE__{
          by_line: %{pos_integer() => [Directive.t()]},
          scoped: [Directive.t()],
          scope_errors: [scope_error()],
          unknown: [{pos_integer(), String.t()}],
          end_lines: %{pos_integer() => pos_integer()}
        }

  defstruct by_line: %{}, scoped: [], scope_errors: [], unknown: [], end_lines: %{}

  @doc """
  Whether the container holds nothing the scan's diagnostics could report — no directive of
  any scope and no unknown-verb comment. (Scope errors have already raised by the time
  diagnostics run.)
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{by_line: by_line, scoped: scoped, unknown: unknown}),
    do: by_line == %{} and scoped == [] and unknown == []

  @doc """
  Every directive in the container as a flat list in document order (line, then the stamped
  `source_order` for the rare same-line pair) — for the whole-set walks: strict qualifier
  validation, ineffective detection, and `--list-ignores`.
  """
  @spec all(t()) :: [Directive.t()]
  def all(%__MODULE__{by_line: by_line, scoped: scoped}) do
    line_directives = Enum.flat_map(by_line, fn {_line, directives} -> directives end)

    Enum.sort_by(line_directives ++ scoped, &{&1.line, &1.source_order})
  end
end
