defmodule ModBoss.EncodingTest do
  use ExUnit.Case, async: true
  doctest ModBoss.Encoding, import: true

  alias ModBoss.Encoding
  alias ModBoss.Encoding.Metadata

  describe "raw" do
    test "doesn't change the value when encoding" do
      assert Encoding.encode_raw(123, %Metadata{}) == {:ok, 123}
      assert Encoding.encode_raw(:abc, %Metadata{}) == {:ok, :abc}
      assert Encoding.encode_raw([1, 2, 3], %Metadata{}) == {:ok, [1, 2, 3]}
    end

    test "doesn't change the value when decoding" do
      assert Encoding.decode_raw(123) == {:ok, 123}
      assert Encoding.decode_raw(:abc) == {:ok, :abc}
      assert Encoding.decode_raw([1, 2, 3]) == {:ok, [1, 2, 3]}
    end
  end

  describe "boolean" do
    test "encodes true and 1 and false as 0" do
      assert Encoding.encode_boolean(true, %Metadata{}) == {:ok, 1}
      assert Encoding.encode_boolean(false, %Metadata{}) == {:ok, 0}
    end

    test "decodes 1 as true and 0 as false" do
      assert Encoding.decode_boolean(1) == {:ok, true}
      assert Encoding.decode_boolean(0) == {:ok, false}
    end
  end

  describe "unsigned_int" do
    test "returns the value if within the range for 16 bits when encoding" do
      assert Encoding.encode_unsigned_int(0, %Metadata{}) == {:ok, 0}
      assert Encoding.encode_unsigned_int(65535, %Metadata{}) == {:ok, 65535}
    end

    test "returns an error for out-of-range values when encoding" do
      assert {:error, _} = Encoding.encode_unsigned_int(-1, %Metadata{})
      assert {:error, _} = Encoding.encode_unsigned_int(65536, %Metadata{})
      assert {:error, _} = Encoding.encode_unsigned_int(:foo, %Metadata{})
    end

    test "returns the value when decoding" do
      assert {:ok, 0} = Encoding.decode_unsigned_int(0)
      assert {:ok, 65535} = Encoding.decode_unsigned_int(65535)
    end

    test "roundtrips as expected" do
      [0, 65535]
      |> Enum.each(fn number ->
        {:ok, encoded} = Encoding.encode_unsigned_int(number, %Metadata{})
        {:ok, decoded} = Encoding.decode_unsigned_int(encoded)
        assert number == decoded
      end)
    end
  end

  describe "signed_int" do
    test "returns the value if within the range for 16 bits when encoding" do
      assert {:ok, -32768} = Encoding.encode_signed_int(-32768, %Metadata{})
      assert {:ok, 32767} = Encoding.encode_signed_int(32767, %Metadata{})
    end

    test "returns error for out-of-range signed integers when encoding" do
      assert {:error, _} = Encoding.encode_signed_int(-32769, %Metadata{})
      assert {:error, _} = Encoding.encode_signed_int(32768, %Metadata{})
    end

    test "interprets the value as a signed int when decoding" do
      assert {:ok, 32767} = Encoding.decode_signed_int(32767)
      assert {:ok, 0} = Encoding.decode_signed_int(0)
      assert {:ok, -32768} = Encoding.decode_signed_int(-32768)
    end

    test "roundtrips as expected" do
      [-32768, 0, 32767]
      |> Enum.each(fn initial ->
        {:ok, encoded} = Encoding.encode_signed_int(initial, %Metadata{})
        {:ok, decoded} = Encoding.decode_signed_int(encoded)
        assert initial == decoded
      end)
    end
  end

  describe "ascii" do
    test "encodes ASCII text to the expected number of register values" do
      meta = %Metadata{name: :my_mapping, type: :holding_register}

      assert {:ok, [0, 0, 0]} == Encoding.encode_ascii("", %{meta | address_count: 3})
      assert {:ok, [0x4100]} == Encoding.encode_ascii("A", %{meta | address_count: 1})
      assert {:ok, [0x4142]} == Encoding.encode_ascii("AB", %{meta | address_count: 1})
      assert {:ok, [0x4142, 0x4300]} == Encoding.encode_ascii("ABC", %{meta | address_count: 2})
    end

    test "returns an error when attempting to encode more characters than what the mapped registers can hold" do
      meta = %Metadata{name: :some_mapping_name, type: :holding_register, address_count: 2}
      assert {:error, message} = Encoding.encode_ascii("ABCDE", meta)
      assert String.match?(message, ~r/Too many characters/)
    end

    test "returns an error when attempting to encode non-ASCII text" do
      meta = %Metadata{name: :my_mapping, type: :holding_register, address_count: 2}
      assert {:error, message} = Encoding.encode_ascii("José", meta)
      assert String.match?(message, ~r/non-ASCII/i)
    end

    test "decodes ASCII text" do
      assert Encoding.decode_ascii([]) == {:ok, ""}
      assert Encoding.decode_ascii([0x4100]) == {:ok, "A"}
      assert Encoding.decode_ascii([0x4142, 0x4300]) == {:ok, "ABC"}
    end

    test "decode_ascii stops at null terminator" do
      assert Encoding.decode_ascii([0x4142, 0x0043, 0x4445]) == {:ok, "AB"}
    end

    test "roundtrips as expected" do
      [{"", 1}, {"A", 1}, {"AB", 2}, {"ABC", 2}, {"ABCD", 2}, {"A", 4}]
      |> Enum.each(fn {text, count} ->
        meta = %Metadata{name: :my_mapping, type: :holding_register, address_count: count}
        {:ok, encoded} = Encoding.encode_ascii(text, meta)
        {:ok, decoded} = Encoding.decode_ascii(encoded)
        assert text == decoded
      end)
    end
  end
end
