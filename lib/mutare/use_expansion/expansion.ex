defmodule Mutare.UseExpansion.Expansion do
  @moduledoc """
  The directives and behaviours supplied by `c:Mutare.UseExpansion.expand_use/3`.

  Directives are folded into name resolution as if they had been injected by `use`; behaviours
  augment the enclosing module's resolved `@behaviour` set. Build this struct through
  `Mutare.UseExpansion.expand/2`.
  """

  defstruct directives: [], behaviours: []

  @type t :: %__MODULE__{directives: [Macro.t()], behaviours: [module()]}
end
