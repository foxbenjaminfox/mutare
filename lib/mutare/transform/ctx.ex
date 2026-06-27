defmodule Mutare.Transform.Ctx do
  @moduledoc false

  # The single context threaded through every transform stage, split by responsibility into
  # three sub-structs so each stage touches only what it owns:
  #
  #   * `config` (`Mutare.Transform.Config`) — immutable for the pass: the file, the resolved
  #     mutators, poison `skip_ids`, and the generated-name hygiene.
  #   * `scope` (`Mutare.Transform.Scope`) — the mutable lexical/emission scope: active-id
  #     binding, module depth, behaviours, and the per-module behaviour-enriched mutator cache.
  #   * `claim` (`Mutare.Transform.ClaimState`) — id/site accumulation and the claim sink
  #     (`:render` vs the render-free `:count`).
  #
  # Still threaded as **one** value (never destructured into loose args), so the shape stays
  # uniform and a stray field name fails loudly; the split is by ownership, not by threading.
  # `update_scope/2`/`update_claim/2` keep the nested updates terse.

  alias Mutare.Transform.{ClaimState, Config, Scope}

  @type t :: %__MODULE__{
          config: Config.t(),
          scope: Scope.t(),
          claim: ClaimState.t()
        }

  defstruct config: %Config{}, scope: %Scope{}, claim: %ClaimState{}

  @doc "Apply `fun` to the `scope` sub-struct, leaving `config`/`claim` untouched."
  @spec update_scope(t(), (Scope.t() -> Scope.t())) :: t()
  def update_scope(%__MODULE__{} = ctx, fun), do: %{ctx | scope: fun.(ctx.scope)}

  @doc "Apply `fun` to the `claim` sub-struct, leaving `config`/`scope` untouched."
  @spec update_claim(t(), (ClaimState.t() -> ClaimState.t())) :: t()
  def update_claim(%__MODULE__{} = ctx, fun), do: %{ctx | claim: fun.(ctx.claim)}
end
