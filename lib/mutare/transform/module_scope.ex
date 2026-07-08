defmodule Mutare.Transform.ModuleScope do
  @moduledoc false
  # The **implicit-alias** vocabulary shared by the three module-scope-aware pre-passes
  # (`Uses`, `Resolve`, `Behaviours`). Elixir auto-introduces an alias for a nested module a
  # body defines, in scope for that body and for the definition's following siblings:
  #
  #     defmodule Outer do
  #       defmodule Foo do ... end
  #       def call, do: Foo.bar()    # `Foo` resolves to `Outer.Foo`, no explicit `alias`
  #     end
  #
  # The three walks each fold a lexically-scoped alias env (via `Aliases.register/2`) so an
  # explicit `alias`/`require …, as:` reaches later siblings; this module adds the *implicit*
  # alias a `defmodule`/`defprotocol` introduces, so a sibling/body reference to a nested module
  # by its short name resolves to the module Elixir actually defines. Without it, a call keyed on
  # such a module (a `:macro_routes` entry, in `Resolve`) or a nested `@behaviour` (in
  # `Behaviours`) is resolved to the wrong module and silently missed.
  #
  # Tracking the implicit alias requires the **enclosing module** (the parent), so each caller
  # threads a `module` accumulator (`nil` at the file top level, the sentinel `unresolved/0` under
  # a non-static head). `child_module/3` computes a nested head's full module from that parent +
  # the alias env; `register_defined_module/3` folds the implicit alias the head introduces;
  # `register_lexical/3` is the combined "explicit alias then implicit module alias" fold each
  # walk applies at every statement in a scope.

  alias Mutare.Transform.Aliases

  # The module name of a nested `defmodule` we couldn't resolve to a concrete atom (a non-static
  # head, or a child of an already-unresolved parent). A caller that reaches it stamps/resolves
  # nothing under that scope rather than run with a wrong `__CALLER__.module` / wrong key.
  @unresolved :__mutare_unresolved__

  @doc "The sentinel a non-resolvable module head resolves to (so a caller can pattern-match it)."
  @spec unresolved() :: atom()
  def unresolved, do: @unresolved

  @doc """
  Fold into the alias env both the alias a *source* statement introduces (an explicit
  `alias`/`require …, as:`, via `Aliases.register/2`) **and** the implicit alias Elixir
  auto-introduces for a nested module the statement defines (`register_defined_module/3`). Both
  scope to following siblings, so the unified fold keeps the env faithful for a later
  `use`/`defimpl`/call/`@behaviour` that refers to a sibling by short name.
  """
  @spec register_lexical(Macro.t(), module() | atom() | nil, map()) :: map()
  def register_lexical(stmt, module, env) do
    stmt |> Aliases.register(env) |> then(&register_defined_module(stmt, module, &1))
  end

  @doc """
  Mirror the alias Elixir auto-introduces when a module body **defines** a nested module:
  `defmodule Outer do defprotocol P …; defimpl P, for: Integer … end` aliases `P => Outer.P`, so
  the `defimpl`'s caller is `Outer.P.Integer` (not `P.Integer`); `defmodule U …; use U` aliases
  `U => Outer.U`, so the `use` target resolves. The alias binds the **first** written segment to
  the parent-prefixed first segment (`defmodule Foo.Bar` ⇒ `Foo => Outer.Foo`, *not*
  `Bar => Outer.Foo.Bar` — verified against the compiler), so it is computed as the
  `child_module/3` of just that first segment. Stored as a path (the form `Aliases.register/2`
  uses) so `resolve_path/2` can extend it (`P.Sub` ⇒ `Outer.P.Sub`). Skipped for a dynamic head
  (`@unresolved`), an absolute `Elixir.`-led head, and an atom-named module (no segment to alias).
  Only `defmodule`/`defprotocol` define such an alias — `defimpl` defines `P.T` but introduces no
  convenient short name, so it is not a definer here.
  """
  @spec register_defined_module(Macro.t(), module() | atom() | nil, map()) :: map()
  def register_defined_module({def_form, _meta, [mod_ast | _]}, module, env)
      when def_form in [:defmodule, :defprotocol] do
    with {:__aliases__, _, [first | _]} when is_atom(first) and first != :"Elixir" <- mod_ast,
         full when full != @unresolved <- child_module({:__aliases__, [], [first]}, module, env),
         path when is_list(path) <- module_path(full) do
      Map.put(env, first, path)
    else
      _ -> env
    end
  end

  def register_defined_module(_stmt, _module, env), do: env

  @doc """
  The full module name of a nested `defmodule`/`defprotocol`/`defimpl` head, best-effort: Elixir
  prepends the enclosing module to a nested alias. A non-static head (`__MODULE__.Child`,
  `unquote(mod)`, a `Module.concat(…)` call) can't be resolved to a concrete module, so it yields
  `@unresolved` and a caller expands/stamps/resolves **nothing** inside that module (rather than
  run with the wrong `__CALLER__.module`). The sentinel propagates inward (an unresolved parent ⇒
  unresolved child). A leading `Elixir` segment (`defmodule Elixir.Bar`) is the **absolute** escape
  — it defines `Bar`, never `Parent.Elixir.Bar` — so it is not prefixed. A bare-atom head
  (`defmodule :foo`) is itself a concrete module — atoms aren't namespaced — so it resolves to that
  atom (Sourceror wraps the literal as `{:__block__, _, [:foo]}`).

  A **top-level** (no-parent) head is resolved through the alias env — `alias RealParent, as: RP;
  defmodule RP.Child` defines `RealParent.Child`, so `__CALLER__.module` must be that. A **nested**
  head is *not* alias-resolved: Elixir prepends the parent to the *literal* segments (`defmodule
  RP.Child` inside `Outer` is `Outer.RP.Child`, the alias untouched), which the literal-path
  `Module.concat([parent | path])` already matches.
  """
  @spec child_module(Macro.t(), module() | atom() | nil, map()) :: module() | atom()
  def child_module({:__aliases__, _, path}, parent, env) when is_list(path) do
    cond do
      not Aliases.atoms?(path) -> @unresolved
      match?([:"Elixir" | _], path) -> Module.concat(path)
      parent == @unresolved -> @unresolved
      parent == nil -> path |> Aliases.resolve_path(env) |> Aliases.to_module()
      true -> Module.concat([parent | path])
    end
  end

  def child_module({:__block__, _, [atom]}, _parent, _env) when is_atom(atom), do: atom
  def child_module(atom, _parent, _env) when is_atom(atom), do: atom
  def child_module(_mod_ast, _parent, _env), do: @unresolved

  # A concrete Elixir module atom → its segment-atom path (`Outer.P` → `[:Outer, :P]`), the value
  # form the alias env stores for an Elixir module. `nil` for an Erlang atom module (`:foo`, from
  # `defmodule :foo`) — an atom has no last segment, so Elixir aliases nothing.
  defp module_path(mod) when is_atom(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> _ -> mod |> Module.split() |> Enum.map(&String.to_atom/1)
      _ -> nil
    end
  end
end
