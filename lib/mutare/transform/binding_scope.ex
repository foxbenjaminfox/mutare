defmodule Mutare.Transform.BindingScope do
  @moduledoc false

  # An emit beneath one hoisted active-id binding, returned with what the emitted code asks of
  # that binding. Two boundaries introduce such a binding: a non-lifted clause's `:do` prologue
  # (`<var> = :persistent_term.get(...)`) and a lifted group's dispatcher, which threads the id
  # as its base function's first parameter. Each decides two things from the code beneath it:
  #
  #   * whether to bind at all — an unreferenced prologue draws an "unused variable" warning,
  #     and a group whose lifted mutants were all withheld needs no dispatcher
  #     (`referenced?/1`);
  #   * whether a clean region repays its copy, by the reads it holds and the ids it claimed
  #     (`Mutare.Transform.CleanRegion.worthwhile?/2`).
  #
  # `emit/2` runs the enclosed emit with a fresh reference count (`Scope.active_references`,
  # which `Mutare.Transform.SelectorEmit.reference_active/2` increments for every read) and
  # restores the enclosing count afterwards: the scope's own binding satisfies its readers, so
  # they never reach an enclosing one. The counter is meaningful only inside `emit/2`; nothing
  # else resets or reads it.
  #
  # The enclosed emit decides whether the binding is *in scope* where it emits
  # (`Scope.active_bound`), because the boundaries differ there: a dispatcher's parameter
  # reaches every body block but no head default, a prologue reaches the `:do` block alone.

  alias Mutare.Transform.Ctx

  @typedoc """
  The emitted value (`emitted`) with its demands on the binding: `references` reads of it,
  `ids` the local ids claimed meanwhile (empty when none were), and `variants` the mutants
  among them actually emitted.
  """
  @type t(value) :: %__MODULE__{
          emitted: value,
          references: non_neg_integer(),
          ids: Range.t(),
          variants: non_neg_integer()
        }

  @type t :: t(term())

  @enforce_keys [:emitted, :references, :ids, :variants]
  defstruct @enforce_keys

  @doc "Run `fun` as the emit beneath a fresh binding, returning its result and demands."
  @spec emit(Ctx.t(), (Ctx.t() -> {value, Ctx.t()})) :: {t(value), Ctx.t()} when value: term()
  def emit(%Ctx{} = ctx, fun) do
    enclosing = ctx.scope.active_references
    first_id = ctx.claim.next_id
    emitted_before = ctx.claim.emitted

    {emitted, ctx} = fun.(Ctx.update_scope(ctx, &%{&1 | active_references: 0}))

    scoped = %__MODULE__{
      emitted: emitted,
      references: ctx.scope.active_references,
      ids: first_id..(ctx.claim.next_id - 1)//1,
      variants: ctx.claim.emitted - emitted_before
    }

    {scoped, Ctx.update_scope(ctx, &%{&1 | active_references: enclosing})}
  end

  @doc "Whether any emitted code reads the binding, so the boundary must introduce it."
  @spec referenced?(t()) :: boolean()
  def referenced?(%__MODULE__{references: references}), do: references > 0
end
