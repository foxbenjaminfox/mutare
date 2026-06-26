defmodule Mutare.Plugin.Expansion do
  @moduledoc """
  The result of a plugin's `c:Mutare.Plugin.expand_use/3` overriding a `use`: the
  `import`/`alias`/`require …, as:` **directives** it injects (folded into resolution as
  if written inline at the `use`), plus the `@behaviour` **modules** the `use` injects.

  A **struct, not a tuple**, on purpose: the shape versions gracefully — a future field gets
  a default and an existing plugin that pattern-matches `%Expansion{directives: d}` keeps
  working, whereas widening a `{:ok, d, b}` tuple would break every match. Build it with
  `Mutare.Plugin.expand/2` rather than by hand.
  """

  defstruct directives: [], behaviours: []

  @type t :: %__MODULE__{directives: [Macro.t()], behaviours: [module()]}
end
