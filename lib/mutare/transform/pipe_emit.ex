defmodule Mutare.Transform.PipeEmit do
  @moduledoc false

  # `x |> case … end` does not compile — `Kernel.|>/2` cannot pipe into a `case`.
  # When ordinary selector emission wraps a pipe stage, the selector lands in exactly that
  # illegal RHS position. Run on the parent `|>` during the same postwalk (the RHS is already
  # emitted), this lifts the selector out of the pipe into a one-shot closure invoked on the
  # piped value:
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

  alias Mutare.Transform.{Ctx, Render}

  @doc """
  Hoist a selector `case` out of the RHS of a pipe, when the RHS is one of our selectors.
  """
  @spec hoist(Macro.t(), Ctx.t()) :: Macro.t()
  def hoist({:|>, meta, [lhs, rhs]} = node, ctx) do
    # Recognise a block-wrapped selector `case` as the pipe's RHS, then confirm its subject in
    # either supported shape: an inline `:persistent_term` read or the hoisted active-id variable.
    with {:ok, subject, clauses} <- Render.selector_case_parts(rhs),
         true <- Mutare.Metamutant.subject?(subject, ctx.active_var) do
      var = {ctx.piped_var, [], nil}

      piped =
        Enum.map(clauses, fn {:->, m, [pat, body]} ->
          {:->, m, [pat, pipe_tail(var, body)]}
        end)

      closure = {:fn, [], [{:->, [], [[var], Render.selector_case(subject, piped)]}]}
      invocation = {{:., [], [closure]}, [], []}
      {:|>, meta, [lhs, invocation]}
    else
      _ -> node
    end
  end

  def hoist(node, _ctx), do: node

  # Pipe `lhs` into a selector clause body. A mutant clause body is a single expression
  # (the mutated stage), piped whole; the catch-all body is a block whose head is the
  # coverage record and whose tail is the original stage, so only the tail is piped.
  defp pipe_tail(lhs, {:__block__, bmeta, stmts}) when stmts != [],
    do: {:__block__, bmeta, List.update_at(stmts, -1, &{:|>, [], [lhs, &1]})}

  defp pipe_tail(lhs, body), do: {:|>, [], [lhs, body]}
end
