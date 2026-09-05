defmodule Mutare.CallRouting.Registry.Entry do
  @moduledoc false

  alias Mutare.CallRouting.Spec

  @type source :: {:builtin | :mutator | :extension, module()} | :config
  @type t :: %__MODULE__{
          spec: Spec.t(),
          router: module() | nil,
          hosts: [module()],
          sources: [source()],
          displaced: Spec.t() | nil
        }

  # `displaced` is the code-provided spec a configured call-level `:skip` overrode, kept for the
  # one thing `:skip` cannot answer on its own: what treatment the *piped* receiver carries. A
  # `:skip` says nothing about positions, so without this the pipe's left operand would fall back
  # to ordinary runtime — turning `1 |> match?(x)` (position 0 is `:pattern`) into a spliced
  # selector `case` inside a match. `:skip` must never route a position less safely than the route
  # it displaced. `nil` whenever the config entry overrode nothing, which is the common case.
  @enforce_keys [:spec]
  defstruct [:spec, router: nil, hosts: [], sources: [], displaced: nil]

  @spec static(Spec.t(), source()) :: t()
  def static(%Spec{} = spec, source), do: %__MODULE__{spec: spec, sources: [source]}

  @spec key(t()) :: {Spec.module_key(), atom(), non_neg_integer() | :any}
  def key(%__MODULE__{spec: spec}), do: Spec.key(spec)
end
