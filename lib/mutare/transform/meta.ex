defmodule Mutare.Transform.Meta do
  @moduledoc false
  # The read/write surface for the internal `:mutare_*` annotations the transform stamps onto an
  # AST node's `meta` keyword list. Two families of metadata cross module boundaries, and both
  # used to be reached with hand-written `Keyword.get(meta, :mutare)` / `[{:mutare_tag, t} | meta]`
  # literals scattered across the analyze and emit modules — a silent-drift hazard the key
  # registry (`Mutare.Transform.MetaKeys`) alone can't close, because nothing forces a call site to
  # go through it. This module *is* that forcing function: it owns the operations, names every key
  # only through `MetaKeys`, and is the single thing any other module calls. AST metadata is then
  # an implementation detail — rename a key in `MetaKeys` and every operation follows; no module
  # outside here and `MetaKeys` spells a `:mutare_*` atom.
  #
  #   * **candidate delivery** — the lists of `Mutare.Transform.Candidate` structs an emit path
  #     consumes, keyed by *logical kind* (`:in_place`/`:case`/`:hosted`) so the API never exposes
  #     the raw delivery atom. `candidates/2`, `put_candidates/3`, `append_candidates/3`,
  #     `take_candidates/2`, `update_candidates/3`, and `strip_delivery/1`.
  #   * **call-routing stamps** — the routing `Mutare.Transform.Resolve` writes and
  #     the analyzer reads (`:mutare_route`/`:mutare_route_piped`/`:mutare_route_call`), the one
  #     resolution family that was being read by raw literal in several modules. Typed reader/writer
  #     per stamp.
  #   * **tag** — the replace-by-tag discovery marker (`:mutare_tag`), which had no `MetaKeys`
  #     accessor at all and was the worst offender: read *and* written by raw literal in
  #     `Mutare.Transform.Tag`.
  #
  # The remaining resolution stamps (`alias`/`import`/`witness`/`kernel_displaced`/`nid`/
  # `behaviours`/`use_*`) already have typed readers/writers in their cohesive owning modules
  # (`Aliases`/`Imports`/`Resolve.NodeIds`/`Behaviours`/`Uses`), each naming its key through a
  # `MetaKeys` accessor — so they are drift-safe and stay there; only the cross-cutting and
  # raw-literal families move here.
  #
  # Every function is **total** over a bare literal node (a node with no keyword metadata):
  # readers return the empty/`nil` default, writers return the node unchanged. So a caller walking
  # mixed AST never needs its own shape guard.

  alias Mutare.Transform.MetaKeys

  # The full delivery-key list, frozen at compile time for the hot `strip_delivery/1` path.
  @delivery_keys MetaKeys.delivery()

  @typedoc "A logical candidate-delivery kind, mapped to its meta key by `MetaKeys`."
  @type kind :: :in_place | :case | :hosted

  # --- candidate delivery ----------------------------------------------------

  @doc """
  The candidate list a node carries for `kind`, or `[]` for a bare literal or an absent key.

  The three kinds (`:in_place`/`:case`/`:hosted`) each drive a different emit but share this read.
  """
  @spec candidates(Macro.t(), kind()) :: [struct()]
  def candidates({_form, meta, _args}, kind) when is_list(meta),
    do: Keyword.get(meta, delivery_key(kind), [])

  def candidates(_node, _kind), do: []

  @doc """
  Set `kind`'s candidate list, replacing any already present.

  An empty list **removes** the key (so an emptied list is indistinguishable from an absent one —
  the meta stays minimal). A bare literal node is returned unchanged.
  """
  @spec put_candidates(Macro.t(), kind(), [struct()]) :: Macro.t()
  def put_candidates({form, meta, args}, kind, []) when is_list(meta),
    do: {form, Keyword.delete(meta, delivery_key(kind)), args}

  def put_candidates({form, meta, args}, kind, candidates) when is_list(meta),
    do: {form, Keyword.put(meta, delivery_key(kind), candidates), args}

  def put_candidates(node, _kind, _candidates), do: node

  @doc """
  Append `candidates` to `kind`'s list, **preserving** any already there (so an operator candidate
  keeps its id before a return/condition one at a shared node). A bare literal node, or an empty
  append, is a no-op.
  """
  @spec append_candidates(Macro.t(), kind(), [struct()]) :: Macro.t()
  def append_candidates(node, kind, candidates),
    do: put_candidates(node, kind, candidates(node, kind) ++ candidates)

  @doc """
  Pop `kind`'s candidates off a node: `{candidates, node_without_key}`. `{[], node}` for a bare
  literal or an absent key.
  """
  @spec take_candidates(Macro.t(), kind()) :: {[struct()], Macro.t()}
  def take_candidates({form, meta, args}, kind) when is_list(meta) do
    key = delivery_key(kind)
    {Keyword.get(meta, key, []), {form, Keyword.delete(meta, key), args}}
  end

  def take_candidates(node, _kind), do: {[], node}

  @doc """
  Apply `fun` to `kind`'s candidate list in place, splicing the result back. A **no-op** (the node
  is returned unchanged) when the key is absent — so a caller that only ever narrows (`Enum.reject`)
  or re-flags (`Enum.map`) an existing list needs no nil/shape handling of its own.
  """
  @spec update_candidates(Macro.t(), kind(), ([struct()] -> [struct()])) :: Macro.t()
  def update_candidates({form, meta, args} = node, kind, fun) when is_list(meta) do
    key = delivery_key(kind)

    case Keyword.fetch(meta, key) do
      {:ok, candidates} -> {form, Keyword.put(meta, key, fun.(candidates)), args}
      :error -> node
    end
  end

  def update_candidates(node, _kind, _fun), do: node

  @doc """
  Drop **every** candidate-delivery key from a node, leaving its other metadata. The emit-time
  scrub run once a node's candidates are consumed and before the bare node is rebuilt. Total over a
  bare literal.
  """
  @spec strip_delivery(Macro.t()) :: Macro.t()
  def strip_delivery({form, meta, args}) when is_list(meta),
    do: {form, Keyword.drop(meta, @delivery_keys), args}

  def strip_delivery(node), do: node

  defp delivery_key(:in_place), do: MetaKeys.in_place_key()
  defp delivery_key(:case), do: MetaKeys.case_key()
  defp delivery_key(:hosted), do: MetaKeys.hosted_key()

  # --- call-routing stamps ---------------------------------------------------

  @doc """
  The routing `Mutare.Transform.Resolve` stamped on a call the route registry matched
  (`Mutare.CallRouting.Registry`): the per-argument position list, or the bare `:skip` for a call
  routed as an inert leaf. `nil` for an unrouted call. The reader of the `:mutare_route` contract key.
  """
  @spec routing(keyword() | term()) :: term()
  def routing(meta) when is_list(meta), do: Keyword.get(meta, MetaKeys.route_key())
  def routing(_meta), do: nil

  @doc """
  Whether a node carries the call-level `:skip` route — an inert leaf to every walk: the
  `Mutare.Transform.Analyze` dispatcher, `Mutare.Transform.Tag`'s guard and pattern walks, and
  the structural pattern discovery (through `contains_skipped?/1`).
  """
  @spec skipped?(Macro.t()) :: boolean()
  def skipped?({_form, meta, args}) when is_list(meta) and is_list(args),
    do: routing(meta) == :skip

  def skipped?(_node), do: false

  @doc """
  Whether `ast` (a node or a list of nodes) holds a `:skip`-routed node anywhere, itself
  included. The structural pattern families restructure a *whole* pattern, so a pattern holding
  a skipped form is not offered to them at all (`Mutare.Transform.PatternStructure`).
  """
  @spec contains_skipped?(Macro.t() | [Macro.t()]) :: boolean()
  def contains_skipped?(ast) do
    {_ast, found} = Macro.prewalk(ast, false, fn node, acc -> {node, acc or skipped?(node)} end)
    found
  end

  @doc """
  The piped-value routing for a known-macro `|>` RHS (`:mutare_route_piped`), stamped only when the
  effective-argument-0 treatment isn't the `:expression` default — so the common runtime LHS
  carries no stamp and this reads `nil`.
  """
  @spec piped_routing(keyword() | term()) :: term()
  def piped_routing(meta) when is_list(meta),
    do: Keyword.get(meta, MetaKeys.piped_route_key())

  def piped_routing(_meta), do: nil

  @doc """
  The resolved `{module_key, name}` macro identity stamped on a call (`:mutare_route_call`), or
  `nil` when the node was never matched against the macro registry. Read by
  `Mutare.Transform.Calls.resolved_routed_call/1`.
  """
  @spec routed_call(keyword() | term()) :: term()
  def routed_call(meta) when is_list(meta), do: Keyword.get(meta, MetaKeys.route_call_key())
  def routed_call(_meta), do: nil

  @doc "Stamp visible-argument macro routing onto a call's meta (`:mutare_route`)."
  @spec stamp_routing(keyword(), term()) :: keyword()
  def stamp_routing(meta, routing), do: [{MetaKeys.route_key(), routing} | meta]

  @doc "Stamp the piped-value routing onto a piped known-macro stage's meta (`:mutare_route_piped`)."
  @spec stamp_piped_routing(keyword(), term()) :: keyword()
  def stamp_piped_routing(meta, routing),
    do: [{MetaKeys.piped_route_key(), routing} | meta]

  @doc "Stamp the resolved `{module_key, name}` macro identity onto a call's meta (`:mutare_route_call`)."
  @spec stamp_routed_call(keyword(), term()) :: keyword()
  def stamp_routed_call(meta, identity), do: [{MetaKeys.route_call_key(), identity} | meta]

  # --- replace-by-tag discovery marker ---------------------------------------

  @doc """
  The replace-by-tag marker (`:mutare_tag`) on a node, or `nil` for a bare literal or an unmarked
  node. `Mutare.Transform.Tag` walks a guard/pattern stamping a unique tag per mutatable node, then
  materialises one mutant by matching it.
  """
  @spec tag(Macro.t()) :: term()
  def tag({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, MetaKeys.tag_key())
  def tag(_node), do: nil

  @doc "Stamp the replace-by-tag marker `tag` onto a node (`:mutare_tag`); total over a bare literal."
  @spec put_tag(Macro.t(), term()) :: Macro.t()
  def put_tag({form, meta, args}, tag) when is_list(meta),
    do: {form, [{MetaKeys.tag_key(), tag} | meta], args}

  def put_tag(node, _tag), do: node

  @doc "Remove the replace-by-tag marker from a node; total over a bare literal or an untagged node."
  @spec delete_tag(Macro.t()) :: Macro.t()
  def delete_tag({form, meta, args}) when is_list(meta),
    do: {form, Keyword.delete(meta, MetaKeys.tag_key()), args}

  def delete_tag(node), do: node

  # --- mutator-requested position marks --------------------------------------

  @doc """
  The set of position-mark labels stamped on a node (`:mutare_marks`), or an empty set for an
  unmarked node or a bare literal. Stamped by `Mutare.Transform.Resolve.ArgumentMarks` at a position
  some enabled mutator asked to mark (`c:Mutare.Mutator.argument_marks/1`) and surfaced to the
  mutators as `context.marks` by `Mutare.Transform.Analyze.Attach.offer/4`.
  """
  # A shared empty set so the common *unmarked* node — every node but the few a mutator asked to
  # mark — costs no allocation on the per-node offer path (the scan is heap-sensitive; NOTES "Scan
  # is transform-bound").
  @empty_marks MapSet.new()

  @spec marks(Macro.t()) :: MapSet.t(atom())
  def marks({_form, meta, _args}) when is_list(meta),
    do: Keyword.get(meta, MetaKeys.marks_key(), @empty_marks)

  def marks(_node), do: @empty_marks

  @doc """
  Add `labels` (an enumerable of atoms) to a node's position-mark set (`:mutare_marks`), unioning
  with any already present. Total over a bare literal that carries no metadata (nothing to stamp).
  """
  @spec add_marks(Macro.t(), Enumerable.t()) :: Macro.t()
  def add_marks({form, meta, args}, labels) when is_list(meta) do
    merged =
      MapSet.union(Keyword.get(meta, MetaKeys.marks_key(), MapSet.new()), MapSet.new(labels))

    {form, [{MetaKeys.marks_key(), merged} | Keyword.delete(meta, MetaKeys.marks_key())], args}
  end

  def add_marks(node, _labels), do: node

  @doc """
  The `{module_key, fun, effective_arity}` of a call some argument-mark declaration matched
  (`:mutare_mark_call`), or `nil`. Stamped by `Mutare.Transform.Resolve` on the call node (and on a
  pipe's RHS when a receiver mark applied) purely so `Mutare.Transform.ConfigMatches` can tell which
  configured `argument_marks:` entries reached a call — the ineffective-entry diagnostic.
  """
  @spec mark_call(keyword() | term()) :: term()
  def mark_call(meta) when is_list(meta), do: Keyword.get(meta, MetaKeys.mark_call_key())
  def mark_call(_meta), do: nil

  @doc "Stamp the matched mark-declaration key onto a call's meta (`:mutare_mark_call`)."
  @spec stamp_mark_call(keyword(), term()) :: keyword()
  def stamp_mark_call(meta, key) when is_list(meta), do: [{MetaKeys.mark_call_key(), key} | meta]

  @doc """
  The dispatch `context` enriched with `node`'s position marks (`marks/1`) under `:marks`, or the
  context unchanged when the node carries none.

  The single definition of "surface a node's marks to the mutators as `context.marks`", so both
  paths that offer a node to the mutator set agree: the in-place offer
  (`Mutare.Transform.Analyze.Attach.offer/4`) and the tag-based guard/pattern dispatch
  (`Mutare.Transform.Tag`). The empty-set short-circuit keeps the overwhelmingly common *unmarked*
  node off the `Map.put` path (the scan is heap-sensitive; NOTES "Scan is transform-bound").
  """
  @spec context_with_marks(map(), Macro.t()) :: map()
  def context_with_marks(context, node) do
    marks = marks(node)
    if MapSet.size(marks) == 0, do: context, else: Map.put(context, :marks, marks)
  end
end
