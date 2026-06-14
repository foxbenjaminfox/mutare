defmodule Mutare.Result do
  @moduledoc "The outcome of running the suite against one mutant."

  alias Mutare.Site

  @type status :: :killed | :survived | :no_coverage | :timeout | :error

  @type t :: %__MODULE__{
          site: Site.t(),
          status: status(),
          duration_ms: non_neg_integer() | nil,
          output: String.t() | nil
        }

  defstruct [:site, :status, :duration_ms, :output]
end
