defmodule Mutare.Analyze do
  @moduledoc """
  Expression-level mutant generation for selector hosts and integrations.

  A macro host (`Mutare.Mutator.MacroHost`) owns everything inside a `:hosted` DSL fragment —
  core never descends there. But a hosted fragment can contain islands of ordinary Elixir that
  are exactly core's business: everything under an Ecto `^` pin is evaluated at runtime and
  interpolated as a query parameter, so `^18` or `^(min + 1)` deserves core's value mutations
  under the user's configured families — not the host's DSL-semantics catalog, and not nothing.

  `expression_mutations/3` is the sub-contract seam: it generates the logical single-point
  mutants of an expression subtree exactly as core's analyzer would for the same code outside a
  DSL, and returns them as data. **Generation is core's; delivery stays host-owned** — the host
  wraps each rebuilt subtree back under its pin, appends it to its
  `Mutare.Mutator.MacroHost.Target` mutants (tagged with the producing spec via
  `Mutare.Mutator.Mutation`'s `:producer`), and the ordinary hosted pipeline assigns ids,
  records sites under the producing family, and weaves the host's selector.

  Inside `c:Mutare.Mutator.MacroHost.host/2`, the run's enabled non-host specs arrive as
  `context.mutators`, so the interior follows the user's actual configuration (`:as` renames and
  per-instance options included — and with a family disabled, its interior mutants simply don't
  exist):

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
  inside the subtree is left raw — no recursive hosting; the calling host owns the region.

  Only **node-level** producers run (`c:Mutare.Mutator.mutate/1` / `c:Mutare.Mutator.mutate/2`,
  through the ordinary dispatch, so notes, variants, per-spec options, and behaviours follow the
  established contract). Structural families and selector hosts in `mutators` are ignored:
  def-level, clause-level, and return-value shapes don't apply to a bare expression subtree.

  The function is pure — no ids are claimed and no sites are recorded; those remain the
  transform's, exercised when the host's target flows through the hosted pipeline. `context` is
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
