defmodule Mutare.CallRouting.Call do
  @moduledoc """
  Stable, resolved view of a known-macro call passed to routing and hosting callbacks.

  `arguments` contains only arguments visible in the written call. For a piped call, the pipe's
  left side is the macro's effective argument zero but is not part of the call node; `pipe_left`
  carries it, and `pipe_mode` and `effective_arity` are derived from it. `rebuild.(name, arguments)`
  preserves the source's bare, qualified, or aliased call form.

  ## The pipe's left side

  `pipe_left` is `:unpiped`, or `{:piped, left}` with the left side of the `|>` the call is the
  right side of. It lets a classifier route the piped position by the shape of what is piped
  (`Post |> from(…)` and `build(x) |> from(…)` want different treatments), and lets a host or
  mutator read a declaration written there (`(p in Post) |> from(…)`).

  Two limits:

    * **Read-only.** `rebuild` and a host's `splice` rewrite the visible call only. Nothing a
      callback returns can replace the left side, which is why the piped position cannot be routed
      `:hosted`.
    * **As written, never resolved.** `left` is the source AST, without the alias and import
      resolution Mutare records on the nodes it walks. `Mutare.Calls.resolved_call/1` on a call
      inside it returns `nil`, whatever the call resolves to in the source — match it by shape.
      In a chain, `left` is the whole upstream pipe (`a |> b()` for the `c()` stage of
      `a |> b() |> c()`).

  The struct is produced by Mutare. Extension callbacks should match only the fields they need so
  additional fields can be added compatibly. To build one in a test, use `new/5`: it derives the
  dependent fields, so a later addition cannot break the test.
  """

  @typedoc "Whether a call is a pipe's right side, and if so the left side as written."
  @type pipe_left :: :unpiped | {:piped, Macro.t()}

  @type t :: %__MODULE__{
          node: Macro.t(),
          module: module() | atom() | nil,
          name: atom(),
          arguments: [Macro.t()],
          pipe_left: pipe_left(),
          pipe_mode: Mutare.Mutator.pipe_mode(),
          effective_arity: non_neg_integer(),
          rebuild: (atom(), [Macro.t()] -> Macro.t())
        }

  @enforce_keys [
    :node,
    :module,
    :name,
    :arguments,
    :pipe_left,
    :pipe_mode,
    :effective_arity,
    :rebuild
  ]
  defstruct @enforce_keys

  @doc """
  Build a call value from its independent facts: the written call `node`, the resolved `module`
  and `name`, the `pipe_left`, and the `rebuild` function.

  `arguments` are read off `node`, and `pipe_mode` and `effective_arity` follow from `pipe_left`,
  so the derived fields always agree with their sources.

      iex> node = quote(do: where(x > 1))
      iex> call = Mutare.CallRouting.Call.new(node, Ecto.Query, :where, {:piped, quote(do: Post)},
      ...>   fn name, args -> {name, [], args} end)
      iex> {call.pipe_mode, call.effective_arity, length(call.arguments)}
      {:piped, 2, 1}
  """
  @spec new(
          Macro.t(),
          module() | atom() | nil,
          atom(),
          pipe_left(),
          (atom(), [Macro.t()] -> Macro.t())
        ) :: t()
  def new({_head, _meta, arguments} = node, module, name, pipe_left, rebuild)
      when is_list(arguments) and is_atom(name) and is_function(rebuild, 2) do
    pipe_mode = pipe_mode(pipe_left)

    %__MODULE__{
      node: node,
      module: module,
      name: name,
      arguments: arguments,
      pipe_left: pipe_left,
      pipe_mode: pipe_mode,
      effective_arity: Mutare.Mutator.effective_arity(arguments, pipe_mode),
      rebuild: rebuild
    }
  end

  @doc """
  The `t:Mutare.Mutator.pipe_mode/0` a `t:pipe_left/0` implies.

      iex> Mutare.CallRouting.Call.pipe_mode(:unpiped)
      :unpiped
      iex> Mutare.CallRouting.Call.pipe_mode({:piped, quote(do: query)})
      :piped
  """
  @spec pipe_mode(pipe_left()) :: Mutare.Mutator.pipe_mode()
  def pipe_mode(:unpiped), do: :unpiped
  def pipe_mode({:piped, _left}), do: :piped
end
