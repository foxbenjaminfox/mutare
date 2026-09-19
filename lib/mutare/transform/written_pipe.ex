defmodule Mutare.Transform.WrittenPipe do
  @moduledoc false
  # `Mutare.Transform.Resolve` rewrites a piped **routed** stage into the direct call
  # `Kernel.|>/2` would build (`left |> from(opts)` becomes `from(left, opts)`), so routing,
  # hosting, mutation and delivery all read one call shape. The metamutant is free to keep that
  # shape — it only has to compile. A `Mutare.Site` is not: it patches the user's source by range
  # and shows them a diff, so it must keep the footprint and the spelling they wrote. This module
  # is the whole of that obligation, read off the `Meta.written_pipe/1` stamp:
  #
  #   * `range/1` — the rewritten call stands where the whole `left |> stage` stood. Its own
  #     meta would range only the stage (`Sourceror.get_range/1` starts a call at its head), and a
  #     return-value replacement patched over that span would leave the `left |>` behind.
  #   * `stage_attribution/2` — a whole-call mutant that left argument 0 alone is a mutation of
  #     the *stage*, and is reported there: the stage's line (where a `# mutare:ignore` sits), the
  #     stage's text on both sides of the diff. A mutant that rewrote argument 0 (a binding
  #     reorder on a piped source) has no narrower home than the pipe, and takes the default.
  #   * `resugar/1` — any rendered Site node shows a rewritten call as the pipe it was, with
  #     whatever operand 0 the node now holds.
  #
  # NOTES "A routed pipe stage becomes a direct call".

  alias Mutare.Mutator.Mutation
  alias Mutare.Transform.Meta

  @doc "The source range of the `|>` a rewritten call was written as, or `nil` for any other node."
  @spec range(Macro.t()) :: Sourceror.Range.t() | nil
  def range(node) do
    case Meta.written_pipe(node) do
      nil -> nil
      pipe -> Sourceror.get_range(pipe)
    end
  end

  @doc """
  The attribution that reports `mutated` — a replacement for the rewritten call `offered` — at
  the written stage, when it kept `offered`'s argument 0. `nil` when `offered` was not written
  as a pipe, or the mutant touched the left side.
  """
  @spec stage_attribution(Macro.t(), Macro.t()) :: Mutation.Attribution.t() | nil
  def stage_attribution({_head, _meta, [left | _visible]} = offered, mutated) do
    with {:|>, _pipe_meta, [_written_left, stage]} <- Meta.written_pipe(offered),
         {head, meta, [^left | visible]} <- mutated do
      Mutation.at(stage, Meta.drop_written_pipe({head, meta, visible}))
    else
      _whole_pipe -> nil
    end
  end

  def stage_attribution(_offered, _mutated), do: nil

  @doc "Render-side inverse of the rewrite: every rewritten call in `node` as the pipe it was."
  @spec resugar(Macro.t()) :: Macro.t()
  def resugar(node) do
    Macro.prewalk(node, fn
      {head, meta, [left | visible]} = call when is_list(meta) ->
        case Meta.written_pipe(call) do
          {:|>, pipe_meta, _written} ->
            {:|>, pipe_meta, [left, Meta.drop_written_pipe({head, meta, visible})]}

          nil ->
            call
        end

      other ->
        other
    end)
  end
end
