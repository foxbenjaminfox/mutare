defmodule Mutare.Analyze do
  @moduledoc """
  Expression-level mutant generation for selector hosts and integrations.

  Core analysis skips regions routed `:hosted` or `:raw`. These regions can still contain ordinary Elixir expressions: everything under an Ecto `^` pin is evaluated at runtime and interpolated as a query parameter. Expressions such as `^18` or `^(min + 1)` can therefore be mutated with the user's configured Elixir families.

  `expression_mutations/3` generates the logical single-point mutants of an expression subtree using the same analysis as for code outside a DSL. It returns them as data for the caller to embed through either delivery path:

    * a selector host (`c:Mutare.Mutator.MacroHost.host/2`) wraps each rebuilt subtree back under its pin, appends it to its `Mutare.Mutator.MacroHost.Target` mutants (tagged with the producing spec via `Mutare.Mutator.Mutation`'s `:producer`), and the ordinary hosted pipeline assigns ids, records sites under the producing family, and weaves the host's selector;
    * a mutator offered the whole call of a registered macro (`c:Mutare.Mutator.mutate/2` — the free-standing `dynamic/1,2` shape, where the macro sits in ordinary expression position and its `:raw` argument stays as written) rebuilds the call around each mutant and relays it the same way; delivery is the ordinary in-place selector.

  On both paths `context.mutators` contains the **full** set of enabled specs, including selector hosts, `:as` renames, and per-instance options. The interior is analyzed under that configuration, with no mutants from disabled families. For a mutator implementing hosting, generation uses both its ordinary node-level `mutate/1,2` and its hosted callbacks. A registered macro inside the expression is passed whole to its registered mutator, as with a nested `dynamic` call. Hosted targets are **lowered** to whole-call rebuilds (`splice(wrap(mutant))`) using just the selected branch. This preserves their mutations without nesting hosted selectors:

      defp pin_mutants({:^, meta, [inner]}, context) do
        for {spec, mutated, note, variant} <-
              Mutare.Analyze.expression_mutations(inner, context.mutators, context) do
          Mutare.Mutator.Mutation.new({:^, meta, [mutated]},
            producer: spec,
            note: note,
            variant: variant
          )
        end
      end
  """

  alias Mutare.Mutator.{Mutation, Spec}
  alias Mutare.Transform.Analyze.Collect

  @doc """
  Returns the logical single-point mutants of the expression subtree, one rebuild per mutant.

  Each element is `{producing_spec, mutated_subtree, note, variant}`: the whole subtree with
  exactly one position swapped, plus the producing `Mutare.Mutator.Spec` and the mutation's
  optional advisory note and resolved `# mutare:ignore` variant label(s) — ready to wrap under
  a `%Mutare.Mutator.Mutation{}` with `producer: spec`.

  This function uses the core analyzer's traversal of runtime expressions, with the same
  mutation rules as for code outside the DSL: call-routing stamps apply (a `:raw` or
  `:pattern` argument stays raw, an `:expression` argument is traversed), pattern positions are
  never mutated in place, and cross-family suppressions apply. A nested `{:hosted, …}` stamp
  inside the subtree keeps its argument core-raw, but the subscribed host's
  `c:Mutare.Mutator.MacroHost.host/2` runs and each target mutant is **lowered** to a rebuild
  of the hosting call — `splice(wrap(mutant))`, the woven selector degenerated to its selected
  branch. By construction, this has the same value as the assembled selector when that mutant
  is active. Hosted mutations are returned as data; only the calling host inserts a selector
  for the region.

  Node-level producers run through the ordinary dispatch (`c:Mutare.Mutator.mutate/1` /
  `c:Mutare.Mutator.mutate/2` — so notes, variants, per-spec options, behaviours, and each
  producer's `c:Mutare.Mutator.finalize/2` funnel follow the established contract), and
  selector hosts through the lowering above (their `finalize/2` runs at target normalization,
  same contract). Structural families in `mutators` are ignored — def-level, clause-level, and
  return-value shapes don't apply to a bare expression subtree.

  It assigns no ids and records no sites. The transform does both when embedding the returned
  mutations. Pass the callback's `context` unchanged: it carries the enclosing call's lexical
  environment and the configured routes and argument marks. Core resolves the declared Elixir
  island there before analysis, including its pipes, aliases and imports. Nested hosted regions
  remain syntax until their own hosts declare an island. During a scan, resolution also reports
  the island's route/mark matches, even when it produces no mutations.

  Without a callback context, the subtree must already carry any resolution its mutations need.

  ## Examples

      iex> subtree = Sourceror.parse_string!("min + 1")
      iex> [{spec, mutated, _note, _variant}] =
      ...>   Mutare.Analyze.expression_mutations(subtree, [Mutare.Mutators.Arithmetic])
      iex> {spec.name, Sourceror.to_string(mutated)}
      {:arithmetic, "min - 1"}
  """
  @spec expression_mutations(Macro.t(), [Spec.t() | module()], map()) ::
          [{Spec.t(), Macro.t(), String.t() | nil, Mutation.variant()}]
  defdelegate expression_mutations(subtree, mutators, context \\ %{}), to: Collect
end
