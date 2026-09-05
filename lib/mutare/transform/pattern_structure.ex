defmodule Mutare.Transform.PatternStructure do
  @moduledoc false

  # Shared helpers for the structural pattern mutators (`Mutare.Mutators.PatternSwap` /
  # `Mutare.Mutators.PatternWildcard`), which restructure a *whole pattern* rather than a
  # single node. Two delivery paths use them, so the discovery primitives live here once:
  #
  #   * `def`/`defp` *head* patterns — lifted (`Mutare.Transform.FunctionPlan`).
  #   * `case` *clause* patterns — wrapped in an in-place selector (`Mutare.Transform`).
  #
  # The two differ only in *delivery*; "which mutators participate", "which names are read
  # outside the pattern", and "run a mutator over a single pattern node" are identical.

  @doc """
  The enabled mutator specs that implement the structural `pattern_mutations` hook — at
  either arity (`/2`, or the context-aware `/3`).
  """
  @spec mutators([Mutare.Mutator.Spec.t()]) :: [Mutare.Mutator.Spec.t()]
  def mutators(enabled),
    do: Mutare.Mutator.Dispatch.implementing_any(enabled, :pattern_mutations, [2, 3])

  @doc """
  The variable names read in `ast` (a node or a list of nodes) — the `used_outside` set a
  structural mutator needs so it never strands a binding. **Over-collects** (any
  `{name, _, ctx}` with an atom `ctx`, including a mere rebinding), which is the safe
  direction: it can only make a mutator keep a binding it didn't need, never remove one a
  body reads (which would be an unbound-variable hard error).
  """
  @spec used_names(Macro.t() | [Macro.t()]) :: MapSet.t()
  def used_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  @doc """
  How many times each variable-shaped name *occurs* in `pattern` — every position, not
  just bindings: a repeated binding (`{a, a}`), a bitstring size read (`<<n, r::size(n)>>`),
  a pin (`{a, ^a}`). The `used_names/1` counterpart that keeps *counts*, not a set.

  The `=`-match rewrite repeats each bound variable this many times in its export tuple, so
  a variable the source self-used (repetition / a size read suppresses Elixir's "unused
  variable" warning) keeps that self-use in the rebind — `{a, a} = …`, not `{a} = …` — and
  doesn't gain a spurious warning the original never had. Over-counts harmlessly: a type
  atom (`binary`) or any non-bound name is counted but never exported.
  """
  @spec occurrence_counts(Macro.t()) :: %{atom() => pos_integer()}
  def occurrence_counts(pattern) do
    {_ast, counts} =
      Macro.prewalk(pattern, %{}, fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, Map.update(acc, name, 1, &(&1 + 1))}

        node, acc ->
          {node, acc}
      end)

    counts
  end

  @doc """
  Structural mutations of a *single* pattern node, as `{mutator, mutated_pattern}` pairs.

  The `pattern_mutations/2` contract takes the argument *list* of a head and never changes
  its length, so a lone pattern is wrapped as a one-element list and the single mutated
  element unwrapped — letting the `case` path reuse the exact same mutators as the def-head
  path, which works on the full arg list directly.
  """
  @spec node_mutations(Macro.t(), MapSet.t(), [Mutare.Mutator.Spec.t()]) ::
          [{Mutare.Mutator.Spec.t(), Macro.t()}]
  def node_mutations(pattern, used_outside, structural_mutators) do
    # A pattern holding a `:skip`-routed head (`"a" <> rest`, `-1` — the literal forms themselves
    # are not routable) is not restructured at all: the skipped head is an inert leaf, and a swap
    # or wildcard across it would mutate inside it. Conservative on purpose, and a contract guard:
    # the built-in families never restructure across such a head, a custom `pattern_mutations/2`
    # might. The literal walk still mutates beside it.
    if Mutare.Transform.Meta.contains_skipped?(pattern) do
      []
    else
      Enum.flat_map(structural_mutators, fn mutator ->
        mutator
        |> Mutare.Mutator.Dispatch.pattern_mutations([pattern], used_outside)
        |> Enum.flat_map(fn
          [mutated] -> [{mutator, mutated}]
          _other -> []
        end)
      end)
    end
  end

  @doc """
  The name of a plain variable node, or `nil`. A plain variable is `{name, _meta, ctx}`
  with an atom `name` and an atom `ctx` (`nil` or a module); `_`, `_`-prefixed names
  (intentionally ignored), and pins (`^x`, whose ctx is a list) are excluded. The strict
  "is this a swappable / wildcardable variable" notion both structural families share.
  """
  @spec var_name(Macro.t()) :: atom() | nil
  def var_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    string = Atom.to_string(name)
    if name == :_ or String.starts_with?(string, "_"), do: nil, else: name
  end

  def var_name(_node), do: nil

  @doc """
  The distinct variable names a pattern **binds**, in first-occurrence order.

  Unlike `used_names/1` (which over-collects every variable-shaped node, the safe
  direction for a *used-outside* set), this is the **exact** binding set — what the
  `=`-match rewrite re-exports through a tuple and rebinds in the outer scope (see
  `Mutare.Transform`). It must be precise in *both* directions: over-collecting binds
  a name the pattern never introduced (an unbound-variable error in the export tuple);
  under-collecting strands a binding the rest of the scope reads. So binding positions
  are classified positively, the way the in-place analyzer classifies contexts:

    * a pin `^x` binds nothing (it *references* an outer binding) — skipped whole;
    * a module-attribute read `@tag` is a compile-time literal, not a binding — skipped whole;
    * a map/struct **key** is an expression matched against, not a binding — only the
      *value* side of each pair is descended (`%{k => v}` binds `v`, never `k`);
    * a bitstring **spec** (`size(n)`, type atoms) references/declares no new binding —
      only the *value* side of a `::` segment is descended;
    * bare `_` binds nothing usable and is dropped — but an underscore-*prefixed* name
      (`_x`) **is** a real binding the rest of the scope can read, so it is kept (this is
      why `var_name/1`, which drops `_`-prefixed names for a swap *target*, is *not*
      reused here — omitting `_x` would leave it undefined after the rewrite).

  Everything else — tuples, lists (incl. cons tails), nested matches (`x = pat`) — is a
  structural descent. The result threads `Mutare.Transform`'s export tuple and outer
  match, so its order/uniqueness is what keeps the two consistent.
  """
  @spec bound_var_names(Macro.t()) :: [atom()]
  def bound_var_names(pattern) do
    pattern |> collect_bound([]) |> Enum.reverse() |> Enum.uniq()
  end

  # A pin references an outer binding — it introduces nothing.
  defp collect_bound({:^, _meta, _args}, acc), do: acc

  # A module-attribute read is a compile-time literal in a pattern. Its inner AST node has
  # variable shape (`{:tag, meta, ctx}`), but `tag` is not introduced by the pattern.
  defp collect_bound({:@, _meta, _args}, acc), do: acc

  # A bitstring segment `value :: spec`: only the value side binds (the spec's type
  # atoms / `size(n)` references declare no new binding).
  defp collect_bound({:"::", _meta, [value, _spec]}, acc), do: collect_bound(value, acc)

  # A map/struct field map: keys are matched-against expressions, not bindings — descend
  # only each pair's value. (`%Struct{…}` reaches here via the generic clause's descent
  # into its inner `%{}`.)
  defp collect_bound({:%{}, _meta, pairs}, acc) when is_list(pairs) do
    Enum.reduce(pairs, acc, fn
      {_key, value}, acc -> collect_bound(value, acc)
      other, acc -> collect_bound(other, acc)
    end)
  end

  # A plain variable in binding position — the one place a name is introduced. Bare `_`
  # binds nothing usable and is dropped; an underscore-*prefixed* name (`_x`) is a real
  # binding the rest of the scope can still read, so it MUST be exported. (This is why we
  # can't reuse `var_name/1`, which also drops `_`-prefixed names — for a *swap/wildcard
  # target* that's right, but for the *export set* omitting `_x` leaves it undefined after
  # the rewrite, a compile error rather than a mere unused warning.)
  defp collect_bound({:_, _meta, ctx}, acc) when is_atom(ctx), do: acc

  defp collect_bound({name, _meta, ctx}, acc) when is_atom(name) and is_atom(ctx),
    do: [name | acc]

  # Any other operator/container node (tuple `{:{}, …}`, struct `%S{}`, nested `=`, …):
  # descend its args structurally.
  defp collect_bound({_form, _meta, args}, acc) when is_list(args),
    do: Enum.reduce(args, acc, &collect_bound/2)

  # A literal 2-tuple `{a, b}` (Sourceror leaves these unwrapped).
  defp collect_bound({a, b}, acc), do: collect_bound(b, collect_bound(a, acc))

  defp collect_bound(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_bound/2)

  defp collect_bound(_leaf, acc), do: acc

  @doc """
  The variable-shaped names appearing in any bitstring **spec** (the right of `::`)
  within `ast` — the `n` in `<<n, rest::binary-size(n)>>`, plus bare type atoms like
  `integer` (indistinguishable from a variable in the AST). The structural families
  exclude a value with such a name from swapping / wildcarding; over-collecting type
  atoms is the safe direction — it can only decline a mutation, never produce an illegal
  one (an `<<v::_>>` specifier) or strand a binding.
  """
  @spec spec_var_names(Macro.t()) :: MapSet.t()
  def spec_var_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:"::", _meta, [_value, spec]} = node, acc -> {node, collect_var_names(spec, acc)}
        node, acc -> {node, acc}
      end)

    names
  end

  defp collect_var_names(spec, acc) do
    {_ast, names} =
      Macro.prewalk(spec, acc, fn node, acc ->
        case var_name(node) do
          nil -> {node, acc}
          name -> {node, MapSet.put(acc, name)}
        end
      end)

    names
  end
end
