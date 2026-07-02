defmodule Mutare.Transform.Result do
  @moduledoc """
  Public result returned by `Mutare.transform_string/2`.

  The transform still produces richer internal `Mutare.Site` records for the runner and reporters.
  This DTO is intentionally smaller and stable: callers get the rendered metamutant, the public
  mutant descriptions, and the next available id without depending on internal site fields.
  """

  alias Mutare.MutationSite
  alias Mutare.Site

  @type t :: %__MODULE__{
          metamutant: String.t(),
          mutants: [MutationSite.t()],
          next_id: pos_integer()
        }

  @enforce_keys [:metamutant, :mutants, :next_id]
  defstruct @enforce_keys

  @doc false
  @spec from_sites(String.t(), [Site.t()], pos_integer()) :: t()
  def from_sites(metamutant, sites, next_id) when is_binary(metamutant) and is_list(sites) do
    %__MODULE__{
      metamutant: metamutant,
      mutants: Enum.map(sites, &MutationSite.from_site/1),
      next_id: next_id
    }
  end
end
