defmodule Mutare.Mutators.Helpers do
  @moduledoc false

  # Shared building blocks for the built-in mutator families. Not a mutator itself
  # (no `@behaviour`, not in the `Mutare.Mutators` registry) — just the logic several
  # families would otherwise copy.

  alias Mutare.Mutator.Mutation
  alias Mutare.Transform.{Calls, Imports}

  @doc """
  Combine two mutation callback results, preserving the public `:skip | list` shape.

  Used by mutators that intentionally compose a context-free helper with a
  context-aware branch under the `mutate/2`-over-`mutate/1` dispatch rule.
  """
  @spec combine_mutations(
          :skip | [Mutare.Mutator.mutation()],
          :skip | [Mutare.Mutator.mutation()]
        ) ::
          :skip | [Mutare.Mutator.mutation()]
  def combine_mutations(left, right) do
    case mutation_list(left) ++ mutation_list(right) do
      [] -> :skip
      mutations -> mutations
    end
  end

  @doc """
  Rename a resolved call by looking its `{module, fun}` up in a swap `table`.

  The single shape behind the "swap-table" families (`Collection`, `Integer`,
  `MapKeyword`, `Numeric`'s qualified arm): resolve the call through
  `Mutare.Transform.Calls` (so a direct, aliased, or bare-imported form all match),
  look up `{module, fun}`, and rebuild the call with the new function name. The
  table value is the new function name, or a **list** of names (several siblings →
  several mutants). `rebuild` reuses the call's written module node, so the swap
  stays within the module (an aliased `S.upcase` mutates to `S.downcase`, not
  `String.downcase`).

  Returns `:skip` when the node isn't a resolved call, or its `{module, fun}` isn't
  in the table.
  """
  @spec swap_call(Macro.t(), %{optional({Calls.module_key(), atom()}) => atom() | [atom()]}) ::
          [Macro.t()] | :skip
  def swap_call(node, table), do: swap_resolved(Calls.resolved_call(node), table)

  @doc """
  The swap-table lookup over an **already-resolved** call (the
  `{module, fun, args, rebuild}` tuple `Mutare.Transform.Calls.resolved_call/1` returns,
  or `nil`). The body of `swap_call/2`, exposed so a family that resolves the call once for
  its own special-casing (`StringCall`'s `String.equivalent?`, `Math`'s `:math.pi`) can run
  the fall-through swap without resolving a second time. Returns `:skip` for an unresolved
  call or a `{module, fun}` absent from `table`.
  """
  @spec swap_resolved(
          {Calls.module_key(), atom(), [Macro.t()], function()} | nil,
          %{optional({Calls.module_key(), atom()}) => atom() | [atom()]}
        ) :: [Macro.t()] | :skip
  def swap_resolved({module, fun, args, rebuild}, table) do
    case Map.fetch(table, {module, fun}) do
      {:ok, new_funs} -> new_funs |> List.wrap() |> Enum.map(&rebuild.(&1, args))
      :error -> :skip
    end
  end

  def swap_resolved(_unresolved, _table), do: :skip

  @doc """
  Resolve a call, compute its **effective** arity (pipe-aware), and look
  `{module, fun, effective_arity}` up in an arity-keyed `rules` map.

  The arity-sensitive counterpart of `swap_call/2`'s `{module, fun}` lookup — the shared
  skeleton behind the arity-keyed call families (`CollectionArity`, `DefaultDrop`,
  `ModeSwap`). Returns `{:ok, rule, {module, fun, args, rebuild}}` — the matched table value
  plus the resolved call (the same shape `Mutare.Transform.Calls.resolved_call/1` returns), so
  a family can read whichever parts it needs (the rule, the args, the rebuilder, or the kept
  `fun` for a same-name swap) — or `:skip` when the node isn't a resolved call or its
  `{module, fun, arity}` isn't in `rules`.
  """
  @spec lookup_resolved_arity(
          Macro.t(),
          Mutare.Mutator.pipe_mode(),
          %{optional({Calls.module_key(), atom(), arity()}) => term()}
        ) :: {:ok, term(), {Calls.module_key(), atom(), [Macro.t()], function()}} | :skip
  def lookup_resolved_arity(node, pipe_mode, rules) do
    with {module, fun, args, rebuild} <- Calls.resolved_call(node),
         eff_arity = Mutare.Mutator.effective_arity(args, pipe_mode),
         {:ok, rule} <- Map.fetch(rules, {module, fun, eff_arity}) do
      {:ok, rule, {module, fun, args, rebuild}}
    else
      _ -> :skip
    end
  end

  @doc """
  Swap a **bare `Kernel`** call for a sibling, gated on effective arity — pipe-aware.

  The bare-`Kernel` counterpart of `swap_call/2`: a bare `min`/`abs`/`div`/… has no module
  to prove it is the `Kernel` one (`Mutare.Transform.Calls` only resolves *qualified*/
  aliased/imported calls), so the sole evidence is its **effective** arity
  (`Mutare.Mutator.effective_arity/2` — one higher when piped, since a pipe stage's node
  carries one fewer arg than the source reads). Look `{fun, effective_arity}` up in `table`
  (so a same-named user function at another arity is never touched) and rebuild the call with
  each sibling name, keeping the argument list. A call displaced from `Kernel` by `import
  Kernel, except:/only:` (`Mutare.Transform.Imports`) names *another* module's function, so
  it is skipped — the swap would otherwise rewrite a user function to a sibling that may not
  exist (poisoning the single build) or mean something else.

  `table` maps `{function, effective_arity}` to a sibling name, or a **list** of names
  (several siblings → several mutants). The single home for the bare-`Kernel` swap that
  `Mutare.Mutators.Numeric` (`min`/`max`/rounding) and `Mutare.Mutators.Arithmetic`
  (`div`/`rem`) share. Returns `:skip` when the node isn't a bare call, is displaced, or its
  `{fun, arity}` isn't in the table.
  """
  @spec swap_bare_kernel(
          Macro.t(),
          Mutare.Mutator.pipe_mode(),
          %{optional({atom(), arity()}) => atom() | [atom()]}
        ) :: [Macro.t()] | :skip
  def swap_bare_kernel({fun, meta, args}, pipe_mode, table)
      when is_atom(fun) and is_list(args) do
    eff_arity = Mutare.Mutator.effective_arity(args, pipe_mode)

    with false <- Imports.kernel_displaced?(meta),
         {:ok, siblings} <- Map.fetch(table, {fun, eff_arity}) do
      siblings |> List.wrap() |> Enum.map(&{&1, meta, args})
    else
      _ -> :skip
    end
  end

  def swap_bare_kernel(_node, _pipe_mode, _table), do: :skip

  @doc """
  Remove a **bare `Kernel`** call, gated on effective arity — pipe-aware.

  The removal twin of `swap_bare_kernel/3` (and the bare-`Kernel` counterpart of
  `remove_call/3`): a bare `abs`/`binary_slice`/… has no module to prove it is the `Kernel`
  one, so its **effective** arity (`Mutare.Mutator.effective_arity/2` — one higher when piped,
  since a pipe stage's node carries one fewer arg than the source reads) is the sole evidence.
  When `{fun, effective_arity}` is in the `removable` set and the call isn't displaced from
  `Kernel` by `import Kernel, except:/only:` (`Mutare.Transform.Imports`), drop it via
  `removed_call/2` (the shared first-arg / `Function.identity` mechanic). `removable` is a
  `MapSet` of `{function, effective_arity}` pairs. Returns `:skip` when the node isn't a bare
  call, is displaced, or its `{fun, arity}` isn't removable.
  """
  @spec remove_bare_kernel(Macro.t(), Mutare.Mutator.pipe_mode(), MapSet.t({atom(), arity()})) ::
          [Macro.t()] | :skip
  def remove_bare_kernel({fun, meta, args}, pipe_mode, removable)
      when is_atom(fun) and is_list(args) do
    eff_arity = Mutare.Mutator.effective_arity(args, pipe_mode)

    with false <- Imports.kernel_displaced?(meta),
         true <- MapSet.member?(removable, {fun, eff_arity}) do
      removed_call(pipe_mode, args)
    else
      _ -> :skip
    end
  end

  def remove_bare_kernel(_node, _pipe_mode, _removable), do: :skip

  @doc """
  Remove a *transparent transform* call — pipe-aware.

  The "call removal" counterpart of `swap_call/2`: resolve `node` through
  `Mutare.Transform.Calls` (so a direct, aliased, or bare-imported form all match)
  and, when its `{module, fun}` is in the `removable` set, drop the call via
  `removed_call/2`. Returns `:skip` when the node isn't a resolved call, or its
  `{module, fun}` isn't removable.

  The `removable` set holds `{module_key, function}` pairs — arity-agnostic, like
  `Mutare.Mutators.CallRemoval`'s `@removable` — where `module_key` is a resolved
  alias path (`[:String]`) or a bare Erlang atom (`:string`).
  """
  @spec remove_call(Macro.t(), Mutare.Mutator.pipe_mode(), MapSet.t({Calls.module_key(), atom()})) ::
          [Macro.t()] | :skip
  def remove_call(node, pipe_mode, removable) do
    with {module, fun, args, _rebuild} <- Calls.resolved_call(node),
         true <- MapSet.member?(removable, {module, fun}) do
      removed_call(pipe_mode, args)
    else
      _ -> :skip
    end
  end

  @doc """
  The pipe-aware removal itself, decoupled from how the call was matched.

  A call removal can't simply *vanish* a node: a pipe stage carries one fewer argument
  than the source reads (the input is the `|>` left side, not in the call), so the
  removal differs by context:

    * **non-piped** → the first argument (`Enum.sort(x)` → `x`), the cleanest diff;
    * **piped** → `Elixir.Function.identity()`, so `x |> Enum.sort()` becomes
      `x |> Elixir.Function.identity()` ≡ `x`. A pipe stage can't be made to disappear
      inside a selector, and `Function.identity/1` is the minimal, compile-safe no-op
      that rides the existing `PipeEmit.hoist` path unchanged. It is emitted through the
      **absolute** `Elixir.Function` alias (led by `:Elixir`, which alias resolution
      never rewrites) so a target-module `alias Foo, as: Function` can't redirect the
      generated no-op.

  Public so a mutator that matches a call by some means `Calls.resolved_call/1` doesn't
  cover (e.g. a bare `Kernel` call, keyed on effective arity) can reuse the
  identity-vs-first-argument mechanic after deciding the call is removable. Returns
  `:skip` for the degenerate non-piped, zero-argument call (nothing to return).
  """
  @spec removed_call(Mutare.Mutator.pipe_mode(), [Macro.t()]) :: [Macro.t()] | :skip
  def removed_call(:piped, _args), do: [identity_call()]
  def removed_call(:unpiped, []), do: :skip
  def removed_call(:unpiped, [first | _]), do: [first]

  defp identity_call, do: Mutare.AST.absolute_call([:Function], :identity, [])

  @doc """
  The "off-by-one + zero sentinel" mutations for a numeric literal `value`: `value + step`
  (`succ`), `value - step` (`pred`), and `zero` (`zero`), deduplicated, with any value equal to
  `value` dropped — each a `Mutare.Mutator.Mutation` carrying its `# mutare:ignore` variant label,
  attached **at production time** (so there is no separate `variant/2` to re-derive it). When the
  off-by-one collapses onto the zero sentinel (`n = 1` ⇒ `n - 1 = 0`) the deduped mutant carries
  *both* labels (`["pred", "zero"]`), so either qualifier suppresses it.

  Shared by `Mutare.Mutators.IntegerLiteral` (`step` 1, `zero` 0) and
  `Mutare.Mutators.FloatLiteral` (`step` 1.0, `zero` 0.0).
  """
  @spec numeric_mutations(number(), number(), number()) :: [Mutation.t()]
  def numeric_mutations(value, step, zero) do
    [{value + step, "succ"}, {value - step, "pred"}, {zero, "zero"}]
    |> Enum.reject(fn {v, _label} -> v == value end)
    |> merge_labels_by_value()
    |> Enum.map(fn {v, labels} -> Mutation.tagged(Mutare.AST.literal(v), one_or_many(labels)) end)
  end

  # Group `{value, label}` pairs by value, preserving first-seen order and collecting *all* labels
  # for a value — so a dedup collapse (`value + step == zero`, or `value - step == zero`) yields a
  # single mutant carrying both kinds, while position is the first occurrence (matching the old
  # `Enum.uniq` order the ids depend on).
  defp merge_labels_by_value(pairs) do
    {order, labels} =
      Enum.reduce(pairs, {[], %{}}, fn {value, label}, {order, labels} ->
        if Map.has_key?(labels, value),
          do: {order, Map.update!(labels, value, &(&1 ++ [label]))},
          else: {[value | order], Map.put(labels, value, [label])}
      end)

    order |> Enum.reverse() |> Enum.map(&{&1, labels[&1]})
  end

  # A lone label rides as a bare string (the common case — `succ`); only a collapse carries the
  # list (`["pred", "zero"]`). Both are valid `Mutare.Mutator.Mutation` variant tags.
  defp one_or_many([label]), do: label
  defp one_or_many(labels), do: labels

  defp mutation_list(:skip), do: []
  defp mutation_list(mutations) when is_list(mutations), do: mutations

  @doc """
  The variant vocabulary shared by the empty/sentinel literal families
  (`c:Mutare.Mutator.variants/0`) — `Mutare.Mutators.StringLiteral`,
  `Mutare.Mutators.StringSigilLiteral`, `Mutare.Mutators.CharlistLiteral`,
  `Mutare.Mutators.WordListLiteral`.
  """
  @spec empty_sentinel_variants() :: [String.t()]
  def empty_sentinel_variants, do: ~w(empty sentinel)

  @doc """
  Classify an empty/sentinel literal mutation by its produced `content` binary
  (`c:Mutare.Mutator.variant/2`): `"empty"` for `""`, `"sentinel"` for the family's `sentinel`
  word, else `nil`. The classification pair behind `empty_sentinel_variants/0`.
  """
  @spec empty_sentinel_variant(binary(), binary()) :: String.t() | nil
  def empty_sentinel_variant("", _sentinel), do: "empty"
  def empty_sentinel_variant(content, sentinel) when content == sentinel, do: "sentinel"
  def empty_sentinel_variant(_content, _sentinel), do: nil
end
