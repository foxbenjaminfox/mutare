defmodule Mutare.Transform.Ctx do
  @moduledoc false

  # The single context threaded through every transform stage, split by responsibility into
  # four sub-structs so each stage touches only what it owns:
  #
  #   * `config` (`Mutare.Transform.Config`) — immutable for the pass: the file, the resolved
  #     mutators, poison `skip_ids`, and the generated-name hygiene.
  #   * `scope` (`Mutare.Transform.Scope`) — the mutable lexical/emission scope: active-id
  #     binding, module depth, behaviours, and the per-module behaviour-enriched mutator cache.
  #   * `claim` (`Mutare.Transform.ClaimState`) — id/site accumulation and the claim sink
  #     (`:render` vs the render-free `:count`).
  #   * `matches` (`Mutare.Transform.ConfigMatches`) — the configured entries this source
  #     reached, for the schema's ineffective-configuration diagnostic. Grows as the walk
  #     records them; never read by id claiming.
  #
  # One more field belongs to no stage: `degraded_uses`, the module-level `use`s the resolve
  # pre-pass could not expand (`Mutare.Transform.Uses.degraded_uses/1`, for `mix mutare
  # --check`). The count sink reads it off the annotated tree once, before the walk; it never
  # changes after that and rides here only to reach `count_report/2` (`[]` under `:render`).
  #
  # Still threaded as **one** value (never destructured into loose args), so the shape stays
  # uniform and a stray field name fails loudly; the split is by ownership, not by threading.
  # `update_scope/2`/`update_claim/2`/`update_matches/2` keep the nested updates terse.

  alias Mutare.Transform.{ClaimState, Config, ConfigMatches, Scope, Uses}

  @type t :: %__MODULE__{
          config: Config.t(),
          scope: Scope.t(),
          claim: ClaimState.t(),
          matches: ConfigMatches.t(),
          degraded_uses: [Uses.degraded_use()]
        }

  defstruct config: %Config{},
            scope: %Scope{},
            claim: %ClaimState{},
            matches: %ConfigMatches{},
            degraded_uses: []

  @doc "Apply `fun` to the `scope` sub-struct, leaving the rest untouched."
  @spec update_scope(t(), (Scope.t() -> Scope.t())) :: t()
  def update_scope(%__MODULE__{} = ctx, fun), do: %{ctx | scope: fun.(ctx.scope)}

  @doc "Apply `fun` to the `claim` sub-struct, leaving the rest untouched."
  @spec update_claim(t(), (ClaimState.t() -> ClaimState.t())) :: t()
  def update_claim(%__MODULE__{} = ctx, fun), do: %{ctx | claim: fun.(ctx.claim)}

  @doc "Apply `fun` to the `matches` sub-struct, leaving the rest untouched."
  @spec update_matches(t(), (ConfigMatches.t() -> ConfigMatches.t())) :: t()
  def update_matches(%__MODULE__{} = ctx, fun), do: %{ctx | matches: fun.(ctx.matches)}
end
