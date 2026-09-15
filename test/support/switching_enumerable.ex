defmodule Mutare.Test.SwitchingEnumerable do
  @moduledoc false
  # Compiled before protocol consolidation, so the runtime clean-path test can
  # demonstrate that `in` may run user code which changes the active selection.
  defstruct [:id]
end

defimpl Enumerable, for: Mutare.Test.SwitchingEnumerable do
  def member?(%{id: id}, _value) do
    Mutare.Selector.put(id)
    {:ok, true}
  end

  def count(_), do: {:error, __MODULE__}
  def slice(_), do: {:error, __MODULE__}
  def reduce(_, _, _), do: raise("membership should use member?/2")
end
