defmodule Mutare.Transform.Ctx do
  @moduledoc false

  # Threading context for a single transform pass. Two roles live here, kept
  # visibly apart: read-only config (`file`, `mutators`, `skip_ids`, `prefix`),
  # set once; and accumulators (`next_id`, `group`, `sites`), updated as ids are
  # assigned and sites recorded. A struct (not a bare map) makes the split
  # explicit and a stray field name fail loudly. The whole struct is threaded
  # through every stage — never destructured into loose values — so the shape
  # stays uniform.

  @type t :: %__MODULE__{
          file: String.t(),
          mutators: [module()],
          skip_ids: MapSet.t(),
          prefix: String.t(),
          active_var: atom(),
          next_id: pos_integer(),
          group: non_neg_integer(),
          sites: [Mutare.Site.t()]
        }

  defstruct [
    # config — read-only for the pass
    :file,
    :mutators,
    :skip_ids,
    # The prefix for generated private (lifted) names. `"__mutare_"` is the
    # canonical value; `Mutare.Transform` recomputes it per file — scanning the
    # source's own definitions — to a collision-free variant when the target
    # already defines a `__mutare_`-prefixed name. `Transform` is the authority;
    # this default is just a safe, non-nil fallback.
    prefix: "__mutare_",
    # The variable a dispatcher/selector binds the active mutant id to (and the
    # lifted clauses' extra arg / guards read). `:mutare_active` canonically;
    # `Mutare.Transform` salts it per file (off `prefix`) when the source already
    # uses that identifier, so a generated guard can't capture a user's variable.
    active_var: :mutare_active,
    # accumulators — threaded and updated
    next_id: 1,
    group: 0,
    sites: []
  ]
end
