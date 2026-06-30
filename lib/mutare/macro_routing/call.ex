defmodule Mutare.MacroRouting.Call do
  @moduledoc """
  Stable, resolved view of a known-macro call passed to routing and hosting callbacks.

  `arguments` contains only arguments visible in the written call. For a piped call, the pipe's
  left side is the macro's effective argument zero but is not part of the call node; `pipe_mode`
  and `effective_arity` make that distinction explicit. `rebuild.(name, arguments)` preserves the
  source's bare, qualified, or aliased call form.

  The struct is produced by Mutare. Extension callbacks should match only the fields they need so
  additional fields can be added compatibly.
  """

  @type t :: %__MODULE__{
          node: Macro.t(),
          module: module() | atom() | nil,
          name: atom(),
          arguments: [Macro.t()],
          pipe_mode: Mutare.Mutator.pipe_mode(),
          effective_arity: non_neg_integer(),
          rebuild: (atom(), [Macro.t()] -> Macro.t())
        }

  @enforce_keys [
    :node,
    :module,
    :name,
    :arguments,
    :pipe_mode,
    :effective_arity,
    :rebuild
  ]
  defstruct @enforce_keys
end
