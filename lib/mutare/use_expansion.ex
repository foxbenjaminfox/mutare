defmodule Mutare.UseExpansion do
  @moduledoc """
  Capability behaviour for overriding a `use` that Mutare cannot expand safely in-process.

  `Mutare.Transform.Uses` normally expands module-level `use` calls to recover injected imports,
  aliases, requires, and behaviours. Some `__using__` macros mutate their caller or depend on
  compile-time state unavailable to the scan process. An enabled extension can implement
  `c:expand_use/3` to supply those directives explicitly.

  This capability is independent of macro routing. A library integration commonly implements
  both `Mutare.UseExpansion` and `Mutare.MacroRouting`, but either may be used alone. The module is
  listed once under `:extensions`:

      defmodule Mutare.Gettext do
        @behaviour Mutare.UseExpansion
        @behaviour Mutare.MacroRouting

        @impl Mutare.UseExpansion
        def expand_use(Gettext, _args, _context) do
          Mutare.UseExpansion.expand([quote(do: import(Gettext.Macros))])
        end

        def expand_use(_used, _args, _context), do: :decline

        @impl Mutare.MacroRouting
        def macro_routes, do: [{Gettext.Macros, :gettext, 1, [:skip]}]
      end

  Multiple handlers are consulted in `:extensions` order; the first result other than
  `:decline` wins. Options from a `{module, opts}` entry arrive in `context.opts`.
  """

  alias Mutare.UseExpansion.{ContractError, Expansion}

  @typedoc "The result of handling a `use`, or `:decline` to try the next handler."
  @type expansion :: Expansion.t() | :decline

  @typedoc """
  Context passed to `c:expand_use/3`.

    * `:module` — the alias-resolved caller module containing the `use`;
    * `:opts` — options from this extension's `{module, opts}` configuration entry.

  It is a map so future context can be added without changing callback arity.
  """
  @type context :: %{
          required(:module) => module(),
          required(:opts) => keyword(),
          optional(atom()) => term()
        }

  @doc """
  Overrides expansion of `use used_module, ...`.

  `used_module` is alias-resolved. `args` is the quoted argument list written
  after the module. Return an expansion built by `expand/2`, or `:decline` to let
  the next handler try. Invalid returns, raises, throws, and exits are wrapped in
  `Mutare.UseExpansion.ContractError`.
  """
  @callback expand_use(used_module :: module(), args :: [Macro.t()], context :: context()) ::
              expansion()

  @doc """
  Build an expansion from injected directives and optional behaviour modules.

  ## Examples

      iex> expansion = Mutare.UseExpansion.expand([quote(do: import String)], [GenServer])
      iex> {length(expansion.directives), expansion.behaviours}
      {1, [GenServer]}
  """
  @spec expand([Macro.t()], [module()]) :: Expansion.t()
  def expand(directives, behaviours \\ [])

  def expand(directives, behaviours) when is_list(directives) and is_list(behaviours),
    do: %Expansion{directives: directives, behaviours: behaviours}

  def expand(directives, behaviours) do
    raise ContractError,
      message:
        "Mutare.UseExpansion.expand/2 expects a list of directives and a list of behaviours, " <>
          "got: directives=#{inspect(directives)}, behaviours=#{inspect(behaviours)}"
  end
end
