defmodule Mutare.Transform.Resolve.Environment do
  @moduledoc false
  # A retained environment grants analysis permission to re-enter the resolver.
  # Inputs are the complete semantic identity of that scope; everything outside
  # Inputs is wiring for a particular walk. Reuse compares inputs directly, so
  # adding a semantic input cannot silently exclude it from the comparison.
  #
  # Diagnostics and on_resolve survive retention: a host's Elixir island must
  # report through the originating scan. The reuse set does not survive: it
  # describes one replacement walk, and retaining it would retain its ASTs too.

  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.Imports
  alias Mutare.Transform.Resolve.ArgumentMarks

  defmodule Inputs do
    @moduledoc false
    @enforce_keys [:call_routes, :marks]
    defstruct [
      :call_routes,
      :marks,
      aliases: %{},
      imports: %{},
      kernel: Imports.default_selector(),
      module: nil
    ]

    @type t :: %__MODULE__{
            aliases: map(),
            imports: map(),
            kernel: Imports.selector(),
            module: atom() | [atom()],
            call_routes: Registry.registry(),
            marks: ArgumentMarks.t()
          }
  end

  @enforce_keys [:inputs, :diag, :on_resolve]
  defstruct [:inputs, :diag, :on_resolve, unchanged: nil]

  @type t :: %__MODULE__{
          inputs: Inputs.t(),
          diag: %{warn?: boolean(), file: String.t()},
          on_resolve: (Macro.t() -> term()),
          unchanged: MapSet.t(Macro.t()) | nil
        }

  @spec new(Registry.registry(), keyword()) :: t()
  def new(registry, opts) do
    %__MODULE__{
      inputs: %Inputs{
        call_routes: registry,
        marks: Keyword.get(opts, :marks, ArgumentMarks.empty())
      },
      on_resolve: Keyword.get(opts, :on_resolve, fn _ast -> :ok end),
      diag: %{warn?: Keyword.get(opts, :warnings, true), file: Keyword.get(opts, :file, "nofile")}
    }
  end

  @spec for_replacement(t(), MapSet.t(Macro.t())) :: t()
  def for_replacement(env, calls),
    do: %{env | diag: %{env.diag | warn?: false}, unchanged: calls}

  @spec retain(t()) :: t()
  def retain(%__MODULE__{unchanged: nil} = env), do: env
  def retain(%__MODULE__{} = env), do: %{env | unchanged: nil}
end
