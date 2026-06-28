defmodule Shop.Inventory do
  @moduledoc """
  Stock, permissions, and warehouse bookkeeping.

  The bit-twiddling and Erlang-flavoured corner: bitwise masks, `Integer`
  division, `MapSet` combinations, a `try/rescue`, an inert type guard, and a
  dynamic `apply/3` whose module argument is a literal alias.
  """

  import Bitwise

  @read 0b001
  @write 0b010

  @doc "Does this permission mask allow writes?"
  def can_write?(permissions) do
    (permissions &&& @write) != 0
  end

  @doc "Does this permission mask allow reads?"
  def can_read?(permissions) do
    (permissions &&& @read) != 0
  end

  @doc "Combine two permission masks into one."
  def grant(current, added) do
    current ||| added
  end

  @doc "Which storage bin a hash falls into, given the number of bins."
  def bin_for(hash, bins) do
    Integer.mod(hash, bins)
  end

  @doc "Every SKU reserved across the two warehouses."
  def all_reserved(west, east) do
    MapSet.union(west, east)
  end

  @doc "Look up a SKU's code length, by dispatching dynamically to the catalog."
  def code_size(sku) when is_binary(sku) do
    apply(Shop.Catalog, :code_length, [sku])
  end

  @doc "Parse a quantity from text, treating malformed input as zero."
  def parse_quantity(text) do
    try do
      String.to_integer(text)
    rescue
      e in [ArgumentError, FunctionClauseError] -> fallback(e)
    end
  end

  defp fallback(_error), do: 0
end
