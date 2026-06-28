defmodule Shop.InventoryTest do
  use ExUnit.Case

  alias Shop.Inventory

  test "can_write? reads the write bit" do
    assert Inventory.can_write?(0b010)
    refute Inventory.can_write?(0b001)
  end

  test "can_read? reads the read bit" do
    assert Inventory.can_read?(0b001)
    refute Inventory.can_read?(0b100)
  end

  test "grant unions two masks" do
    assert Inventory.grant(0b001, 0b010) == 0b011
  end

  test "bin_for is the hash modulo the bin count" do
    assert Inventory.bin_for(10, 3) == 1
  end

  test "all_reserved unions both warehouses" do
    assert Inventory.all_reserved(MapSet.new([1, 2]), MapSet.new([2, 3])) ==
             MapSet.new([1, 2, 3])
  end

  test "code_size dispatches to the catalog" do
    assert Inventory.code_size("ABCD") == 4
  end

  test "parse_quantity reads digits and falls back to zero" do
    assert Inventory.parse_quantity("12") == 12
    assert Inventory.parse_quantity("oops") == 0
  end
end
