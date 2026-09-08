defmodule Mutare.Transform.RescueEmit do
  @moduledoc false

  # Share the protected do/else/after blocks across rescue mutants without extracting
  # a function (which would add stack frames). An outer native try catches raw errors;
  # the selected inner try re-raises their original reason/stack through native rescue
  # matching and normalization. Handler failures escape; else/after stay on the outer try.
  #
  # Eligibility is deliberately positional: an already-bound selector, no catch block,
  # and every rescue head binds the SAME non-underscored variable over literal types.
  # Reusing that name in the generated catch introduces no new variable visible to
  # source handlers or macros. Bare types/lists, mixed bindings, and unknown type syntax
  # retain ordinary whole-try delivery. See NOTES "Rescue factoring experiments".
  #
  # Rescue mutants must still run raw do/else/after bodies: sharing the instrumented
  # baseline indiscriminately could expose nested selectors' bindings to source macros.
  # Each block therefore has at most one raw and one instrumented copy, selected without
  # binding a new variable. Identical raw/emitted ASTs need no body selector.

  alias Mutare.AST
  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.Candidate.Delivery

  alias Mutare.Transform.{
    Candidate,
    Ctx,
    GuardBuild,
    ImportWitness,
    Meta,
    Render,
    Scope,
    SelectorEmit
  }

  @spec emit(Macro.t(), [Delivery.node_candidate()], Ctx.t()) ::
          {Macro.t(), Ctx.t()} | :fallback
  def emit({:try, meta, [blocks]} = node, candidates, %Ctx{} = ctx) do
    with %Scope{active_bound: true, module_depth: 0} <- ctx.scope,
         false <- Enum.any?(candidates, &match?(%Candidate.InPlace{pin?: true}, &1)),
         true <- Enum.any?(candidates, &rescue_candidate?/1),
         {:ok, binding} <- shared_binding(blocks) do
      {claimed, ctx} =
        SelectorEmit.claim_items(candidates, ctx, {&Delivery.site/4, &Delivery.line/1}, fn id,
                                                                                           c ->
          {id, c}
        end)

      {rescues, whole} = Enum.split_with(claimed, fn {_id, c} -> rescue_candidate?(c) end)
      default = Meta.strip_delivery(node)

      if length(rescues) >= 2 do
        rewritten = factor(meta, blocks, rescues, binding, ctx)
        {select(rewritten, whole, ctx), ctx}
      else
        {select(default, claimed, ctx), ctx}
      end
    else
      _ -> :fallback
    end
  end

  defp rescue_candidate?(%Candidate.CasePattern{}), do: true
  defp rescue_candidate?(%Candidate.RescueDrop{}), do: true
  defp rescue_candidate?(_), do: false

  defp shared_binding(blocks) do
    case {block(blocks, :catch), block(blocks, :rescue)} do
      {nil, [_ | _] = clauses} ->
        case clauses |> Enum.map(&head_binding/1) |> Enum.uniq() do
          [name] when is_atom(name) and not is_nil(name) -> {:ok, {name, [], nil}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp head_binding({:->, _, [[{:in, _, [var, types]}], _]}) do
    if literal_types?(types), do: binding_name(var)
  end

  defp head_binding({:->, _, [[var], _]}), do: binding_name(var)
  defp head_binding(_), do: nil

  defp binding_name({name, _, context}) when is_atom(name) and is_atom(context) do
    unless String.starts_with?(Atom.to_string(name), "_"), do: name
  end

  defp binding_name(_), do: nil

  defp literal_types?({:__block__, _, [types]}), do: literal_types?(types)
  defp literal_types?(types) when is_list(types), do: Enum.all?(types, &literal_types?/1)
  defp literal_types?({:__aliases__, _, parts}), do: Enum.all?(parts, &is_atom/1)
  defp literal_types?(type), do: is_atom(type)

  defp factor(meta, blocks, rescues, binding, ctx) do
    ids = Enum.map(rescues, &elem(&1, 0))
    [{_, first} | _] = rescues
    {:try, _, [raw_blocks]} = first.replacement
    exclusion = GuardBuild.exclusion(ids, ctx.config.active_var)

    reraised = AST.erlang_call(:raise, [AST.literal(:error), binding, {:__STACKTRACE__, [], nil}])

    branches =
      Enum.map(rescues, fn {id, candidate} ->
        {:try, _, [mutated_blocks]} = candidate.replacement

        branch =
          mutated_blocks
          |> handlers(reraised)
          |> ImportWitness.wrap(ImportWitness.for_candidate(candidate))

        {:->, [], [[id], branch]}
      end)

    fallback = {:->, [], [[{:_, [], nil}], handlers(blocks, reraised)]}
    dispatch = SelectorEmit.raw_case(branches, fallback, ctx)
    catch_clause = {:->, [], [[AST.literal(:error), binding], dispatch]}

    shared =
      blocks
      |> Enum.reject(fn {key, _} -> AST.key_atom(key) == :rescue end)
      |> Enum.map(fn {key, emitted} ->
        raw = block(raw_blocks, AST.key_atom(key))

        value =
          case AST.key_atom(key) do
            :else -> share_else(raw, emitted, exclusion, ctx)
            _ -> share_body(raw, emitted, exclusion, ctx)
          end

        {key, value}
      end)

    Render.block_wrap(
      {:__block__, [],
       [
         Recorder.record_ast(ids, ctx.config.active_var, ctx.config.runtime_namespace),
         {:try, meta, [shared ++ [catch: [catch_clause]]]}
       ]}
    )
  end

  defp handlers(blocks, reraised),
    do: {:try, [do: [], end: []], [[do: reraised, rescue: block(blocks, :rescue)]]}

  defp share_else(raw, emitted, exclusion, ctx) do
    Enum.zip_with(raw, emitted, fn {:->, _, [_, raw_body]}, {:->, meta, [head, body]} ->
      {:->, meta, [head, share_body(raw_body, body, exclusion, ctx)]}
    end)
  end

  defp share_body(body, body, _exclusion, _ctx), do: body

  defp share_body(raw, emitted, exclusion, ctx) do
    original = {:->, [], [[{:when, [], [{:_, [], nil}, exclusion]}], emitted]}
    mutant = {:->, [], [[{:_, [], nil}], raw]}
    Render.selector_case(SelectorEmit.subject(ctx), [original, mutant])
  end

  defp block(blocks, name) do
    Enum.find_value(blocks, fn {key, value} ->
      if AST.key_atom(key) == name, do: {:found, value}
    end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  defp select(node, [], _ctx), do: node

  defp select(node, claimed, ctx) do
    branches =
      Enum.map(claimed, fn {id, candidate} ->
        branch =
          candidate
          |> Delivery.selector_branch()
          |> ImportWitness.wrap(ImportWitness.for_candidate(candidate))

        {:->, [], [[id], branch]}
      end)

    SelectorEmit.selector_case(node, branches, ctx)
  end
end
