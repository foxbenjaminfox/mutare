defmodule Mutare.CallRouting.Call do
  @moduledoc """
  Stable, resolved view of a known-macro call passed to routing and hosting callbacks.

  `arguments` are the call's arguments, all of them, however the call was written: Mutare
  treats a piped routed call as the direct call `Kernel.|>/2` would build, so
  `(p in Post) |> from(order_by: …)` is shown as `from(p in Post, order_by: …)`. A classifier
  routes the piped operand as the first argument it is, and a host or mutator can read and
  rewrite it like any other. `rebuild.(name, arguments)` preserves the source's bare,
  qualified, or aliased call form; reports still show the pipe the user wrote.

  At classification, arguments retain their written syntax. After routing, hosts see Elixir
  arguments resolved and `:raw`/`:hosted` fragments preserved, including their pipe operators.

  A module named in an argument is written as the call site's aliases make it (`Post` for
  `MyApp.Post` under `alias MyApp.Post`), or through `__MODULE__` (`__MODULE__`,
  `__MODULE__.Comment`). Arguments are not resolved at classification, so `resolved_module/2`
  reads such a name through the aliases and the module in force at the call site. It answers
  for the call handed to `c:Mutare.CallRouting.route_arguments/1`; a call obtained any other
  way carries neither, and resolves only an `Elixir.`-qualified name.

  The struct is produced by Mutare. Extension callbacks should match only the fields they need so
  additional fields can be added compatibly. `alias_env` and `enclosing_module` are internal,
  read only through `resolved_module/2`. To build one in a test, use `new/4` or `new/5`.
  """

  alias Mutare.Transform.Aliases

  @type t :: %__MODULE__{
          node: Macro.t(),
          module: module() | atom() | nil,
          name: atom(),
          arguments: [Macro.t()],
          rebuild: (atom(), [Macro.t()] -> Macro.t()),
          alias_env: map() | nil,
          enclosing_module: module() | nil
        }

  @enforce_keys [:node, :module, :name, :arguments, :rebuild]
  defstruct @enforce_keys ++ [alias_env: nil, enclosing_module: nil]

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

  @doc """
  `new/4`, with what is in force at the call site, for `resolved_module/2` to read:

    * `aliases: %{Short => Module}` — the aliases, the way an `alias Module, as: Short` would
      bind them;
    * `enclosing_module: Module` — the module the call is written in, which `__MODULE__` names.

  Either may be left out; a call without it resolves no name that needs it.

      iex> node = quote(do: where(Post, x > 1))
      iex> call = Mutare.CallRouting.Call.new(node, Ecto.Query, :where,
      ...>   fn name, args -> {name, [], args} end, aliases: %{Post: MyApp.Post})
      iex> Mutare.CallRouting.Call.resolved_module(call, hd(call.arguments))
      {:ok, MyApp.Post}
  """
  @spec new(
          Macro.t(),
          module() | atom() | nil,
          atom(),
          (atom(), [Macro.t()] -> Macro.t()),
          aliases: %{atom() => module()},
          enclosing_module: module()
        ) :: t()
  def new(node, module, name, rebuild, site) when is_list(site) do
    site = Keyword.validate!(site, aliases: nil, enclosing_module: nil)
    env = site[:aliases] && Map.new(site[:aliases], &alias_entry/1)

    %{
      new(node, module, name, rebuild)
      | alias_env: env,
        enclosing_module: site[:enclosing_module]
    }
  end

  defp alias_entry({short, target}), do: {short, Aliases.from_module(target)}

  @doc """
  The module a node in the call's arguments names, read through the aliases and the module in
  force at the call site: `{:ok, module}`, or `:error` for a node that is not a module name, or
  that needs something the call does not carry (see the moduledoc). An `Elixir.`-qualified name
  ignores aliases, as the compiler does, and so resolves either way. `__MODULE__` is the module
  the call is written in, and `__MODULE__.Comment` a name beneath it, as the compiler reads
  them; both are `:error` outside a module, or in one whose name is computed (`defmodule
  __MODULE__.Sub`, say). Whether the module exists is not checked.

      iex> node = quote(do: from(p in Post))
      iex> call = Mutare.CallRouting.Call.new(node, Ecto.Query, :from,
      ...>   fn name, args -> {name, [], args} end, aliases: %{Post: MyApp.Post})
      iex> {:in, _, [_binding, source]} = hd(call.arguments)
      iex> Mutare.CallRouting.Call.resolved_module(call, source)
      {:ok, MyApp.Post}
      iex> Mutare.CallRouting.Call.resolved_module(call, quote(do: Post.Comment))
      {:ok, MyApp.Post.Comment}
      iex> Mutare.CallRouting.Call.resolved_module(call, quote(do: p))
      :error

  `__MODULE__` reads the module the call is written in:

      iex> node = quote(do: from(p in __MODULE__))
      iex> call = Mutare.CallRouting.Call.new(node, Ecto.Query, :from,
      ...>   fn name, args -> {name, [], args} end, enclosing_module: MyApp.Post)
      iex> {:in, _, [_binding, source]} = hd(call.arguments)
      iex> Mutare.CallRouting.Call.resolved_module(call, source)
      {:ok, MyApp.Post}
      iex> Mutare.CallRouting.Call.resolved_module(call, quote(do: __MODULE__.Comment))
      {:ok, MyApp.Post.Comment}
      iex> unplaced = Mutare.CallRouting.Call.new(node, Ecto.Query, :from,
      ...>   fn name, args -> {name, [], args} end)
      iex> Mutare.CallRouting.Call.resolved_module(unplaced, source)
      :error
  """
  @spec resolved_module(t(), Macro.t()) :: {:ok, module()} | :error
  def resolved_module(%__MODULE__{enclosing_module: module}, {:__MODULE__, _meta, context})
      when is_atom(context) do
    if module, do: {:ok, module}, else: :error
  end

  # `__MODULE__.Comment`: the compiler prefixes the module to the written segments, and reads
  # none of them through an alias.
  def resolved_module(
        %__MODULE__{enclosing_module: module},
        {:__aliases__, _meta, [{:__MODULE__, _, context} | path]}
      )
      when is_atom(context) do
    if module && Aliases.atoms?(path),
      do: {:ok, Module.concat([module | path])},
      else: :error
  end

  def resolved_module(%__MODULE__{alias_env: env}, {:__aliases__, _meta, path})
      when is_list(path) do
    cond do
      not Aliases.atoms?(path) ->
        :error

      match?([:"Elixir", _ | _], path) ->
        {:ok, path |> Aliases.resolve_path(%{}) |> Aliases.to_module()}

      env == nil ->
        :error

      true ->
        {:ok, path |> Aliases.resolve_path(env) |> Aliases.to_module()}
    end
  end

  def resolved_module(%__MODULE__{}, _node), do: :error
end
