defmodule Mutare.Ignore.SpecError do
  @moduledoc """
  Something in the `# mutare:ignore` **variant-label** system is unusable — raised fail-loud and
  rendered by the Mix task as a clean abort (the library API lets it crash).

  Two of the reasons are about a **qualified** `[family:label]` filter naming a label that, for a
  *known* family, can't be resolved — raised by `Mutare.Ignore.validate!/3` against the declared
  variant vocabulary (`Mutare.Mutators.vocabulary/1`), caught *statically* (no per-line site
  needed); `file`/`line` locate the directive:

    * `:no_variants` — the family is real but declares no variant vocabulary
      (`c:Mutare.Mutator.variants/0`), so it admits only the bare `[family]` filter;
    * `:unknown_variant` — the family declares variants, but not this label.

  An **unknown family** (one not in the vocabulary) is deliberately *not* an error, qualified or
  bare: it is indistinguishable from a `--mutators`-excluded or removed custom family, so it stays
  a soft `Mutare.Ignore.ineffective/2` warning. The hard error is reserved for the case where the
  family is present and the label is therefore *certainly* wrong, with a "did you mean" suggestion.

  The last two reasons are **mutator-authoring / config** bugs, raised by `Mutare.Mutators.vocabulary/1`
  when it harvests the active mutator set (no directive involved, so `file`/`line` are `nil`):

    * `:wire_unsafe_label` — a `c:Mutare.Mutator.variants/0` label that can't be written as a
      `[family:label]` qualifier selecting it: it is empty, or contains a character a filter token
      can't carry (whitespace, `,`, `(`, `)`, `]`, `"`). Surfaced loudly rather than silently
      producing an unmatchable label; `label` is the offending token (`family` is `nil`).
    * `:unfilterable_family` — a mutator's recorded family name (`c:Mutare.Mutator.name/0` or an
      `:as` rename) can't be written as a `# mutare:ignore[...]` token: it contains a `:` (read as
      the variant-qualifier separator, so `[ecto:query]` could never name a whole `ecto:query`
      family) or a wire-unsafe character. `family` is the offending name (`label` is `nil`).
  """

  defexception [:message, :reason, :file, :line, :family, :label]

  @type reason :: :no_variants | :unknown_variant | :wire_unsafe_label | :unfilterable_family

  @type t :: %__MODULE__{
          message: String.t(),
          reason: reason(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          family: String.t() | nil,
          label: String.t() | nil
        }
end
