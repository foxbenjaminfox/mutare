defmodule Mutare.MacroRouting.Registry.Entry do
  @moduledoc false

  alias Mutare.Macro.Spec

  @type source :: {:builtin | :mutator | :extension, module()} | :config
  @type t :: %__MODULE__{
          spec: Spec.t(),
          router: module() | nil,
          hosts: [module()],
          sources: [source()]
        }

  @enforce_keys [:spec]
  defstruct [:spec, router: nil, hosts: [], sources: []]

  @spec static(Spec.t(), source()) :: t()
  def static(%Spec{} = spec, source), do: %__MODULE__{spec: spec, sources: [source]}

  @spec key(t()) :: {Spec.module_key(), atom(), non_neg_integer() | :any}
  def key(%__MODULE__{spec: spec}), do: Spec.key(spec)
end
