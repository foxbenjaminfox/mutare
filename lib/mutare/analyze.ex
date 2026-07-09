defmodule Mutare.Analyze do
  @moduledoc """
  Expression-level mutant generation for selector hosts and integrations.

  A region that macro routing declared raw — a `:hosted` DSL fragment owned by its `Mutare.Mutator.MacroHost`, or a `:skip` argument owned by the mutator that registered the macro — is never descended by core. But such a region can contain islands of ordinary Elixir that are exactly core's business: everything under an Ecto `^` pin is evaluated at runtime and interpolated as a query parameter, so `^18` or `^(min + 1)` deserves core's value mutations under the user's configured families — not a DSL-semantics catalog, and not nothing.

  `expression_mutations/3` is the sub-contract seam: it generates the logical single-point mutants of an expression subtree exactly as core's analyzer would for the same code outside a DSL, and returns them as data. Generation is core's; delivery stays the caller's — on either delivery path a raw region can take:

    * a selector host (`c:Mutare.Mutator.MacroHost.host/2`) wraps each rebuilt subtree back under its pin, appends it to its `Mutare.Mutator.MacroHost.Target` mutants (tagged with the producing spec via `Mutare.Mutator.Mutation`'s `:producer`), and the ordinary hosted pipeline assigns ids, records sites under the producing family, and weaves the host's selector;
    * a mutator offered the whole call of a registered macro (`c:Mutare.Mutator.mutate/2` — the free-standing `dynamic/1,2` shape, where the macro sits in ordinary expression position and its `:skip` argument stays raw) rebuilds the call around each mutant and relays it the same way; delivery is the ordinary in-place selector.

  On both paths the run's enabled specs arrive as `context.mutators` — the **full** set, selector hosts included — so the interior is analyzed exactly like top-level Elixir under the user's actual configuration (`:as` renames and per-instance options included — and with a family disabled, its interior mutants simply don't exist). A host-implementing mutator participates through *both* of its surfaces: its ordinary node-level `mutate/1,2` (a registered macro inside the island is offered whole-call to its owner — the inner-`dynamic` case), and its hosted surface, whose targets are **lowered** to whole-call rebuilds (`splice(wrap(mutant))` — the woven selector degenerated to its selected branch) rather than woven, so hosted delivery never nests while no mutant is lost:

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

  The walk is the analyzer's own runtime descent, so a host cannot out-mutate what core would
  have done on the same code outside the DSL: macro-routing stamps are honored (a `:skip` or
  `:pattern` argument stays raw, an `:expression` argument descends), pattern positions are
  never mutated in place, and cross-family suppressions apply. A nested `{:hosted, …}` stamp
  inside the subtree keeps its argument core-raw, but the subscribed host's
  `c:Mutare.Mutator.MacroHost.host/2` runs and each target mutant is **lowered** to a rebuild
  of the hosting call — `splice(wrap(mutant))`, the woven selector degenerated to its selected
  branch, by construction the value the weave evaluates to when that mutant is active. Hosting
  is a delivery optimization, not a semantic category: hosted *semantics* come back as data;
  hosted *delivery* (a woven selector) never nests — the calling host owns the region.

  Node-level producers run through the ordinary dispatch (`c:Mutare.Mutator.mutate/1` /
  `c:Mutare.Mutator.mutate/2` — so notes, variants, per-spec options, behaviours, and each
  producer's `c:Mutare.Mutator.finalize/2` funnel follow the established contract), and
  selector hosts through the lowering above (their `finalize/2` runs at target normalization,
  same contract). Structural families in `mutators` are ignored — def-level, clause-level, and
  return-value shapes don't apply to a bare expression subtree.

  The function is pure — no ids are claimed and no sites are recorded; those remain the
  transform's, exercised when the relayed mutation flows through its delivery path (a host
  target through the hosted pipeline, a whole-call rebuild through the in-place one). `context` is
  accepted for call-site symmetry with the mutator callbacks and is currently not consulted:
  the walk derives each position's own context (pipe stages, patterns, routing) from the
  subtree, and pipe/behaviour facts travel on the specs themselves.

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
