defmodule Modboss.MappingTest do
  use ExUnit.Case
  alias ModBoss.Mapping

  describe "new/4" do
    test "creates a valid mapping with default options" do
      mapping = Mapping.new(:foo, :holding_register, 1)
      assert mapping.name == :foo
      assert mapping.type == :holding_register
      assert mapping.addresses == 1..1
      assert mapping.starting_address == 1
      assert mapping.register_count == 1
      assert mapping.mode == :r
    end

    test "creates a valid mapping with a range of addresses" do
      mapping = Mapping.new(:bar, :coil, 1..5, mode: :rw)
      assert mapping.name == :bar
      assert mapping.type == :coil
      assert mapping.addresses == 1..5
      assert mapping.starting_address == 1
      assert mapping.register_count == 5
      assert mapping.mode == :rw
    end

    test "raises an error for invalid mode" do
      assert_raise RuntimeError, ~r/Invalid mode/, fn ->
        Mapping.new(:baz, :holding_register, 1, mode: :invalid)
      end
    end

    test "raises an error for unsupported address range step" do
      assert_raise RuntimeError, ~r/Only address ranges with step `1` are supported/, fn ->
        Mapping.new(:qux, :coil, 1..5//2)
      end
    end
  end

  describe "readable?/1" do
    test "returns true for readable mappings" do
      for mode <- [:r, :rw] do
        mapping = Mapping.new(:foo, :holding_register, 1, mode: mode)
        assert Mapping.readable?(mapping)
      end
    end

    test "returns false for non-readable mappings" do
      mapping = Mapping.new(:foo, :holding_register, 1, mode: :w)
      refute Mapping.readable?(mapping)
    end
  end

  describe "writable?/1" do
    test "returns true for writable mappings" do
      for mode <- [:w, :rw] do
        mapping = Mapping.new(:foo, :holding_register, 1, mode: mode)
        assert Mapping.writable?(mapping)
      end
    end

    test "returns false for non-writable mappings" do
      mapping = Mapping.new(:foo, :holding_register, 1, mode: :r)
      refute Mapping.writable?(mapping)
    end
  end
end
