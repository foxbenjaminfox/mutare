defmodule Mutare.Ignore.SpecError do
  @moduledoc """
  Raised when a `# mutare:ignore` **variant qualifier** can't be honoured — surfaced by
  `mix mutare` as a clean abort with a fix-it message, before any mutant runs.

  Two reasons are about a qualified `[family:label]` directive whose `label`, for a *known* family,
  can't be resolved (a typo; `file`/`line` locate the directive):

    * `:no_variants` — the family declares no variant labels, so it admits only the bare `[family]`
      filter. Drop the `:label`.
    * `:unknown_variant` — the family declares variants, but not this one. The message lists the
      family's known labels and suggests the closest.

  An *unknown family* (qualified or bare) is never this error — a built-in is always known (even one
  disabled this run with `--mutators`), but a custom family not enabled this run can't be told apart
  from a typo, so it stays a soft "ineffective ignore" warning instead.

  The other two are bugs in a *custom mutator's* declaration (no directive involved, so `file`/`line`
  are `nil`):

    * `:wire_unsafe_label` — a declared variant label (`c:Mutare.Mutator.variants/0`) that can't be
      written as a `[family:label]` token: it is empty, or contains whitespace, `,`, `(`, `)`, `]`,
      or `"`. `label` is the offending token.
    * `:unfilterable_family` — the mutator's family name (its `c:Mutare.Mutator.name/0` or `:as`
      rename) can't be written as a `# mutare:ignore[...]` token: it contains a `:` (the qualifier
      separator) or a wire-unsafe character. `family` is the offending name; rename it.
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
