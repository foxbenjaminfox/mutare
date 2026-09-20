defmodule Mutare.Transform.WrittenPipe do
  @moduledoc false
  # `left |> stage(args)` is sugar for `stage(left, args)`. Every stage `Kernel.|>/2` can pipe
  # into is resolved and routed as that direct call (`Mutare.Transform.Resolve` marks it,
  # `Meta.routed_direct?/1` — a stage under the call-level `:skip` included, restamped
  # `Meta.withheld?/1`), and `direct/1` is where it *becomes* one: applied by
  # `Mutare.Transform.Analyze` and the guard walker `Tag` as they reach a node, so that routing,
  # hosting, mutation and delivery all read one call shape — and so that code Mutare never
  # analyzes (a `:raw` argument, a `:skip`ped call, a pattern, a verbatim clean copy) is never
  # rewritten at all. A reader that skips it does not get a misaligned answer:
  # `Meta.routing/1` raises on a marked stage.
  #
  # The metamutant only has to compile (`Mutare.Transform.PipeEmit` spells the call as a pipe
  # again so a chain renders flat, nothing more). A `Mutare.Site` is held to more: it patches
  # the user's source by range and shows them a diff, so it must keep the footprint and the
  # spelling they wrote. The rest of this module is that obligation, read off the stamp
  # `direct/1` leaves.
  #
  # The stamp is the `|>` node's **meta** and nothing else (`Meta.written_pipe_meta/1`). The
  # call already holds the rest of the pipe — argument 0 is its left side, the call less that
  # argument its stage — so `written/1` rebuilds the pipe from the call, and is the one inverse
  # of `direct/1` that every reader of the spelling goes through (`resugar/1` here,
  # `Mutare.Transform.Render` for the metamutant). A stamp that held the pipe itself would be a
  # second copy of the left side, stale once analysis reaches argument 0, and a copy of every
  # upstream prefix down a chain.
  #
  #   * `written/1` — the rewritten call stands where the whole `left |> stage` stood, so
  #     `Mutare.Transform.NodeRange.get/1` ranges the written pipe in its stead. The call's own
  #     meta would range only the stage (`Sourceror.get_range/1` starts a call at its head), and a
  #     return-value replacement patched over that span would leave the `left |>` behind.
  #   * `stage_attribution/2` — a whole-call mutant that left argument 0 alone is a mutation of
  #     the *stage*, and is reported there: the stage's line (where a `# mutare:ignore` sits), the
  #     stage's text on both sides of the diff. A mutant that rewrote argument 0 (an operand
  #     swap, a call removal, a binding reorder on a piped source) has no narrower home than
  #     the pipe, and takes the default.
  #   * `stage_position/1` — a mutant reported over the whole pipe is still *keyed* at the stage:
  #     the line a `# mutare:ignore` or a `--line` names.
  #   * `resugar/1` — any rendered Site node shows a rewritten call as the pipe it was, with
  #     whatever operand 0 the node now holds.
  #
  # NOTES "A pipe stage is the call it is sugar for".

  alias Mutare.Mutator.Mutation
  alias Mutare.Transform.{Meta, MetaKeys, NodeRange}

  @doc """
  The direct call a marked pipe is sugar for — `Kernel.|>/2`'s own desugaring (`Macro.pipe/3`)
  of `left |> stage(args)`, carrying the stage's resolution and route stamps and the `|>`'s own
  meta (`Meta.written_pipe_meta/1`), which is all `written/1` needs to undo it. Any other node
  is returned untouched.
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
        |> Meta.stamp_written_pipe(pipe_meta)

      {head, meta, [left | args || []]}
    else
      pipe
    end
  end

  def direct(node), do: node

  @doc """
  The `|>` a rewritten call was written as — the inverse of `direct/1`, around whatever
  argument 0 the call now holds — or `nil` for any other node. It is what
  `Mutare.Transform.NodeRange.get/1` ranges in the call's stead, since the call stands where the
  whole `left |> stage` stood.

  The stage comes back marked (`Meta.routed_direct?/1`), as `direct/1` found it: its route stamp
  still lists the direct call's positions, so it must not be read on its own. A stage written
  without parentheses (`x |> to_string`) comes back without them.
  """
  @spec written(Macro.t()) :: Macro.t() | nil
  def written({head, meta, [left | visible]} = call) when is_list(meta) do
    case Meta.written_pipe_meta(call) do
      nil ->
        nil

      pipe_meta ->
        {_head, stage_meta, _args} = Meta.drop_written_pipe(call)
        stage = {head, Meta.stamp_routed_direct(stage_meta), written_args(head, meta, visible)}
        {:|>, pipe_meta, [left, stage]}
    end
  end

  def written(_node), do: nil

  # The parser gives every parenthesized call a `:closing`; a bare name that takes no written
  # argument and has none was written `x |> name`, whose arguments are `nil`.
  defp written_args(head, meta, []) when is_atom(head),
    do: if(Keyword.has_key?(meta, :closing), do: [], else: nil)

  defp written_args(_head, _meta, visible), do: visible

  @doc """
  The attribution that reports `mutated` — a replacement for the rewritten call `offered` — at
  the written stage, when it kept `offered`'s argument 0. `nil` when `offered` was not written
  as a pipe, or the mutant touched the left side.
  """
  @spec stage_attribution(Macro.t(), Macro.t()) :: Mutation.Attribution.t() | nil
  def stage_attribution({_head, _meta, [left | _visible]} = offered, mutated) do
    with {:|>, _pipe_meta, [^left, stage]} <- written(offered),
         {head, meta, [^left | visible]} <- mutated do
      Mutation.at(stage, Meta.drop_written_pipe({head, meta, visible}))
    else
      _whole_pipe -> nil
    end
  end

  def stage_attribution(_offered, _mutated), do: nil

  @doc """
  Where a mutant of the rewritten call `node` is keyed when it is reported over the whole pipe:
  the start of the written stage (`[line:, column:]`), or `nil` for a node not written as a
  pipe. In a multi-line chain the pipe's range starts lines above the stage, and a
  `# mutare:ignore` over the stage, or a `--line` naming it, means the stage's mutants —
  whether or not the mutant's patch needs the piped value too.
  """
  @spec stage_position(Macro.t()) :: keyword() | nil
  def stage_position(node) do
    with {:|>, _pipe_meta, [_left, stage]} <- written(node),
         %{start: start} <- NodeRange.get(stage) do
      start
    else
      _unpiped -> nil
    end
  end

  @doc "Render-side inverse of the rewrite: every rewritten call in `node` as the pipe it was."
  @spec resugar(Macro.t()) :: Macro.t()
  def resugar(node), do: Macro.prewalk(node, &(written(&1) || &1))
end
