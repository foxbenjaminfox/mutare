defmodule Mutare.Transform.Result do
  @moduledoc """
  Public result returned by `Mutare.transform_string/2`.

  The transform still produces richer internal `Mutare.Site` records for the runner and reporters.
  This DTO is intentionally smaller and stable: callers get the rendered metamutant, the public
  mutant descriptions, the next available id, and the metamutant's dispatch variable, without
  depending on internal site fields.

  `dispatch_var` is the variable the metamutant's generated code binds the active mutant id to
  and reads in its selectors and guards — `:mutare_active`, unless the source already uses that
  identifier, in which case a salted variant (`:mutare_active_0`, …) is chosen per file. A reader
  of the metamutant needs it: `Mutare.Manifest.from_source/2` recognises the hoisted selectors and
  gated clauses by this name.
  """

  alias Mutare.MutationSite
  alias Mutare.Site

  @type t :: %__MODULE__{
          metamutant: String.t(),
          mutants: [MutationSite.t()],
          next_id: pos_integer(),
          dispatch_var: atom()
        }

  @enforce_keys [:metamutant, :mutants, :next_id, :dispatch_var]
  defstruct @enforce_keys

  @doc false
  @spec from_sites(String.t(), [Site.t()], pos_integer(), atom()) :: t()
  def from_sites(metamutant, sites, next_id, dispatch_var)
      when is_binary(metamutant) and is_list(sites) and is_atom(dispatch_var) do
    %__MODULE__{
      metamutant: metamutant,
      mutants: Enum.map(sites, &MutationSite.from_site/1),
      next_id: next_id,
      dispatch_var: dispatch_var
    }
  end
end
