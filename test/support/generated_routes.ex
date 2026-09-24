# Two `Mutare.CallRouting` providers whose declarations are whatever the calling process put
# there — for properties that build a `Mutare.CallRouting.Registry` from *generated* code
# routes. `Registry.build/3` invokes `call_routes/0` in the caller's process, so a test sets the
# routes (`put/2`) and builds in the same `forall` body; the process dictionary keeps it
# `async: true`-safe. Two providers, so a declaration can be made by one, the other, or both
# (the same key from two sources coalesces in the registry; the property checks it does).
defmodule Mutare.Test.GeneratedRoutes do
  @moduledoc false

  @providers [__MODULE__.A, __MODULE__.B]

  @doc "The provider modules, in a fixed order."
  def providers, do: @providers

  @doc "Install `routes` as `provider`'s `call_routes/0` for the calling process."
  def put(provider, routes) when provider in @providers,
    do: Process.put({provider, :call_routes}, routes)

  for provider <- @providers do
    defmodule provider do
      @moduledoc false
      @behaviour Mutare.CallRouting

      @impl Mutare.CallRouting
      def call_routes, do: Process.get({__MODULE__, :call_routes}, [])
    end
  end
end
