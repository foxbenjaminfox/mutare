defmodule Mutare.Transform.WrittenPipe do
  @moduledoc false
  # `left |> stage(args)` is sugar for `stage(left, args)`, and `Mutare.Transform.Resolve` makes
  # every stage `Kernel.|>/2` can pipe into that direct call, across the whole tree (`direct/2`
  # is the stamp it leaves). Routing, hosting, mutation and delivery all read one call shape, at
  # every depth: a mutator looking into its node's operands finds calls, never a stage one
  # argument short. Code Mutare never analyzes (a `:raw` argument, a `:skip`ped call, a clean
  # copy) is rewritten with the rest and spelled back exactly by `written/1`, so what the
  # compiler — and any macro handed such a region — receives is the pipe the user wrote.
  #
  # The metamutant only has to compile, to the program the user wrote (`Mutare.Transform.Render`
  # spells each call as a pipe again). A `Mutare.Site` is held to more: it patches
  # the user's source by range and shows them a diff, so it must keep the footprint and the
  # spelling they wrote. The rest of this module is that obligation, read off the stamp
  # `direct/2` leaves.
  #
  # The stamp is the `|>` node's **meta** and nothing else (`Meta.written_pipe_meta/1`). The
  # call already holds the rest of the pipe — argument 0 is its left side, the call less that
  # argument its stage — so `written/1` rebuilds the pipe from the call, and is the one inverse
  # of the rewrite that every reader of the spelling goes through (`resugar/1` here,
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
  # NOTES "A pipe stage is the call it is sugar for", "The rewrite is Resolve's".

  alias Mutare.Mutator.Mutation
  alias Mutare.Transform.{Meta, MetaKeys, NodeRange}

  @doc """
  Record on `call` — the direct call `Kernel.|>/2`'s own desugaring (`Macro.pipe/3`) made of a
  `left |> stage(args)`, already resolved and routed — that it was written as the pipe whose
  meta is `pipe_meta` (`Meta.written_pipe_meta/1`), which is all `written/1` needs to undo it.

  The call stands where the pipe stood, so it answers to the pipe's node identity: a return
  tail recorded against the `|>` (`Mutare.Transform.Analyze.Returns` delivers by
  `:mutare_nid`) must find this node.
  """
  @spec direct(keyword(), Macro.t()) :: Macro.t()
  def direct(pipe_meta, {head, meta, [_left | _visible] = args}) when is_list(pipe_meta) do
    meta =
      meta
      |> Keyword.put(MetaKeys.nid_key(), Keyword.fetch!(pipe_meta, MetaKeys.nid_key()))
      |> Meta.stamp_written_pipe(pipe_meta)

    {head, meta, args}
  end

  @doc """
  The `|>` a rewritten call was written as — the inverse of `direct/1`, around whatever
  argument 0 the call now holds — or `nil` for any other node. It is what
  `Mutare.Transform.NodeRange.get/1` ranges in the call's stead, since the call stands where the
  whole `left |> stage` stood.

  The stage it rebuilds is for a range and for rendering: it still carries the direct call's
  resolution and route stamps, which describe one argument more than it holds. A stage written
  without parentheses (`x |> to_string`) comes back without them.
  """
  @spec written(Macro.t()) :: Macro.t() | nil
  def written({head, meta, [left | visible]} = call) when is_list(meta) do
    with pipe_meta when is_list(pipe_meta) <- Meta.written_pipe_meta(call),
         {_head, stage_meta, _args} = Meta.drop_written_pipe(call),
         stage = {head, stage_meta, written_args(head, meta, visible)},
         true <- stage?(left, stage) do
      {:|>, pipe_meta, [left, stage]}
    else
      _not_a_pipe -> nil
    end
  end

  def written(_node), do: nil

  # Whether `stage` is something `Kernel.|>/2` pipes into. The stamp is meta, and meta is copied
  # by whoever rebuilds a node on it: a mutator that turns `div(n, 2)` into `n - 2`, `-n` or a
  # literal and keeps the call's meta has built a node that was never a stage. Spelled as one it
  # would read `n |> -2`, which does not compile — in the piped spelling alone. So the question
  # is put to `Macro.pipe/3`, which is `Kernel.|>/2`'s own answer, and an operator is refused
  # whatever its arity (`n |> *(2)` is accepted there and is not source anyone writes).
  defp stage?(_left, {head, _meta, _args}) when is_atom(head) and head in [:__block__, :fn, :&],
    do: false

  defp stage?(left, {head, _meta, _args} = stage) do
    not (is_atom(head) and (Macro.operator?(head, 1) or Macro.operator?(head, 2))) and
      pipes?(left, stage)
  end

  defp pipes?(left, stage) do
    Macro.pipe(left, stage, 0)
    true
  rescue
    ArgumentError -> false
  end

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
         {head, meta, [^left | visible]} <- mutated,
         mutated_stage = Meta.drop_written_pipe({head, meta, visible}),
         true <- stage?(left, mutated_stage) do
      Mutation.at(stage, mutated_stage)
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
