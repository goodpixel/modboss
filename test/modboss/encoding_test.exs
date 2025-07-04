defmodule ModBoss.EncodingTest do
  use ExUnit.Case, async: true
  doctest ModBoss.Encoding, import: true

  alias ModBoss.Encoding
  alias ModBoss.Mapping

  describe "raw" do
    test "doesn't change the value when encoding" do
      assert Encoding.encode_raw(123, %Mapping{}) == {:ok, 123}
      assert Encoding.encode_raw(:abc, %Mapping{}) == {:ok, :abc}
      assert Encoding.encode_raw([1, 2, 3], %Mapping{}) == {:ok, [1, 2, 3]}
    end

    test "doesn't change the value when decoding" do
      assert Encoding.decode_raw(123) == {:ok, 123}
      assert Encoding.decode_raw(:abc) == {:ok, :abc}
      assert Encoding.decode_raw([1, 2, 3]) == {:ok, [1, 2, 3]}
    end
  end

  describe "boolean" do
    test "encodes true and 1 and false as 0" do
      assert Encoding.encode_boolean(true, %Mapping{}) == {:ok, 1}
      assert Encoding.encode_boolean(false, %Mapping{}) == {:ok, 0}
    end

    test "decodes 1 as true and 0 as false" do
      assert Encoding.decode_boolean(1) == {:ok, true}
      assert Encoding.decode_boolean(0) == {:ok, false}
    end
  end

  describe "unsigned_int" do
    test "returns the value if within the range for 16 bits when encoding" do
      assert Encoding.encode_unsigned_int(0, %Mapping{}) == {:ok, 0}
      assert Encoding.encode_unsigned_int(65535, %Mapping{}) == {:ok, 65535}
    end

    test "returns an error for out-of-range values when encoding" do
      assert {:error, _} = Encoding.encode_unsigned_int(-1, %Mapping{})
      assert {:error, _} = Encoding.encode_unsigned_int(65536, %Mapping{})
      assert {:error, _} = Encoding.encode_unsigned_int(:foo, %Mapping{})
    end

    test "returns the value when decoding" do
      assert {:ok, 0} = Encoding.decode_unsigned_int(0)
      assert {:ok, 65535} = Encoding.decode_unsigned_int(65535)
    end

    test "roundtrips as expected" do
      [0, 65535]
      |> Enum.each(fn number ->
        {:ok, encoded} = Encoding.encode_unsigned_int(number, %Mapping{})
        {:ok, decoded} = Encoding.decode_unsigned_int(encoded)
        assert number == decoded
      end)
    end
  end

  describe "signed_int" do
    test "returns the value if within the range for 16 bits when encoding" do
      assert {:ok, -32768} = Encoding.encode_signed_int(-32768, %Mapping{})
      assert {:ok, 32767} = Encoding.encode_signed_int(32767, %Mapping{})
    end

    test "returns error for out-of-range signed integers when encoding" do
      assert {:error, _} = Encoding.encode_signed_int(-32769, %Mapping{})
      assert {:error, _} = Encoding.encode_signed_int(32768, %Mapping{})
    end

    test "interprets the value as a signed int when decoding" do
      assert {:ok, 32767} = Encoding.decode_signed_int(32767)
      assert {:ok, 0} = Encoding.decode_signed_int(0)
      assert {:ok, -32768} = Encoding.decode_signed_int(-32768)
    end

    test "roundtrips as expected" do
      [-32768, 0, 32767]
      |> Enum.each(fn initial ->
        {:ok, encoded} = Encoding.encode_signed_int(initial, %Mapping{})
        {:ok, decoded} = Encoding.decode_signed_int(encoded)
        assert initial == decoded
      end)
    end
  end

  describe "ascii" do
    test "encodes ASCII text to the expected number of register values" do
      assert {:ok, [0, 0, 0]} == Encoding.encode_ascii("", %Mapping{address_count: 3})
      assert {:ok, [0x4100]} == Encoding.encode_ascii("A", %Mapping{address_count: 1})
      assert {:ok, [0x4142]} == Encoding.encode_ascii("AB", %Mapping{address_count: 1})
      assert {:ok, [0x4142, 0x4300]} == Encoding.encode_ascii("ABC", %Mapping{address_count: 2})
    end

    test "returns an error when attempting to encode more characters than what the mapped registers can hold" do
      mapping = %Mapping{name: :my_mapping, address_count: 2}
      assert {:error, message} = Encoding.encode_ascii("ABCDE", mapping)
      assert String.match?(message, ~r/too many characters/)
    end

    test "returns an error when attempting to encode non-ASCII text" do
      assert {:error, message} = Encoding.encode_ascii("José", %Mapping{address_count: 2})
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
        {:ok, encoded} = Encoding.encode_ascii(text, %Mapping{name: :foo, address_count: count})
        {:ok, decoded} = Encoding.decode_ascii(encoded)
        assert text == decoded
      end)
    end
  end
end
