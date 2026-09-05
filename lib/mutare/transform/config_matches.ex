defmodule Mutare.Transform.ConfigMatches do
  @moduledoc false

  # The count pass's side channel for the **ineffective configuration** diagnostic: which call-route
  # keys and mark-declaration keys the resolved calls of one source actually hit. `Mutare.Schema`
  # unions these across every scanned file and reports the configured `call_routes:` /
  # `argument_marks:` entries that reached no call anywhere — the `skip_lifting` mirror
  # (`Mutare.Schema.detect_ineffective_skip_lifting/3`), for the same reason: a typo'd module or a
  # wrong arity otherwise leaves the entry silently inert.
  #
  # Both facts are read off stamps `Mutare.Transform.Resolve` already placed on the annotated tree —
  # the routed-call identity (`:mutare_route_call`, whose registry lookup yields the winning route's
  # key, wildcard keys included) and the mark-call key (`:mutare_mark_call`) — so this is one cheap
  # prewalk with no resolution logic of its own, and it can't drift from what the resolver matched.

  alias Mutare.CallRouting.Registry
  alias Mutare.CallRouting.Registry.Entry
  alias Mutare.Mutator
  alias Mutare.Transform.Meta

  @type t :: %{routes: MapSet.t(tuple()), marks: MapSet.t(tuple())}

  @doc "Collect the route keys and mark-declaration keys the calls in `ast` matched."
  @spec collect(Macro.t(), Registry.registry()) :: t()
  def collect(ast, registry) do
    {_ast, acc} =
      Macro.prewalk(ast, %{routes: MapSet.new(), marks: MapSet.new()}, fn
        {_head, meta, args} = node, acc when is_list(meta) and (is_list(args) or is_nil(args)) ->
          {node, acc |> add_route(meta, args, registry) |> add_mark(meta)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp add_route(acc, meta, args, registry) do
    case Meta.routed_call(meta) do
      {module_key, fun, pipe_mode} when pipe_mode in [:piped, :unpiped] ->
        arity = Mutator.effective_arity(args || [], pipe_mode)

        case Registry.lookup(registry, module_key, fun, arity) do
          %Entry{} = entry -> %{acc | routes: MapSet.put(acc.routes, Entry.key(entry))}
          nil -> acc
        end

      _ ->
        acc
    end
  end

  defp add_mark(acc, meta) do
    case Meta.mark_call(meta) do
      {_module_key, _fun, _arity} = key -> %{acc | marks: MapSet.put(acc.marks, key)}
      _ -> acc
    end
  end
end
