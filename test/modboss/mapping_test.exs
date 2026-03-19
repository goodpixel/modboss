defmodule ModBoss.MappingTest do
  use ExUnit.Case, async: true
  alias ModBoss.Mapping
  require Mapping

  describe "new/4" do
    test "creates a valid mapping with default options" do
      mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1)
      assert mapping.name == :foo
      assert mapping.type == :holding_register
      assert mapping.starting_address == 1
      assert mapping.address_count == 1
      assert mapping.mode == :r
    end

    test "creates a valid mapping with a range of addresses" do
      mapping = Mapping.new(__MODULE__, :bar, :coil, 1..5, mode: :rw)
      assert mapping.name == :bar
      assert mapping.type == :coil
      assert mapping.starting_address == 1
      assert mapping.address_count == 5
      assert mapping.mode == :rw
    end

    test "raises an error for invalid mode" do
      assert_raise RuntimeError, ~r/Invalid mode/, fn ->
        Mapping.new(__MODULE__, :baz, :holding_register, 1, mode: :invalid)
      end
    end

    test "raises an error for unsupported address range step" do
      assert_raise RuntimeError, ~r/Only address ranges with step `1` are supported/, fn ->
        Mapping.new(__MODULE__, :qux, :coil, 1..5//2)
      end
    end

    test "accepts a {module, translator_func} tuple for the `:as` option" do
      mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, as: {SomeModule, :foo})
      assert {SomeModule, :foo} = mapping.as
    end

    test "accepts a simple atom for the `:as` option, and infers the schema module as the module" do
      mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, as: :foo)
      assert {__MODULE__, :foo} = mapping.as
    end

    test "falls back to using the raw 'translator' if not provided the `:as` option" do
      mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1)
      assert {ModBoss.Encoding, :raw} = mapping.as
    end
  end

  describe "gap_safe" do
    test "defaults to true for readable mappings" do
      for mode <- [:r, :rw] do
        mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, mode: mode)
        assert mapping.gap_safe == true
      end
    end

    test "defaults to false for write-only mappings" do
      mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, mode: :w)
      assert mapping.gap_safe == false
    end

    test "can be explicitly set to false on readable mappings" do
      for mode <- [:r, :rw] do
        mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, mode: mode, gap_safe: false)
        assert mapping.gap_safe == false
      end
    end

    test "can be explicitly set to true on readable mappings" do
      for mode <- [:r, :rw] do
        mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, mode: mode, gap_safe: true)
        assert mapping.gap_safe == true
      end
    end

    test "raises when set to true on a write-only mapping" do
      assert_raise RuntimeError, ~r/gap_safe: true is not allowed on write-only/, fn ->
        Mapping.new(__MODULE__, :foo, :holding_register, 1, mode: :w, gap_safe: true)
      end
    end
  end

  describe "address_range/1" do
    mapping = Mapping.new(__MODULE__, :foo, :holding_register, 3)
    assert 3..3 = Mapping.address_range(mapping)

    mapping = Mapping.new(__MODULE__, :foo, :holding_register, 27..31)
    assert 27..31 = Mapping.address_range(mapping)
  end

  describe "adjacent?/2" do
    test "true when same type and addresses are contiguous" do
      a = Mapping.new(__MODULE__, :a, :holding_register, 1)
      b = Mapping.new(__MODULE__, :b, :holding_register, 2)
      assert Mapping.adjacent?(a, b)
    end

    test "true when mappings of the same type span multiple contiguous addresses" do
      a = Mapping.new(__MODULE__, :a, :holding_register, 1..3)
      b = Mapping.new(__MODULE__, :b, :holding_register, 4..5)
      assert Mapping.adjacent?(a, b)
    end

    test "false when there is a gap between addresses" do
      a = Mapping.new(__MODULE__, :a, :holding_register, 1)
      b = Mapping.new(__MODULE__, :b, :holding_register, 3)
      refute Mapping.adjacent?(a, b)
    end

    test "false when types differ" do
      a = Mapping.new(__MODULE__, :a, :holding_register, 1)
      b = Mapping.new(__MODULE__, :b, :input_register, 2)
      refute Mapping.adjacent?(a, b)
    end

    test "false when order is reversed" do
      a = Mapping.new(__MODULE__, :a, :holding_register, 2)
      b = Mapping.new(__MODULE__, :b, :holding_register, 1)
      refute Mapping.adjacent?(a, b)
    end
  end

  describe "gap/2" do
    test "returns size 0 and empty addresses for adjacent mappings" do
      a = Mapping.new(__MODULE__, :a, :holding_register, 1)
      b = Mapping.new(__MODULE__, :b, :holding_register, 2)
      assert %{size: 0, addresses: addresses} = Mapping.gap(a, b)
      assert MapSet.size(addresses) == 0
    end

    test "returns the correct size and addresses for a gap" do
      a = Mapping.new(__MODULE__, :a, :holding_register, 1)
      b = Mapping.new(__MODULE__, :b, :holding_register, 5)
      assert %{size: 3, addresses: addresses} = Mapping.gap(a, b)

      assert addresses ==
               MapSet.new([
                 {:holding_register, 2},
                 {:holding_register, 3},
                 {:holding_register, 4}
               ])
    end

    test "raises when types differ" do
      a = Mapping.new(__MODULE__, :a, :holding_register, 1)
      b = Mapping.new(__MODULE__, :b, :input_register, 2)

      assert_raise FunctionClauseError, fn ->
        Mapping.gap(a, b)
      end
    end

    test "works with multi-address mappings" do
      a = Mapping.new(__MODULE__, :a, :holding_register, 1..3)
      b = Mapping.new(__MODULE__, :b, :holding_register, 6)
      assert %{size: 2, addresses: addresses} = Mapping.gap(a, b)

      assert addresses ==
               MapSet.new([{:holding_register, 4}, {:holding_register, 5}])
    end
  end

  describe "readable?/1" do
    test "returns true for readable mappings" do
      for mode <- [:r, :rw] do
        mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, mode: mode)
        assert Mapping.readable?(mapping)
      end
    end

    test "returns false for non-readable mappings" do
      mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, mode: :w)
      refute Mapping.readable?(mapping)
    end
  end

  describe "writable?/1" do
    test "returns true for writable mappings" do
      for mode <- [:w, :rw] do
        mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, mode: mode)
        assert Mapping.writable?(mapping)
      end
    end

    test "returns false for non-writable mappings" do
      mapping = Mapping.new(__MODULE__, :foo, :holding_register, 1, mode: :r)
      refute Mapping.writable?(mapping)
    end
  end
end
