defmodule Mutare.Transform.PipeEmit do
  @moduledoc false

  # `x |> case … end` does not compile — `Kernel.|>/2` cannot pipe into a `case`.
  # When ordinary selector emission wraps a pipe stage, the selector lands in exactly that
  # illegal RHS position. Run on the parent `|>` during the same postwalk (the RHS is already
  # emitted, and carries the marker `Render.selector_case/2` stamped on it), this lifts the
  # selector out of the pipe into a one-shot closure invoked on the piped value:
  #
  #     lhs |> (fn mutare_piped ->
  #               case <subject> do
  #                 <id> -> mutare_piped |> <mutant stage>
  #                 _    -> <cov>; mutare_piped |> <original stage>
  #               end
  #             end).()
  #
  # The piped value is computed once (it stays the pipe's LHS, so the upstream chain appears
  # once) and bound to the closure's param; each branch pipes that cheap variable instead of a
  # copy of `lhs`. This keeps a chain of mutated stages linear in the rendered source, and the
  # bare stage stays the Site's recorded node, so the diff is unaffected.

  # The closure evaluates the piped value ahead of the stage — what a function does with its
  # first argument, and a call is a function in every respect its route does not address
  # (`Mutare.CallRouting`, "Evaluation"). Core never derives whether a callee is a macro; a
  # callee that does not evaluate its operand eagerly says so with `:lazy_expression`. A stage
  # under a positional route never reaches `hoist/2` as a pipe — analysis made it the direct
  # call (`Mutare.Transform.WrittenPipe.direct/1`) — and takes the binding from
  # `bound_argument/2` below.

  # All of it is `Kernel.|>/2`'s alone. A `|>` displaced out of `Kernel` is left exactly as
  # emitted: the closure would apply the custom operator twice (once to reach the closure, once
  # inside each branch), and expanding a pinned left side would assume `Kernel`'s desugaring.

  alias Mutare.Transform.{Calls, Candidate, Ctx, Meta, Render}

  @doc """
  Hoist a selector out of a pipe's RHS and preserve a pinned LHS's rendering precedence.
  """
  @spec hoist(Macro.t(), Ctx.t()) :: Macro.t()
  def hoist({:|>, meta, [lhs, rhs]} = node, ctx) do
    if Calls.kernel_call?(node), do: hoist_kernel_pipe(lhs, rhs, meta, ctx), else: node
  end

  def hoist(node, _ctx), do: node

  defp hoist_kernel_pipe(lhs, rhs, meta, ctx) do
    # The pipe's RHS is one of our selectors iff it carries the builder's marker; the subject
    # (inline read or hoisted variable) is reused as-is inside the closure.
    case Render.selector_case_parts(rhs) do
      {:ok, subject, clauses} ->
        value_pipe(lhs, meta, subject, clauses, ctx)

      :error ->
        pipe_into(lhs, rhs, meta)
    end
  end

  # --- a rewritten stage's piped value ----------------------------------------------------
  #
  # A piped stage under a positional route is no `|>` by now (`WrittenPipe.direct/1` made it
  # the direct call), so its selector is the ordinary one, whose every mutant branch carries the
  # call's as-written arguments — argument 0, the whole upstream chain, included. Down a chain of
  # routed stages that is a copy of each prefix per mutant. The closure above answers the same
  # problem for a pipe, and answers it here the same way, by binding the piped value once:
  #
  #     <emitted argument 0>
  #     |> (fn mutare_piped ->
  #           case <subject> do
  #             <id> -> <mutant stage>(mutare_piped, …)
  #             _    -> <cov>; <original stage>(mutare_piped, …)
  #           end
  #         end).()
  #
  # which is what such a stage was delivered as while it was still a pipe — the `|>` included.
  # It is the user's own (its meta, from the `Meta.written_pipe/1` stamp), so it resolves as it
  # did in their source: to `Kernel`, or the stage would not have been rewritten. Applying the
  # closure to the argument directly would nest each stage inside the next and indent a long
  # chain quadratically; piped, the chain renders flat. Two conditions, both read off the node
  # (`bound_argument/2`):
  #
  #   * argument 0 is routed `:expression` or `:interior`: a value, which the callee is taken to
  #     evaluate as a function would. `:lazy_expression` is the route's way of saying it does
  #     not, and every other treatment says the macro reads the argument as syntax, which a
  #     variable would hide.
  #   * **every** candidate kept argument 0 where it was. A mutant that rewrote or dropped it —
  #     a return-value constant standing in for the whole call among them — would either ignore
  #     the binding or run the original operand beside its own, so one such candidate sends the
  #     whole site back to plain delivery.
  #
  # Only a call *written as a pipe* is bound. The contract would allow binding a directly
  # written call's argument 0 just as well; nothing asks for it — the binding exists so that a
  # pipe chain costs the same whether or not its stages are routed, and directly nested calls
  # are not written thirty deep.

  @typedoc "The written `|>`'s meta, for a site that binds its argument 0 — or `:inline`."
  @type binding :: {:bind, keyword()} | :inline

  @doc "Whether `node`'s selector binds its argument 0 once (see above), and to what."
  @spec bound_argument(Macro.t(), [Candidate.t()]) :: binding()
  def bound_argument({_head, meta, [_zero | _rest]} = node, [_ | _] = candidates) do
    with {:|>, pipe_meta, _operands} <- Meta.written_pipe(node),
         [zero | _] when zero in [:expression, :interior] <- Meta.routing(meta),
         [%Candidate.InPlace{original: {_h, _m, [written | _]}} | _] <- candidates,
         true <- Enum.all?(candidates, &keeps_argument?(&1, written)) do
      {:bind, pipe_meta}
    else
      _plain -> :inline
    end
  end

  def bound_argument(_node, _candidates), do: :inline

  defp keeps_argument?(%Candidate.InPlace{pin?: false, mutated: {_h, _m, [zero | _]}}, written),
    do: zero == written

  defp keeps_argument?(_candidate, _written), do: false

  @doc "A selector branch (mutant or default) with its argument 0 replaced by the piped variable."
  @spec rebind(Macro.t(), binding(), Ctx.t()) :: Macro.t()
  def rebind(branch, :inline, _ctx), do: branch

  def rebind({head, meta, [_zero | rest]}, {:bind, _pipe_meta}, ctx),
    do: {head, meta, [piped_var(ctx) | rest]}

  @doc "Close a rebound selector over `argument`, the emitted argument 0."
  @spec close(Macro.t(), binding(), Macro.t(), Ctx.t()) :: Macro.t()
  def close(selector, :inline, _argument, _ctx), do: selector

  def close(selector, {:bind, pipe_meta}, argument, ctx) do
    closure = {:fn, [], [{:->, [], [[piped_var(ctx)], selector]}]}
    {:|>, pipe_meta, [argument, {{:., [], [closure]}, [], []}]}
  end

  defp piped_var(ctx), do: {ctx.config.piped_var, [], nil}

  defp value_pipe(lhs, meta, subject, clauses, ctx) do
    var = piped_var(ctx)
    piped = Enum.map(clauses, &pipe_clause(var, &1))
    closure = {:fn, [], [{:->, [], [[var], Render.selector_case(subject, piped)]}]}
    invocation = {{:., [], [closure]}, [], []}
    {:|>, meta, [lhs, invocation]}
  end

  defp pipe_clause(lhs, {:->, meta, [pattern, body]}),
    do: {:->, meta, [pattern, pipe_tail(lhs, body)]}

  # Pipe `lhs` into a selector clause body. A mutant clause body is a single expression
  # (the mutated stage), piped whole; the catch-all body is a block whose head is the
  # coverage record and whose tail is the original stage, so only the tail is piped.
  defp pipe_tail(lhs, {:__block__, bmeta, stmts}) when stmts != [],
    do: {:__block__, bmeta, List.update_at(stmts, -1, &pipe_into(lhs, &1))}

  defp pipe_tail(lhs, body), do: pipe_into(lhs, body)

  # Sourceror renders a generated pin over a selector as `^case … end |> stage()`,
  # which reparses as `^(case … end |> stage())`. Expand just this pipe as Kernel would,
  # so the pin stays the macro's argument. This also applies when only the LHS mutates.
  defp pipe_into(lhs, stage, meta \\ [])
  defp pipe_into({:^, _, [_]} = lhs, stage, _meta), do: Macro.pipe(lhs, stage, 0)

  defp pipe_into(lhs, stage, meta), do: {:|>, meta, [lhs, stage]}
end
