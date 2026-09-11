defmodule Mutare.Transform.Render do
  @moduledoc false

  alias Mutare.AST
  alias Mutare.Transform.Meta

  # Sourceror rendering workarounds for the metamutant, kept apart from the
  # semantic transform. The metamutant is a throwaway build artifact that only
  # has to *compile* — these helpers exist solely to get `Sourceror.to_string`
  # to accept the rewritten tree. The diff report patches the original source and
  # never touches any of this.

  @doc """
  Render the annotated metamutant AST to source.

  Strips the analyzer's internal annotations, flips keyword-format keys back to
  plain atoms (a `Sourceror` formatter workaround), then renders. Metamutant
  only.
  """
  def to_source(ast) do
    ast
    |> strip_annotations()
    |> normalize_keyword_blocks()
    |> normalize_for_options()
    |> Sourceror.to_string(Mutare.AST.render_opts())
  end

  @doc """
  Wrap a node in a single-expression block so it renders safely in any position.

  A bare `case` used directly as a `key: value` value crashes Sourceror's
  formatter; the surrounding `{:__block__, [], [node]}` makes it render fine
  everywhere (e.g. an in-place selector replacing a `def f, do: <expr>` value).
  """
  def block_wrap(node), do: {:__block__, [], [node]}

  @doc """
  Build a selector `case` — `case <subject> do <clauses> end` — `block_wrap/1`ped so
  it renders safely in any position, and marked as emit-built (`Meta.put_selector/1`).

  This and `selector_case_parts/1` are the single home for the selector shape. The one
  reader that must reach back into a just-built selector (`Mutare.Transform.PipeEmit.hoist/2`,
  which lifts the `case` out of an illegal pipe-RHS position) recognises it by the marker
  this builder stamps, not by reconstructing its shape — so a user's own `case` can never be
  mistaken for one, and the two can't drift apart silently (a mismatch would yield an
  uncompilable metamutant with no error pointing back here). The marker is internal node
  metadata, stripped with the rest before rendering.
  """
  def selector_case(subject, clauses),
    do: block_wrap(Meta.put_selector({:case, [], [subject, [do: clauses]]}))

  @doc """
  Destructure a node built by `selector_case/2` into `{:ok, subject, clauses}`, or
  `:error` for anything else — including a `case` of the same shape the emit did not build.
  The inverse of `selector_case/2`.
  """
  def selector_case_parts({:__block__, _bmeta, [{:case, _cmeta, [subject, [do: clauses]]} = c]}) do
    if Meta.selector?(c), do: {:ok, subject, clauses}, else: :error
  end

  def selector_case_parts(_node), do: :error

  # Sourceror represents keyword-syntax keys (`do:`, `else:`, but also `ms:`,
  # `env:`, any `key: value`) as `{:__block__, [format: :keyword], [key]}`. A
  # block-wrapped pair key left in a list renders as invalid `key => value`
  # syntax, so unwrap every single-expression block key and let Sourceror render
  # the surrounding pair as either `key: value` or `{key, value}`.
  defp normalize_keyword_blocks(ast) do
    Macro.prewalk(ast, fn
      {{:__block__, _meta, [key]}, value} ->
        {key, value}

      other ->
        other
    end)
  end

  # Once keyword-syntax keys are unwrapped, Sourceror may choose the block form for
  # a for expression. If the original keyword list put do: before another
  # comprehension option, such as into:, that block rendering becomes invalid
  # because into is emitted inside the body. The metamutant only needs compiling
  # source, so canonicalize the final option list to keep all options before do:.
  # Only the final argument is touched; earlier list arguments can be ordinary
  # qualifiers or filters.
  defp normalize_for_options(ast) do
    Macro.prewalk(ast, fn
      {:for, meta, args} when is_list(args) ->
        {:for, meta, normalize_for_args(args)}

      other ->
        other
    end)
  end

  defp normalize_for_args([]), do: []

  defp normalize_for_args(args) do
    {prefix, [last]} = Enum.split(args, -1)
    prefix ++ [normalize_for_option_list(last)]
  end

  defp normalize_for_option_list(opts) when is_list(opts) do
    if Enum.all?(opts, &match?({_key, _value}, &1)) and Enum.any?(opts, &do_option?/1) do
      {do_options, other_options} = Enum.split_with(opts, &do_option?/1)
      other_options ++ do_options
    else
      opts
    end
  end

  defp normalize_for_option_list(other), do: other

  defp do_option?({key, _value}), do: AST.key_atom(key) == :do
  defp do_option?(_other), do: false

  # Remove the analyzer's internal annotations before rendering — every `:mutare_*` node-meta
  # key is bookkeeping that must never reach the source. The canonical list (and what each key
  # means) lives in `Mutare.Transform.MetaKeys`, so this scrub can't drift from the stamp sites.
  @internal_meta_keys Mutare.Transform.MetaKeys.all()

  defp strip_annotations(ast) do
    Macro.prewalk(ast, fn
      # Equivalent: stripping is belt-and-suspenders — any leftover annotation metadata
      # never reaches the rendered source (Sourceror ignores unknown meta keys).
      # mutare:ignore[pattern_swap] form/meta swap only flips which binding is_list tests
      {form, meta, args} when is_list(meta) ->
        {form, Keyword.drop(meta, @internal_meta_keys), args}

      other ->
        other
    end)
  end
end
