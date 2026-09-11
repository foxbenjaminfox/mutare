defmodule Mutare.Transform.CountReport do
  @moduledoc false

  # What the render-free count pass (`Mutare.Transform.count_report/2`) reports for one source —
  # every fact `Mutare.Schema` reads off a file, collected by the one pass that parsed and
  # annotated it, so nothing after the scan re-parses a source (NOTES "The count pass is the
  # scan's only parse": a new scan-time diagnostic adds a field here):
  #
  #   * `mutants` — the number of ids the render would claim (`next_id - start_id`, drift-proof
  #     by construction — same claim path, no `Mutare.Site` built).
  #   * `selected_ids` — under a `:selection_lines` filter, the *local* ids whose site would land
  #     on a selected line (in claim order), else `nil`.
  #   * `matches` — the configured entries this source reached (`Mutare.Transform.ConfigMatches`),
  #     for the ineffective-configuration diagnostic.
  #   * `directives` — the file's `Mutare.Ignore.Directives` container (the directives, the
  #     unknown `mutare:` verbs, and the misplacement hint's expression end lines), for the
  #     ineffective-directive and unknown-verb diagnostics.
  #   * `degraded_uses` — the module-level `use`s the resolve pre-pass could not expand
  #     (`Mutare.Transform.Uses.degraded_uses/1`), for `mix mutare --check`.
  #
  # `Mutare.Schema` consumes one per file in its two-phase build.

  alias Mutare.Ignore.Directives
  alias Mutare.Transform.{ConfigMatches, Uses}

  @type t :: %__MODULE__{
          mutants: non_neg_integer(),
          selected_ids: [pos_integer()] | nil,
          matches: ConfigMatches.t(),
          directives: Directives.t(),
          degraded_uses: [Uses.degraded_use()]
        }

  @enforce_keys [:mutants, :selected_ids, :matches, :directives, :degraded_uses]
  defstruct [:mutants, :selected_ids, :matches, :directives, :degraded_uses]
end
