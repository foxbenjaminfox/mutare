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

  # Syntax-valued operands cannot enter that closure: it evaluates them and hides their
  # AST from the macro. Distribute the pipe into the selector instead. Only the catch-all
  # gets the emitted LHS; mutant branches get the as-written one, since no upstream mutant
  # can be active there. This also keeps selectors inside pins from multiplying.

  # All of it is `Kernel.|>/2`'s alone. A `|>` displaced out of `Kernel` is left exactly as
  # emitted: the closure would apply the custom operator twice (once to reach the closure, once
  # inside each branch), and expanding a pinned left side would assume `Kernel`'s desugaring.

  alias Mutare.Transform.{Calls, Ctx, Meta, Render}

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
        case Meta.pipe_delivery(meta) do
          :value -> value_pipe(lhs, meta, subject, clauses, ctx)
          {:syntax, original} -> syntax_pipe(lhs, original, subject, clauses)
        end

      :error ->
        pipe_into(lhs, rhs, meta)
    end
  end

  defp value_pipe(lhs, meta, subject, clauses, ctx) do
    var = {ctx.config.piped_var, [], nil}
    piped = Enum.map(clauses, &pipe_clause(var, &1))
    closure = {:fn, [], [{:->, [], [[var], Render.selector_case(subject, piped)]}]}
    invocation = {{:., [], [closure]}, [], []}
    {:|>, meta, [lhs, invocation]}
  end

  defp syntax_pipe(lhs, original, subject, clauses) do
    {mutants, [catch_all]} = Enum.split(clauses, -1)
    piped = Enum.map(mutants, &pipe_clause(original, &1)) ++ [pipe_clause(lhs, catch_all)]
    Render.selector_case(subject, piped)
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
