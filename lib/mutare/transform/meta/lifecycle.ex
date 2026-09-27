defmodule Mutare.Transform.Meta.Lifecycle do
  @moduledoc false
  # Annotation transitions, distinct from Meta's individual readers and writers.
  #
  # invalidate_call_resolution/1 affects one call and its remote head; its children,
  # identity, positions and spelling survive. for_resolution/1 also restores that
  # call's written pipe before invalidation. preserve_written/1 applies that policy
  # throughout syntax a route withholds, without resolving or classifying it.
  # consume_delivery/1 removes only the consumed node's candidate lists.
  # release_analysis/1 releases retained resolver capabilities throughout a tree,
  # including metadata carried inside metadata, while preserving program data.
  #
  # WrittenPipe owns the spelling codec; this module owns when resolution ceases
  # to describe it. Render still owns the final scrub of all internal annotations.

  alias Mutare.Transform.{MetaKeys, WrittenPipe}

  @delivery_keys MetaKeys.delivery()

  @doc "Remove all delivery annotations from one consumed node, retaining every other stamp."
  @spec consume_delivery(Macro.t()) :: Macro.t()
  def consume_delivery({form, meta, args}) when is_list(meta),
    do: {form, Keyword.drop(meta, @delivery_keys), args}

  def consume_delivery(node), do: node

  # A changed call may carry the offered call's meta (`rebuild` copies it, the stamped head
  # included; a mutator may reuse it outright): every stamp resolution left there describes
  # another call, and the walk stamps the call it now is. `Imports.stamp/5` and
  # `Aliases.stamp_module/2` prepend, so a stale stamp left behind a fresh one is unread, but
  # one left where the rebuilt name resolves to nothing would be read as the call's — a
  # renamed bare import as the import it no longer is. The node's identity, spelling and
  # positions are not resolution's (`:mutare_nid`, `:mutare_written_pipe`, `:mutare_operand_of`)
  # and stay.
  @call_stamps [
    MetaKeys.import_key(),
    MetaKeys.import_witness_key(),
    MetaKeys.kernel_displaced_key(),
    MetaKeys.route_key(),
    MetaKeys.displaced_route_key(),
    MetaKeys.route_call_key(),
    MetaKeys.resolution_key(),
    MetaKeys.mark_call_key()
  ]

  @spec invalidate_call_resolution(Macro.t()) :: Macro.t()
  def invalidate_call_resolution({form, meta, args}) when is_list(meta),
    do: {unstamped_head(form), Keyword.drop(meta, @call_stamps), args}

  def invalidate_call_resolution(node), do: node

  defp unstamped_head({:., dot_meta, [{:__aliases__, alias_meta, path}, fun]}),
    do:
      {:., dot_meta,
       [{:__aliases__, Keyword.delete(alias_meta, MetaKeys.alias_key()), path}, fun]}

  defp unstamped_head(form), do: form

  # What fails reuse is handed to the walk as written. A direct call `Kernel.|>/2`'s desugaring
  # made of a written pipe (`WrittenPipe.direct/2`) is that desugaring only while `|>` still
  # resolves to `Kernel`: a mutant that imports another `|>` over the offered call changes what
  # the written operator means, and the compiler reads the patch — spelled as the pipe again by
  # `Mutare.Transform.Render` — by that import. Resolving the direct call again would find no
  # operator to reconsider, so the pipe is restored first (`WrittenPipe.written/1`), pipe and
  # stage stripped of their stale stamps, and the `|>` clause resolves the operator in the
  # environment now in force: `Kernel`'s desugars it again, and stamps it again; another's takes
  # the bare-call walk with its own route. A node `|>` cannot pipe into — a stamp a mutator's
  # operator or literal inherited with the offered meta — has no written pipe, and is the call
  # it is, its stamps dropped (`invalidate_call_resolution/1`).
  @spec for_resolution(Macro.t()) :: Macro.t()
  def for_resolution(node) do
    case WrittenPipe.written(node) do
      {:|>, _pipe_meta, [left, stage]} = pipe ->
        invalidate_call_resolution(put_elem(pipe, 2, [left, invalidate_call_resolution(stage)]))

      nil ->
        invalidate_call_resolution(node)
    end
  end

  # What a route keeps as written — a skipped call's arguments, a `:raw` or `:hosted`
  # position, a skipped `quote` or `|>` — the walk does not resolve, and the readers that look
  # into it resolve it themselves, through the environment the boundary retained (`Resolve.context/2`,
  # `Resolve.kernel_form/2`, `Resolve.preserved_routing/2`). A file's walk leaves such a region as parsed, with
  # nothing to mislead them. A mutant's may hold the offered node's resolved calls there, and
  # reuse was never decided for them: their alias and import stamps, route and retained
  # environment were computed where the mutator found them, and a direct call desugared from a
  # pipe presumes the `|>` was `Kernel`'s, when the replacement may import another. Read as
  # the region's resolution, any of these stands in for what the compiler reads from the
  # patch. So a mutant's preserved region is returned as the source it spells — every
  # desugared pipe written again, every resolution stamp dropped (`for_resolution/1`, at each node)
  # — and the readers find what a reparse of that source would give them. Nothing is
  # resolved, desugared, or classified inside: the route that kept the region still bounds
  # the walk.
  @spec preserve_written(Macro.t()) :: Macro.t()
  def preserve_written(syntax), do: Macro.prewalk(syntax, &unresolved/1)

  # A remote head's module stamp is dropped with its call (`invalidate_call_resolution/1`); an `__aliases__`
  # outside a call head (a `defmodule`'s) carries one too.
  defp unresolved({:__aliases__, meta, path}) when is_list(meta),
    do: {:__aliases__, Keyword.delete(meta, MetaKeys.alias_key()), path}

  defp unresolved({_form, meta, args} = node) when is_list(meta) and is_list(args),
    do: for_resolution(node)

  defp unresolved(node), do: node

  # Release every retained environment. A call's meta carries it, and a meta is carried
  # inside other metas — a desugared pipe's written spelling, a grouped prefix's
  # continuation and grouping history (`Mutare.Transform.WrittenPipe`) — so from a meta the
  # walk continues into whatever the meta holds, dropping the `{key, env}` pair from every
  # list it meets there, until it reaches a node again (a continuation holds the remaining
  # stages). A node's arguments are program data, where the same pair is a keyword a mutator
  # built and the metamutant must return (a source keyword's key is a literal node, never
  # the bare atom; a mutator's `quote` makes it the atom); only a node's meta is Mutare's.
  # The environment is dropped before it could be descended into.
  @doc false
  @spec release_analysis(Macro.t()) :: Macro.t()
  def release_analysis({form, meta, args}) when is_list(meta),
    do: {release_analysis(form), release_analysis_meta(meta), release_analysis(args)}

  def release_analysis({left, right}), do: {release_analysis(left), release_analysis(right)}
  def release_analysis(list) when is_list(list), do: Enum.map(list, &release_analysis/1)
  def release_analysis(leaf), do: leaf

  defp release_analysis_meta(meta),
    do: for(item <- meta, not retained_pair?(item), do: release_analysis_carried(item))

  defp retained_pair?({key, _env}), do: key == MetaKeys.resolution_key()
  defp retained_pair?(_item), do: false

  defp release_analysis_carried({_form, meta, _args} = node) when is_list(meta),
    do: release_analysis(node)

  defp release_analysis_carried(list) when is_list(list), do: release_analysis_meta(list)

  defp release_analysis_carried(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&release_analysis_carried/1) |> List.to_tuple()

  defp release_analysis_carried(leaf), do: leaf
end
