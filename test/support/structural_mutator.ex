defmodule Mutare.Test.ReturnMutator do
  @moduledoc """
  A custom **structural return-position** mutator: it implements
  `c:Mutare.Mutator.Structural.return_replacements/1` (not `mutate/1`, which is `:skip`), so the transform
  discovers it by export and offers it at every clause return tail — exactly like the built-in
  `Mutare.Mutators.ReturnValue`, but under its own name. Exercises that structural in-place
  mutators are no longer hardcoded to the two built-ins.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :custom_return

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  # Replace any clause tail with the marker atom `:custom_return`.
  @impl Mutare.Mutator.Structural
  def return_replacements(_tail), do: [AST.literal(:custom_return)]
end

defmodule Mutare.Test.ConditionMutator do
  @moduledoc """
  A custom **structural condition** mutator: it implements
  `c:Mutare.Mutator.Structural.condition_replacements/1`, so the transform offers it at every
  `if`/`unless`/`cond` condition — like the built-in `Mutare.Mutators.IfCondition`, under its
  own name. Here it forces the condition to `true` only.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :custom_condition

  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.Mutator.Structural
  def condition_replacements(_condition), do: [AST.literal(true)]
end
