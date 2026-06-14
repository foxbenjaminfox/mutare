defmodule Mutare.Transform.Ctx do
  @moduledoc false

  # Threading context for a single transform pass. Two roles live here, kept
  # visibly apart: read-only config (`file`, `mutators`, `skip_ids`), set once;
  # and accumulators (`next_id`, `group`, `sites`), updated as ids are assigned
  # and sites recorded. A struct (not a bare map) makes the split explicit and a
  # stray field name fail loudly. The whole struct is threaded through every
  # stage — never destructured into loose values — so the shape stays uniform.

  @type t :: %__MODULE__{
          file: String.t(),
          mutators: [module()],
          skip_ids: MapSet.t(),
          next_id: pos_integer(),
          group: non_neg_integer(),
          sites: [Mutare.Site.t()]
        }

  defstruct [
    # config — read-only for the pass
    :file,
    :mutators,
    :skip_ids,
    # accumulators — threaded and updated
    next_id: 1,
    group: 0,
    sites: []
  ]
end
