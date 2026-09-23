defmodule Mutare.CallRouting.Registry.Entry do
  @moduledoc false

  alias Mutare.CallRouting.Spec

  # `displaced` is set on a configured call-level `:skip` only: the code declarations (built-in,
  # mutator, extension) the skip replaced at this key, coalesced by treatment. A skip withholds
  # mutation and nested routing, not what the arguments *mean* — a declared `:binding_pattern`
  # still binds, a declared `:pattern` still binds nothing — so the binding readers read a
  # skipped call by the declaration it displaced (`Mutare.Transform.Resolve.RouteStamp` stamps
  # it; `Mutare.Transform.Resolve.effective_routing/2` reads it). Empty where nothing was
  # displaced (an ordinary call); more than one where the displaced providers disagreed, which
  # the override settled for routing but leaves the arguments' meaning unknown.
  @type source :: {:builtin | :mutator | :extension, module()} | :config
  @type t :: %__MODULE__{
          spec: Spec.t(),
          router: module() | nil,
          hosts: [module()],
          sources: [source()],
          displaced: [Spec.t()]
        }

  @enforce_keys [:spec]
  defstruct [:spec, router: nil, hosts: [], sources: [], displaced: []]

  @spec static(Spec.t(), source()) :: t()
  def static(%Spec{} = spec, source), do: %__MODULE__{spec: spec, sources: [source]}

  @spec key(t()) :: {Spec.module_key(), atom(), non_neg_integer() | :any}
  def key(%__MODULE__{spec: spec}), do: Spec.key(spec)
end
