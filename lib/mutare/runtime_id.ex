defmodule Mutare.RuntimeId do
  @moduledoc """
  The identity embedded in a metamutant, separate from its report number.

  Schema builds use `{root_relative_file, local_id}`. The local id reserves every
  candidate, including withheld ones, and starts at one in each file. An unrelated
  file's candidate count can therefore change report numbers without changing this
  file's generated code. Standalone transforms retain their integer identity.

  Sites carry both identities. Coverage translates runtime identities through
  `index/1`; the source file is already available during poison attribution, which uses `file_index/1`.
  Both indexes are built from the current run's sites, never persisted across runs.
  """

  alias Mutare.Site

  @type t :: non_neg_integer() | {String.t(), pos_integer()}

  @doc "The runtime selection for a Site, retaining integer selection for standalone transforms."
  @spec of(Site.t()) :: t()
  def of(%Site{runtime_id: nil, id: id}), do: id
  def of(%Site{runtime_id: id}), do: id

  @doc "Map the current run's runtime identities to report ids for coverage decoding."
  @spec index([Site.t()]) :: %{t() => pos_integer()}
  def index(sites), do: Map.new(sites, &{of(&1), &1.id})

  @doc "The integer a Site's generated code selects on: its local id, or a standalone report id."
  @spec local(Site.t()) :: non_neg_integer()
  def local(%Site{} = site) do
    case of(site) do
      {_namespace, id} -> id
      id -> id
    end
  end

  @doc "Map each file's emitted integers to report ids for lazy poison attribution."
  @spec file_index([Site.t()]) :: %{{String.t(), pos_integer()} => pos_integer()}
  def file_index(sites), do: Map.new(sites, &{{&1.file, local(&1)}, &1.id})
end
