defmodule Mutare.Transform.CoverageEmit do
  @moduledoc false
  # Scope-aware coverage emission. Delivery paths choose the recording position; this
  # module chooses the gate and records its binding dependencies. `Mutare.Coverage.Recorder`
  # owns the pure generated AST, including the helper payload and runtime contract.
  #
  # A `:local` active binding is introduced by the generated selector/tuple clause or
  # dispatcher itself. An `:enclosing` binding must already be available in the emit
  # scope, and using it keeps that scope's prologue or lifted dispatcher alive — which is
  # why every caller hands the binding kind over rather than calling `Recorder` directly.

  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.{Ctx, Scope, SelectorEmit}

  @spec record([pos_integer()], Ctx.t(), :local | :enclosing) :: {Macro.t(), Ctx.t()}
  def record(ids, %Ctx{} = ctx, binding) when ids != [] do
    ctx = reference(ctx, binding)
    {Recorder.record_ast(ids, ctx.config.active_var, ctx.config.runtime_namespace), ctx}
  end

  defp reference(ctx, :local), do: ctx

  defp reference(ctx, :enclosing) do
    true = Scope.active_var_bound?(ctx.scope)
    SelectorEmit.reference_active(ctx)
  end
end
