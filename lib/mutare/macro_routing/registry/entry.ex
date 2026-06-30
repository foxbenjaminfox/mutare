defmodule Mutare.MacroRouting.Registry.Entry do
  @moduledoc """
  **Internal.** A resolved `Mutare.MacroRouting.Registry` entry — not part of Mutare's public API.

  Pairs a routing `Mutare.Macro.Spec` (pure user data) with the callback *providers* the registry
  stamps from the contributing module:

    * `router` — the module answering a `:routing` classifier through
      `c:Mutare.MacroRouting.macro_routing/2` (`nil` for a static spec);
    * `host` — the enabled mutator delivering a `:hosted` argument through
      `c:Mutare.Mutator.MacroHost.host/2` (`nil` until a `:hosted` treatment needs it).

  Providers live here, off `Mutare.Macro.Spec`, so a user-constructed spec can never carry (or
  forge) one: provenance is always stamped by the registry from the module that contributed the
  route, never read off an incoming spec.
  """

  alias Mutare.Macro.Spec

  @type t :: %__MODULE__{
          spec: Spec.t(),
          router: module() | nil,
          host: module() | nil
        }

  @enforce_keys [:spec]
  defstruct [:spec, router: nil, host: nil]

  @doc "Wrap a routing `spec` with no provider stamps (a static route or built-in)."
  @spec static(Spec.t()) :: t()
  def static(%Spec{} = spec), do: %__MODULE__{spec: spec}

  @doc "The registry key of the wrapped spec."
  @spec key(t()) :: {Spec.module_key(), atom(), non_neg_integer() | :any}
  def key(%__MODULE__{spec: spec}), do: Spec.key(spec)
end
