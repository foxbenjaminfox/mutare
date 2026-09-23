defmodule Mutare.CallRouting.Registry.Entry do
  @moduledoc false

  alias Mutare.CallRouting.Spec

  # An entry is what a call is *routed* by. What a configured `:skip`'s arguments *mean* is not
  # the entry's to say — the skip withholds mutation and nested routing, not meaning — but the
  # registry's, from the declaration the skip displaced or shadowed
  # (`Mutare.CallRouting.Registry.meaning/4`).
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
