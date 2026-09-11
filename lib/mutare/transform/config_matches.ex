defmodule Mutare.Transform.ConfigMatches do
  @moduledoc false

  # The count pass's side channel for the **ineffective configuration** diagnostic: which of the
  # run's configured entries the resolved code of one source actually reached — the `:skip_lifting`
  # entries any statement sequence matched (`Mutare.Transform.ModulePlan` reports them), the
  # call-route keys (`Mutare.CallRouting.Spec.key/0`, wildcards included), and the mark-declaration
  # keys (`{module_key, fun, arity}`) the resolved calls hit. `Mutare.Schema` unions these across
  # every scanned file and reports the configured `skip_lifting:` / `call_routes:` /
  # `argument_marks:` entries that reached nothing anywhere — the mirror of an ineffective
  # `# mutare:ignore` directive, for the same reason: a typo'd module or a wrong arity otherwise
  # leaves the entry silently inert.
  #
  # Lives on `Mutare.Transform.Ctx` as its own `matches` field — sink-independent, and never
  # touched by id claiming (`Mutare.Transform.ClaimState`). The route/mark facts are read off
  # stamps `Mutare.Transform.Resolve` already placed on the annotated tree (`collect/2` — the
  # routed-call identity `:mutare_route_call`, whose registry lookup yields the winning route's
  # key, and the mark-call key `:mutare_mark_call`), so that is one cheap prewalk with no
  # resolution logic of its own, and it can't drift from what the resolver matched.

  alias Mutare.CallRouting.Registry
  alias Mutare.CallRouting.Registry.Entry
  alias Mutare.Mutator
  alias Mutare.Transform.Meta

  @type t :: %__MODULE__{
          skip_lifting: MapSet.t(Mutare.Lifting.skip_entry()),
          routes: MapSet.t(tuple()),
          marks: MapSet.t(tuple())
        }

  defstruct skip_lifting: MapSet.new(), routes: MapSet.new(), marks: MapSet.new()

  @doc "Collect the route keys and mark-declaration keys the calls in `ast` matched."
  @spec collect(Macro.t(), Registry.registry()) :: t()
  def collect(ast, registry) do
    {_ast, acc} =
      Macro.prewalk(ast, %__MODULE__{}, fn
        {_head, meta, args} = node, acc when is_list(meta) and (is_list(args) or is_nil(args)) ->
          {node, acc |> add_route(meta, args, registry) |> add_mark(meta)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  @doc "Record the `:skip_lifting` entries a statement sequence matched."
  @spec add_skip_lifting(t(), MapSet.t(Mutare.Lifting.skip_entry())) :: t()
  def add_skip_lifting(%__MODULE__{} = matches, entries),
    do: %{matches | skip_lifting: MapSet.union(matches.skip_lifting, entries)}

  @doc "The field-wise union of two match records (one per scanned file, folded by `Mutare.Schema`)."
  @spec union(t(), t()) :: t()
  def union(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      skip_lifting: MapSet.union(a.skip_lifting, b.skip_lifting),
      routes: MapSet.union(a.routes, b.routes),
      marks: MapSet.union(a.marks, b.marks)
    }
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
