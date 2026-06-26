defmodule Mutare.Plugin.ContractError do
  @moduledoc """
  Raised when a `Mutare.Plugin`'s `c:Mutare.Plugin.expand_use/3` **misbehaves** — it returns a value
  that is neither a `Mutare.Plugin.Expansion` (build it with `Mutare.Plugin.expand/2`) nor
  `:decline`, **or** it raises / throws. (A raise or throw is *wrapped* in this error, the original
  cause kept in the message; `Mutare.Plugin.expand/2`'s own non-list guard raises this directly.)

  Any such failure is a **configuration** error — an installed plugin is broken — *not* a property
  of the target being scanned, so it surfaces **loudly** (like `Mutare.Plugin.validate!/1` on a
  non-plugin module) rather than degrading silently to `:decline` the way a target's un-expandable
  `use` does. It is a distinct exception type precisely so the `Mutare.Transform.Uses.Harvest`
  never-raise boundary can re-raise *this* while still swallowing the target-expansion failures it
  is designed to absorb.
  """
  defexception [:message]
end
