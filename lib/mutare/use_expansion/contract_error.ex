defmodule Mutare.UseExpansion.ContractError do
  @moduledoc """
  Raised when an enabled `Mutare.UseExpansion` handler returns an invalid result or fails.

  This is a configuration error in an installed extension, not a property of the target source.
  The distinct exception lets the otherwise failure-tolerant `use` harvesting boundary re-raise
  extension failures while still degrading safely when the target's own `__using__` cannot expand.
  """

  defexception [:message]
end
