defmodule Mutare.Schema.Source do
  @moduledoc false

  # One captured file, including an unparseable or zero-site file. Count facts survive
  # the worker that produced them; its AST does not. Recovery reuses these facts and
  # bytes, replacing only `rendered`. The source, ID origin and dispatch variable
  # consequently travel together to hydration and poison attribution.
  alias Mutare.Transform.CountReport

  defmodule Rendered do
    @moduledoc false
    @enforce_keys [:start_id, :metamutant, :dispatch_var]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            start_id: pos_integer(),
            metamutant: String.t(),
            dispatch_var: atom()
          }
  end

  @enforce_keys [:rel, :source, :outcome]
  defstruct @enforce_keys ++ [rendered: nil]

  @type t :: %__MODULE__{
          rel: String.t(),
          source: String.t(),
          outcome: {:ok, CountReport.t()} | {:error, Exception.t()},
          rendered: Rendered.t() | nil
        }
end
