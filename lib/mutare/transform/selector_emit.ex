defmodule Mutare.Transform.SelectorEmit do
  @moduledoc false

  # Shared selector-emission mechanics. The transform-specific paths still decide what a mutant
  # branch does and where the resulting selector is spliced; this module owns the common id/site
  # claim, active-id subject, catch-all coverage branch, and ordinary selector-case assembly.

  alias Mutare.Coverage.Recorder
  alias Mutare.Site
  alias Mutare.Transform.{ClaimState, Config, CoverageEmit, Ctx, Render, Scope}

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
  Build an ordinary selector `case` with a coverage-recording catch-all branch, returning it
  with the scope updated (`subject/1`).
  """
  @spec selector_case(Macro.t(), [Macro.t()], Ctx.t()) :: {Macro.t(), Ctx.t()}
  def selector_case(default_node, mutant_clauses, %Ctx{} = ctx) do
    ids = ids_from_clauses(mutant_clauses)
    {catch_all, ctx} = catch_all_clause(ids, default_node, ctx)
    {subject, ctx} = subject(ctx)
    {Render.selector_case(subject, mutant_clauses ++ [catch_all]), ctx}
  end

  @doc "Build a raw selector `case` from already assembled clauses, with the scope updated (`subject/1`)."
  @spec raw_case([Macro.t()], Macro.t(), Ctx.t()) :: {Macro.t(), Ctx.t()}
  def raw_case(mutant_clauses, catch_all, %Ctx{} = ctx) do
    {subject, ctx} = subject(ctx)
    {raw_case_over(subject, mutant_clauses, catch_all), ctx}
  end

  @doc """
  `raw_case/3` over a subject the caller already holds (`subject_read/1`).

  Rebuilding a selector in place of one already emitted goes through here: the rebuilt `case`
  is the same selector site, so it takes no second subject and records no second reference.
  """
  @spec raw_case_over(Macro.t(), [Macro.t()], Macro.t()) :: Macro.t()
  def raw_case_over(subject, mutant_clauses, catch_all),
    do: {:case, [], [subject, [do: mutant_clauses ++ [catch_all]]]}

  @doc """
  Record that the emitted code references the hoisted binding (`Scope.active_references`).

  `subject/1` does this for every selector that reads the variable as its scrutinee; a
  per-clause delivery that reads it directly — a `<var> === <id>` gate in an `fn`/`receive`
  clause, an exclusion guard, a creation-time coverage record — calls this itself.
  `Mutare.Transform` uses the flag to determine whether to bind the variable at all.
  """
  @spec reference_active(Ctx.t()) :: Ctx.t()
  def reference_active(%Ctx{} = ctx),
    do: Ctx.update_scope(ctx, &%{&1 | active_references: &1.active_references + 1})

  @doc """
  The selector `case` scrutinee for the current emit scope, with the scope updated.

  When the active-id variable is bound here (`Scope.active_var_bound?/1`), selectors read that
  variable and the reference is recorded (`reference_active/1`). Otherwise they keep the
  self-contained `:persistent_term` read.
  """
  @spec subject(Ctx.t()) :: {Macro.t(), Ctx.t()}
  def subject(%Ctx{} = ctx) do
    {_read, subject, ctx} = subject_read(ctx)
    {subject, ctx}
  end

  @typedoc """
  What a selector's scrutinee reads. `:binding` is the scope's hoisted active-id variable: one
  immutable value, so every selector that reads it in that scope switches on the same id.
  `:inline` is the selector's own `:persistent_term` read, which it shares with no other.
  """
  @type read :: :binding | :inline

  @doc """
  `subject/1`, naming what the scrutinee reads.

  A caller that may later fold more mutant clauses into the selector it is building
  (`Mutare.Transform.HostedEmit`) keeps the answer: only `:binding` selectors are known to
  switch on one value.
  """
  @spec subject_read(Ctx.t()) :: {read(), Macro.t(), Ctx.t()}
  def subject_read(%Ctx{scope: scope, config: %Config{active_var: var} = config} = ctx) do
    if Scope.active_var_bound?(scope),
      do: {:binding, {var, [], nil}, reference_active(ctx)},
      else: {:inline, Mutare.Metamutant.subject_ast(config.runtime_namespace), ctx}
  end

  @doc "The selector catch-all branch: baseline plus every inactive mutant."
  @spec catch_all_clause([pos_integer()], Macro.t(), Ctx.t()) :: {Macro.t(), Ctx.t()}
  def catch_all_clause([], default_node, ctx),
    do: {{:->, [], [[{:_, [], nil}], default_node]}, ctx}

  def catch_all_clause(ids, default_node, ctx) do
    {record, ctx} = CoverageEmit.record(ids, ctx, :local)
    body = {:__block__, [], [record, default_node]}
    {{:->, [], [[Recorder.catch_all_pattern(ctx.config.active_var)], body]}, ctx}
  end

  # The id/site/sink mechanics live on `Mutare.Transform.ClaimState` (which owns that state);
  # here we pass the config it consults, the enclosing block-macro tag the scope carries, and
  # thread the updated `claim` back onto `ctx`. The render vs. count sink branch is
  # `ClaimState.claim/6`.
  defp claim_item(
         %Ctx{config: config, scope: scope, claim: claim} = ctx,
         item,
         site_fns,
         artifact_fn
       ) do
    {artifacts, claim} =
      ClaimState.claim(
        claim,
        config,
        scope.block_macro,
        item,
        site_fns,
        artifact_fn
      )

    {artifacts, %{ctx | claim: claim}}
  end
end
