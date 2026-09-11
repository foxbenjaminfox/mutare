defmodule Mutare.Reflection do
  @moduledoc false
  # The one home for the capability probe every optional-callback check runs: load `module` on
  # demand, then ask whether it exports `fun`/`arity`. `function_exported?/3` alone answers `false`
  # for a module that merely hasn't been loaded yet, so every site that discovers a capability
  # (a mutator's `init/1`, a host's `hosted_macros/0`, an extension's `expand_use/3`, a
  # behaviour's `behaviour_info/1`, …) needs the load first — and spelling the pair out at each
  # site is how one of them forgets. `Code.ensure_loaded?/1` is idempotent and cheap once the
  # module is loaded, so probing several arities of one module is fine.
  #
  # Total over any term: a non-atom (a string in `.mutare.exs`, `nil`) exports nothing, so a
  # caller can report it rather than crash on a guard.

  @spec exports?(term(), atom(), arity()) :: boolean()
  def exports?(module, fun, arity) when is_atom(module) and is_atom(fun) and is_integer(arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  def exports?(_term, _fun, _arity), do: false
end
