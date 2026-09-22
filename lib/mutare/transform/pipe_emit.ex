defmodule Mutare.Transform.PipeEmit do
  @moduledoc false

  # Binding-preserving selector delivery, with a shared-operand optimization for calls
  # **written as a pipe**. `Mutare.Transform.Resolve` made every
  # `Kernel.|>/2` stage the direct call it is sugar for, so a stage's selector is the
  # ordinary one, whose every mutant branch carries the call's as-written arguments — argument
  # 0, the whole upstream chain, included, while its catch-all nests the emitted chain. Down a
  # chain that is a copy of each prefix per mutant, and a `case` nested per stage. So the piped
  # value is bound once, in a one-shot closure invoked on it:
  #
  #     <emitted argument 0>
  #     |> (fn mutare_piped ->
  #           case <subject> do
  #             <id> -> mutare_piped |> <mutant stage>
  #             _    -> <cov>; mutare_piped |> <original stage>
  #           end
  #         end).()
  #
  # The upstream chain appears once and a chain of mutated stages renders flat, linear in its
  # length. The `|>` is the user's own (its meta, the `Meta.written_pipe_meta/1` stamp), so it
  # resolves as it did in their source: to `Kernel`, or the stage would not have been rewritten.
  #
  # This is the one place a call's spelling and its route are read together, and both answer a
  # delivery question, invisible to mutators, to reports and to a function's behaviour:
  #
  #   * **written as a pipe** — the closure pays only where it can be rendered under a `|>`.
  #     Applied to a directly nested call it would nest as deep as the call does, and wrap a
  #     closure around every nested operator; directly nested calls are not written thirty deep.
  #   * **argument 0 is a value** — unrouted, or routed `:expression`/`:interior`. The closure
  #     evaluates the piped value ahead of the call, what an ordinary call does with its first
  #     argument, and a call is ordinary in every respect its route does not address
  #     (`Mutare.CallRouting`, "Ordinary calls"). `:lazy_expression` is the route's way of saying
  #     the callee does not, and every other treatment says the macro reads the argument as
  #     syntax, which a variable would hide.
  #   * **the callee is inert** — a bare call or a call on a statically resolved module has no
  #     receiver expression to evaluate. A dynamic remote or anonymous callee runs before its
  #     arguments, so moving argument 0 outside the call would reverse their order; those calls
  #     keep ordinary branch-local delivery.
  #
  # A candidate rides inside the closure when it **keeps argument 0** where it was, or returns
  # that operand directly (call removal): both evaluate the operand once, first. One that moves
  # or drops it (an operand swap, a return-value constant standing in for the whole call) would
  # either ignore the binding or run the original operand beside its own, and hoisting the
  # operand ahead of a swapped call would change the mutant's evaluation order. Those go in an
  # **outer** selector around the closure, each branch evaluating its own as-written expression
  # in its own order (`{:split, …}`) — the shape a tail pipe's return-value selector has always
  # had around its stage's.
  #
  # Every selector is a scope boundary: a `case` branch traps what it binds. So what the
  # branches bind is returned beside the result through a tuple and rebound outside
  # (`{:export, names}`), and the closure, a boundary too, exports what its stage binds the
  # same way. Which names *can* be exported is the scope's business, not the expression's
  # (`Mutare.Transform.Bindings`): a name **bound on entry** is exported by every branch — one
  # that does not rebind it names the incoming value, which is what the source leaves after a
  # rebinding a mutant removed — and a name bound **fresh** only by the branches that bind it,
  # so it is exported when every *live* branch does. A live branch that drops a fresh name
  # something reads later never reaches here (`Candidate.Delivery.gate/2` withheld it); one
  # that drops a fresh name nothing reads leaves it unexported, trapped in the catch-all,
  # unread. The live set is the emitter's to hand over: an ignored or poison-skipped candidate
  # has no branch, and must not decide what the program exports.
  #
  # Bindings made by argument 0 already escape from the closure invocation's argument
  # expression and must not be captured inside the closure. They are made *after* the closure
  # is created, too: a stage that reads (or rebinds) a name argument 0 binds would see the
  # value captured at creation, so such a site keeps ordinary branch-local delivery.
  #
  # The calls this leaves in the tree are direct calls still; `Mutare.Transform.Render` spells
  # each as the pipe it was written as, so the metamutant is as deep as the user's source, not
  # one level deeper per stage.
  #
  # The emitter drives this in three steps, and needs to know nothing about layers or bindings:
  # `delivery/2` decides, `branch/3` places and rebinds one candidate's branch, and `layers/5`
  # builds the selector or selectors through the emitter's own builder.

  alias Mutare.Transform.{BindingEscapeEmit, Bindings, Calls, Candidate, Ctx, Meta}
  alias Mutare.Transform.Candidate.Delivery

  @typedoc "How one selector treats what its branches share: nothing, exported bindings, or a bound operand."
  @type binding ::
          :inline
          | {:export, nonempty_list(atom())}
          | {:bind, keyword(), Macro.t(), [atom()]}

  @typedoc """
  A site's delivery: one selector under one `t:binding/0`, or `{:split, inner, outer}` — the
  candidates that keep argument 0 in a bound closure (`inner`), the rest in a selector around
  it (`outer`).
  """
  @type t ::
          binding()
          | {:split, {:bind, keyword(), Macro.t(), [atom()]}, :inline | {:export, [atom()]}}

  @typedoc "Which selector of a `t:t/0` a candidate is delivered in: inside the closure, or around it."
  @type layer :: :inner | :outer

  @doc """
  How `node`'s **live** candidates are delivered — see the module header. `candidates` are the
  ones that get a branch; a withheld candidate is not passed.
  """
  @spec delivery(Macro.t(), [Candidate.t()]) :: t()
  def delivery({_head, meta, [_zero | _rest]} = node, [_ | _] = candidates) do
    {bound, _later} = Meta.bindings(node)

    with pipe_meta when is_list(pipe_meta) <- Meta.written_pipe_meta(node),
         true <- value_position?(Meta.routing(meta)),
         [%Candidate.InPlace{original: {_h, _m, [written | _]} = original} | _] <- candidates,
         true <- inert_callee?(original),
         true <- separable?(written, original, candidates) do
      case Enum.split_with(candidates, &keeps_argument?(&1, written)) do
        {kept, []} ->
          {:bind, pipe_meta, written, stage_exports(original, kept, bound)}

        {[], moved} ->
          exports(original, moved, bound)

        {kept, moved} ->
          stage = stage_exports(original, kept, bound)

          {:split, {:bind, pipe_meta, written, stage},
           outer_exports(original, stage, moved, bound)}
      end
    else
      _plain -> exports(original_of(candidates, node), candidates, bound)
    end
  end

  def delivery(_node, _candidates), do: :inline

  # The node as the candidates were offered it — with its routes, without its candidates.
  defp original_of([%Candidate.InPlace{original: original} | _], _node), do: original
  defp original_of(_candidates, node), do: Meta.strip_delivery(node)

  @doc """
  Which selector of `delivery` `candidate` is delivered in, and its branch there — a retained
  operand rebound to the closure's variable, or the branch's result and escaping bindings
  appended.
  """
  @spec branch(Candidate.t(), t(), Ctx.t()) :: {layer(), Macro.t()}
  def branch(candidate, delivery, ctx) do
    layer = layer(candidate, delivery)
    {layer, candidate |> Delivery.selector_branch() |> rebind(binding(delivery, layer), ctx)}
  end

  @typedoc "Builds one selector from its catch-all and the claimed items of one layer."
  @type builder(item) :: (Macro.t(), [item], Ctx.t() -> {Macro.t(), Ctx.t()})

  @doc """
  Build `delivery`'s selectors around `default`, the inner one first. `claimed` tags each
  claimed item with its `branch/3` layer; `build` makes one selector from a catch-all and the
  items of one layer. A layer none of whose items was claimed (every mutation skipped) has no
  selector, and the node passes through it.
  """
  @spec layers(t(), Macro.t(), [{layer(), item}], Ctx.t(), builder(item)) :: {Macro.t(), Ctx.t()}
        when item: term()
  def layers(delivery, default, claimed, ctx, build) do
    Enum.reduce([:inner, :outer], {default, ctx}, fn layer, {default, ctx} ->
      case for({^layer, item} <- claimed, do: item) do
        [] ->
          {default, ctx}

        items ->
          binding = binding(delivery, layer)
          {selector, ctx} = default |> rebind(binding, ctx) |> build.(items, ctx)
          {close(selector, binding, default, ctx), ctx}
      end
    end)
  end

  defp layer(candidate, {:split, {:bind, _pipe_meta, written, _exports}, _outer}),
    do: if(keeps_argument?(candidate, written), do: :inner, else: :outer)

  # With no split there is one selector, and either name for it builds the same one.
  defp layer(_candidate, _binding), do: :outer

  defp binding({:split, inner, _outer}, :inner), do: inner
  defp binding({:split, _inner, outer}, :outer), do: outer
  defp binding(binding, _layer), do: binding

  # An unrouted call is a function, whose every argument is a value.
  defp value_position?(nil), do: true
  defp value_position?([zero | _rest]), do: zero in [:expression, :interior]

  # A skipped call keeps only the mutants that replace it whole, as a function's tail.
  # mutare:ignore[boolean] equivalent — those keep no argument 0, so they never ride the closure
  defp value_position?(:skip), do: false

  # A bare call or a call on a statically resolved module has no runtime callee expression to
  # move across argument 0. A dynamic remote/anonymous receiver is evaluated before its
  # arguments, so binding argument 0 outside the call would reverse their order.
  defp inert_callee?({head, _meta, args}) when is_atom(head) and is_list(args), do: true
  defp inert_callee?(node), do: not is_nil(Calls.resolved_call(node))

  # Argument 0's bindings are made after the closure is created and outside it: a stage that
  # reads or rebinds one would see the captured value instead. Such a site is not closed over.
  defp separable?(written, {_head, _meta, [_zero | rest]}, candidates) do
    case BindingEscapeEmit.expression_bindings(written) do
      [] ->
        true

      names ->
        stages = [rest | Enum.map(candidates, &stage_rest/1)]
        not Enum.any?(names, &MapSet.member?(Bindings.referenced_names(stages), &1))
    end
  end

  defp stage_rest(candidate) do
    case Delivery.selector_branch(candidate) do
      {_head, _meta, [_zero | rest]} -> rest
      _other -> []
    end
  end

  # What the closure exports: the stage's bindings, made after argument 0 enters it. Argument
  # 0's own bindings already escape from the closure invocation's argument expression.
  defp stage_exports(original, kept, bound) do
    export_names(stage(original), Enum.map(kept, &stage/1), bound)
  end

  # What the outer selector of a split exports: the catch-all is the closure application, which
  # binds argument 0's escaping names and rebinds what the closure exported (`stage`).
  defp outer_exports({_head, _meta, [written | _rest]} = original, stage, moved, bound) do
    fresh =
      written
      |> BindingEscapeEmit.expression_bindings()
      |> Kernel.++(stage)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(bound, &1))

    original
    |> export_names(Enum.map(moved, &Delivery.selector_branch/1), bound, fresh)
    |> export_binding()
  end

  defp exports(original, candidates, bound) do
    original
    |> export_names(Enum.map(candidates, &Delivery.selector_branch/1), bound)
    |> export_binding()
  end

  # The names a selector over `original` exports, given its live `branches`: every name bound
  # on entry that `original` may rebind — by a match anywhere in it, or by a position its
  # route declares binding (`destructure/2`) — and every fresh name all the branches bind.
  # `fresh` defaults to what `original` binds fresh.
  # mutare:ignore-start[operand_swap, call_removal] equivalent — the export tuple is built and matched from this one list, in any order, and a name listed twice matches one value twice
  defp export_names(original, branches, bound, fresh \\ nil) do
    escaping = BindingEscapeEmit.expression_bindings(original)

    rebound =
      original
      |> Bindings.matched_names()
      |> Kernel.++(escaping)
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(bound, &1))

    fresh = fresh || Enum.reject(escaping, &MapSet.member?(bound, &1))

    shared =
      Enum.reduce(branches, fresh, fn branch, names ->
        kept = BindingEscapeEmit.expression_bindings(branch)
        Enum.filter(names, &(&1 in kept))
      end)

    Enum.uniq(rebound ++ shared)
  end

  # mutare:ignore-end

  # The stage with a placeholder for argument 0: what binds after the piped value enters.
  # mutare:ignore[atom, tuple] equivalent — any placeholder that binds nothing does
  defp stage(%Candidate.InPlace{} = candidate),
    do: candidate |> Delivery.selector_branch() |> stage()

  defp stage({head, meta, [_zero | rest]}), do: {head, meta, [{:mutare_piped, [], nil} | rest]}
  defp stage(other), do: other

  defp export_binding([]), do: :inline
  defp export_binding(names), do: {:export, names}

  defp keeps_argument?(%Candidate.InPlace{pin?: false, mutated: written}, written), do: true

  defp keeps_argument?(%Candidate.InPlace{pin?: false, mutated: {_h, _m, [zero | _]}}, written),
    do: zero == written

  defp keeps_argument?(_candidate, _written), do: false

  # Rebind a retained operand, or append the branch's result and escaping bindings.
  defp rebind(branch, :inline, _ctx), do: branch

  defp rebind(branch, {:export, names}, ctx) do
    value = piped_var(ctx)
    {:__block__, [], [{:=, [], [value, branch]}, export_tuple(value, names)]}
  end

  defp rebind(written, {:bind, _pipe_meta, written, names}, ctx),
    do: export_branch(piped_var(ctx), names, ctx)

  defp rebind({head, meta, [_zero | rest]}, {:bind, _pipe_meta, _written, names}, ctx),
    do: export_branch({head, meta, [piped_var(ctx) | rest]}, names, ctx)

  # Close over the shared operand — `default`'s emitted argument 0 — or rebind an inline
  # selector's exported variables.
  defp close(selector, :inline, _default, _ctx), do: selector

  defp close(selector, {:export, names}, _default, ctx) do
    value = piped_var(ctx)
    {:__block__, [], [{:=, [], [export_tuple(value, names), selector]}, value]}
  end

  defp close(
         selector,
         {:bind, pipe_meta, _written, names},
         {_head, _meta, [argument | _rest]},
         ctx
       ) do
    closure = {:fn, [], [{:->, [], [[piped_var(ctx)], selector]}]}
    application = {:|>, pipe_meta, [argument, {{:., [], [closure]}, [], []}]}

    case names do
      [] ->
        application

      names ->
        value = piped_var(ctx)
        {:__block__, [], [{:=, [], [export_tuple(value, names), application]}, value]}
    end
  end

  defp export_branch(branch, [], _ctx), do: branch

  defp export_branch(branch, names, ctx) do
    value = piped_var(ctx)
    {:__block__, [], [{:=, [], [value, branch]}, export_tuple(value, names)]}
  end

  defp piped_var(ctx), do: {ctx.config.piped_var, [], nil}

  defp export_tuple(value, names),
    do: {:{}, [], [value | Enum.map(names, &{&1, [], nil})]}
end
