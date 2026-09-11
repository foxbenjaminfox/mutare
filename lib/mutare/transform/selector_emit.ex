defmodule Mutare.Transform.SelectorEmit do
  @moduledoc false

  # Shared selector-emission mechanics. The transform-specific paths still decide what a mutant
  # branch does and where the resulting selector is spliced; this module owns the common id/site
  # claim, active-id subject, catch-all coverage branch, and ordinary selector-case assembly.

  alias Mutare.Coverage.Recorder
  alias Mutare.Site
  alias Mutare.Transform.{ClaimState, Config, Ctx, Render, Scope}

  @doc """
  Claim an id per item, record its site, and collect one artifact per live mutant.

  Ignored, unselected, and poison-skipped ids still advance and record a site, but emit no artifact.

  `site_fns` is the `{site_fn, line_fn}` pair `Mutare.Transform.ClaimState` needs: one builds
  the recorded `Mutare.Site`, the other answers only *where* it would be recorded, for the count
  pass's `--line` test (which must not build a `Site` — see `ClaimState`).
  """
  @spec claim_items(
          [item],
          Ctx.t(),
          {(pos_integer(), item, String.t(), {boolean(), boolean()} -> Site.t()),
           (item -> pos_integer() | nil)},
          (pos_integer(), item -> artifact)
        ) :: {[artifact], Ctx.t()}
        when item: term(), artifact: term()
  def claim_items(items, %Ctx{} = ctx, site_fns, artifact_fn) do
    Enum.flat_map_reduce(items, ctx, fn item, ctx ->
      claim_item(ctx, item, site_fns, artifact_fn)
    end)
  end

  @doc "The mutant ids of a list of `<id> -> body` selector clauses, in order."
  @spec ids_from_clauses([Macro.t()]) :: [pos_integer()]
  def ids_from_clauses(clauses), do: for({:->, _, [[id], _]} <- clauses, do: id)

  @doc """
  Build an ordinary selector `case` with a coverage-recording catch-all branch.
  """
  @spec selector_case(Macro.t(), [Macro.t()], Ctx.t()) :: Macro.t()
  def selector_case(default_node, mutant_clauses, %Ctx{config: %Config{active_var: var}} = ctx) do
    ids = ids_from_clauses(mutant_clauses)
    catch_all = catch_all_clause(ids, default_node, var, ctx.config.runtime_namespace)
    Render.selector_case(subject(ctx), mutant_clauses ++ [catch_all])
  end

  @doc "Build a raw selector `case` from already assembled clauses."
  @spec raw_case([Macro.t()], Macro.t(), Ctx.t()) :: Macro.t()
  def raw_case(mutant_clauses, catch_all, %Ctx{} = ctx) do
    {:case, [], [subject(ctx), [do: mutant_clauses ++ [catch_all]]]}
  end

  @doc """
  The selector `case` scrutinee for the current emit scope.

  When the active-id variable is already bound in the current function scope, selectors read that
  variable. Otherwise they keep the self-contained `:persistent_term` read.
  """
  @spec subject(Ctx.t()) :: Macro.t()
  def subject(%Ctx{scope: scope, config: %Config{} = config}) do
    if Scope.active_var_bound?(scope),
      do: {config.active_var, [], nil},
      else: Mutare.Metamutant.subject_ast(config.runtime_namespace)
  end

  @doc "The selector catch-all branch: baseline plus every inactive mutant."
  @spec catch_all_clause([pos_integer()], Macro.t(), atom(), String.t() | nil) :: Macro.t()
  def catch_all_clause(ids, default_node, var, namespace \\ nil)

  def catch_all_clause([], default_node, _var, _namespace),
    do: {:->, [], [[{:_, [], nil}], default_node]}

  def catch_all_clause(ids, default_node, var, namespace) do
    body = {:__block__, [], [Recorder.record_ast(ids, var, namespace), default_node]}
    {:->, [], [[Recorder.catch_all_pattern(var)], body]}
  end

  # The id/site/sink mechanics live on `Mutare.Transform.ClaimState` (which owns that state);
  # here we pass the config it consults and thread the updated `claim` back onto `ctx`.
  # The render vs. count sink branch is `ClaimState.claim/5`.
  defp claim_item(%Ctx{config: config, claim: claim} = ctx, item, site_fns, artifact_fn) do
    {artifacts, claim} =
      ClaimState.claim(
        claim,
        config,
        item,
        site_fns,
        artifact_fn
      )

    {artifacts, %{ctx | claim: claim}}
  end
end
