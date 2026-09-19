defmodule Mutare.CallRouting.Call do
  @moduledoc """
  Stable, resolved view of a known-macro call passed to routing and hosting callbacks.

  `arguments` are the call's arguments, all of them, however the call was written: Mutare
  rewrites a piped routed call into the direct call `Kernel.|>/2` would build, so
  `(p in Post) |> from(order_by: …)` is shown as `from(p in Post, order_by: …)`. A classifier
  routes the piped operand as the first argument it is, and a host or mutator can read and
  rewrite it like any other. `rebuild.(name, arguments)` preserves the source's bare,
  qualified, or aliased call form; reports still show the pipe the user wrote.

  The struct is produced by Mutare. Extension callbacks should match only the fields they need so
  additional fields can be added compatibly. To build one in a test, use `new/4`.
  """

  @type t :: %__MODULE__{
          node: Macro.t(),
          module: module() | atom() | nil,
          name: atom(),
          arguments: [Macro.t()],
          rebuild: (atom(), [Macro.t()] -> Macro.t())
        }

  @enforce_keys [:node, :module, :name, :arguments, :rebuild]
  defstruct @enforce_keys

  @doc """
  Build a call value from the written call `node`, the resolved `module` and `name`, and the
  `rebuild` function. `arguments` are read off `node`, so the two always agree.

      iex> node = quote(do: where(Post, x > 1))
      iex> call = Mutare.CallRouting.Call.new(node, Ecto.Query, :where,
      ...>   fn name, args -> {name, [], args} end)
      iex> length(call.arguments)
      2
  """
  @spec new(Macro.t(), module() | atom() | nil, atom(), (atom(), [Macro.t()] -> Macro.t())) ::
          t()
  def new({_head, _meta, arguments} = node, module, name, rebuild)
      when is_list(arguments) and is_atom(name) and is_function(rebuild, 2) do
    %__MODULE__{
      node: node,
      module: module,
      name: name,
      arguments: arguments,
      rebuild: rebuild
    }
  end
end
