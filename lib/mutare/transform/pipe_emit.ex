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

  alias Mutare.Transform.{BindingEscapeEmit, Calls, Candidate, Ctx, Meta, Render}
  alias Mutare.Transform.Candidate.Delivery

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
  #   * **every** candidate kept argument 0 where it was, or returns that operand directly
  #     (call removal). Both shapes evaluate the operand once, and its bindings must stay
  #     outside the selector so they reach later statements. A mutant that rewrote or dropped it —
  #     a return-value constant standing in for the whole call among them — would either ignore
  #     the binding or run the original operand beside its own, so one such candidate sends the
  #     whole site back to inline delivery, exporting any bindings shared by its branches.
  #
  # Only a call *written as a pipe* is bound. The contract would allow binding a directly
  # written call's argument 0 just as well; nothing asks for it — the binding exists so that a
  # pipe chain costs the same whether or not its stages are routed, and directly nested calls
  # are not written thirty deep.

  @typedoc "Shared operand binding, inline binding export, or ordinary inline delivery."
  @type binding :: {:bind, keyword(), Macro.t()} | {:export, nonempty_list(atom())} | :inline

  @doc "How the selector preserves bindings: a shared operand, branch exports, or neither."
  @spec bound_argument(Macro.t(), [Candidate.t()]) :: binding()
  def bound_argument({_head, meta, [_zero | _rest]} = node, [_ | _] = candidates) do
    with {:|>, pipe_meta, _operands} <- Meta.written_pipe(node),
         [zero | _] when zero in [:expression, :interior] <- Meta.routing(meta),
         [%Candidate.InPlace{original: {_h, _m, [written | _]} = original} | _] <- candidates do
      if Enum.all?(candidates, &keeps_argument?(&1, written)) do
        {:bind, pipe_meta, written}
      else
        inline_binding(original, candidates)
      end
    else
      _plain -> :inline
    end
  end

  def bound_argument(_node, _candidates), do: :inline

  defp inline_binding(original, candidates) do
    names = BindingEscapeEmit.expression_bindings(original)

    # Moving an operand must retain the mutant's evaluation order. Return the result and
    # bindings from each branch instead of evaluating the original operand ahead of them.
    # Only bindings present in every branch can be exported (a whole-call constant has none).
    shared =
      Enum.reduce(candidates, names, fn candidate, names ->
        bound = candidate |> Delivery.selector_branch() |> BindingEscapeEmit.expression_bindings()
        Enum.filter(names, &(&1 in bound))
      end)

    case shared do
      [] -> :inline
      names -> {:export, names}
    end
  end

  defp keeps_argument?(%Candidate.InPlace{pin?: false, mutated: written}, written), do: true

  defp keeps_argument?(%Candidate.InPlace{pin?: false, mutated: {_h, _m, [zero | _]}}, written),
    do: zero == written

  defp keeps_argument?(_candidate, _written), do: false

  @doc "Rebind a retained operand, or append the branch's result and escaping bindings."
  @spec rebind(Macro.t(), binding(), Ctx.t()) :: Macro.t()
  def rebind(branch, :inline, _ctx), do: branch

  def rebind(branch, {:export, names}, ctx) do
    value = piped_var(ctx)
    {:__block__, [], [{:=, [], [value, branch]}, export_tuple(value, names)]}
  end

  def rebind(written, {:bind, _pipe_meta, written}, ctx), do: piped_var(ctx)

  def rebind({head, meta, [_zero | rest]}, {:bind, _pipe_meta, _written}, ctx),
    do: {head, meta, [piped_var(ctx) | rest]}

  @doc "Close over the shared operand, or rebind an inline selector's exported variables."
  @spec close(Macro.t(), binding(), Macro.t(), Ctx.t()) :: Macro.t()
  def close(selector, :inline, _argument, _ctx), do: selector

  def close(selector, {:export, names}, _argument, ctx) do
    value = piped_var(ctx)
    {:__block__, [], [{:=, [], [export_tuple(value, names), selector]}, value]}
  end

  def close(selector, {:bind, pipe_meta, _written}, argument, ctx) do
    closure = {:fn, [], [{:->, [], [[piped_var(ctx)], selector]}]}
    {:|>, pipe_meta, [argument, {{:., [], [closure]}, [], []}]}
  end

  defp piped_var(ctx), do: {ctx.config.piped_var, [], nil}

  defp export_tuple(value, names),
    do: {:{}, [], [value | Enum.map(names, &{&1, [], nil})]}

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
  # The selector marker is essential: emission also visits untouched raw/skipped syntax.
  defp pipe_into(lhs, stage, meta \\ [])

  defp pipe_into({:^, _, [expression]} = lhs, stage, meta) do
    case Render.selector_case_parts(expression) do
      {:ok, _subject, _clauses} -> Macro.pipe(lhs, stage, 0)
      :error -> {:|>, meta, [lhs, stage]}
    end
  end

  defp pipe_into(lhs, stage, meta), do: {:|>, meta, [lhs, stage]}
end
