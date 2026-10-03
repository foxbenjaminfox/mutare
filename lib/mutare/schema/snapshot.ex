defmodule Mutare.Schema.Snapshot do
  @moduledoc false

  # Ordered source records and the build inputs that gave their IDs meaning. The
  # context retains configuration and rendering choices only, never progress hooks
  # or the project (whose discovery has already fixed the file list).
  alias Mutare.Run.Context
  alias Mutare.Schema.Source

  @enforce_keys [:files, :context]
  defstruct @enforce_keys

  @type t :: %__MODULE__{files: [Source.t()], context: Context.t()}

  @spec new([Source.t()], Context.t()) :: t()
  def new(files, %Context{} = context) do
    %__MODULE__{
      files: files,
      context: %Context{
        options: context.options,
        defer_site_code: context.defer_site_code,
        summarize_sites: context.summarize_sites
      }
    }
  end
end
