defmodule Mutare.Transform.WrittenPipe do
  @moduledoc false
  # `left |> stage(args)` is sugar for `stage(left, args)`. A piped stage under a positional call
  # route is resolved and routed as that direct call (`Mutare.Transform.Resolve` marks it,
  # `Meta.routed_direct?/1`), and `direct/1` is where it *becomes* one: applied by
  # `Mutare.Transform.Analyze` as it reaches a node, so that routing, hosting, mutation and
  # delivery all read one call shape — and so that code Mutare never analyzes (a `:raw` argument,
  # a `:skip`ped call, a pattern, a verbatim clean copy) is never rewritten at all.
  #
  # The metamutant is free to keep the direct shape — it only has to compile. A `Mutare.Site` is
  # not: it patches the user's source by range and shows them a diff, so it must keep the
  # footprint and the spelling they wrote. The rest of this module is that obligation, read off
  # the `Meta.written_pipe/1` stamp `direct/1` leaves:
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
  alias Mutare.Transform.{Meta, MetaKeys}

  @doc """
  The direct call a marked pipe is sugar for — `Kernel.|>/2`'s own desugaring (`Macro.pipe/3`)
  of `left |> stage(args)`, carrying the stage's resolution and route stamps and the pipe as it
  stood (`Meta.written_pipe/1`). Any other node is returned untouched.

  The stamp holds the pipe *before* analysis, so its left side carries no `written_pipe` stamp
  of its own: a chain's stamps sum to its prefixes rather than doubling per stage.
  """
  @spec direct(Macro.t()) :: Macro.t()
  def direct({:|>, pipe_meta, [left, {head, meta, args} = stage]} = pipe) do
    if Meta.routed_direct?(stage) do
      # The call stands where the pipe stood, so it answers to the pipe's node identity: a
      # return tail recorded against the `|>` (`Mutare.Transform.Analyze.Returns` delivers by
      # `:mutare_nid`) must find this node.
      meta =
        meta
        |> Keyword.delete(MetaKeys.routed_direct_key())
        |> Keyword.put(MetaKeys.nid_key(), Keyword.fetch!(pipe_meta, MetaKeys.nid_key()))
        |> Meta.stamp_written_pipe(pipe)

      {head, meta, [left | args || []]}
    else
      pipe
    end
  end

  def direct(node), do: node

  @doc """
  The `|>` a rewritten call was written as, or `nil` for any other node — what
  `Mutare.Transform.NodeRange.get/1` ranges in the call's stead, since the call stands where the
  whole `left |> stage` stood.
  """
  @spec written(Macro.t()) :: Macro.t() | nil
  def written(node), do: Meta.written_pipe(node)

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
      {head, meta, [left | visible]} = call ->
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
