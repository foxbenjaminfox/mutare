defmodule Mutare.Test.ThrowingScanMutator do
  @moduledoc false
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :throwing_scan

  @impl Mutare.Mutator
  def mutate(_node), do: throw(:mutare_scan_throw)
end

defmodule Mutare.Test.ExitingScanMutator do
  @moduledoc false
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :exiting_scan

  @impl Mutare.Mutator
  def mutate(_node), do: exit(:mutare_scan_exit)
end
