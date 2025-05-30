defmodule ModBoss.Encoding do
  import Bitwise

  @doc false
  def encode_raw(value_or_values), do: {:ok, value_or_values}

  @doc false
  def decode_raw(value_or_values), do: {:ok, value_or_values}

  @doc """
  Interpret a single `raw_value` as an unsigned integer
  """
  def decode_unsigned_int(raw_value) do
    <<value::unsigned-integer-size(16)>> = <<raw_value::16>>
    {:ok, value}
  end

  @doc """
  Interpret a single `raw_value` as a signed integer
  """
  def decode_signed_int(raw_value) do
    <<value::signed-integer-size(16)>> = <<raw_value::16>>
    {:ok, value}
  end

  @doc """
  Encode text to ASCII

  * A `0` is used as a terminator if fewer than the maximum characters are encoded
    given the number of registers claimed by the mapping.
  """
  def encode_ascii(text) when is_binary(text) do
    text
    |> :binary.bin_to_list()
    |> Enum.chunk_every(2, 2, [0])
    |> Enum.map(fn [upper_byte, lower_byte] -> (upper_byte <<< 8) + lower_byte end)
    |> then(&{:ok, &1})
  end

  @doc """
  Decode ASCII to text

  * A `0` is expected as a terminator if fewer than the maximum characters are encoded
    given the number of registers claimed by the mapping.
  """
  def decode_ascii(raw_values) do
    # Split each 16-bit register into two bytes (i.e. two ASCII characters).
    raw_values
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      <<upper_byte::8, lower_byte::8>> = <<value::unsigned-integer-size(16)>>
      [upper_byte, lower_byte]
    end)
    |> Enum.take_while(&(&1 != 0))
    |> List.to_string()
    |> then(&{:ok, &1})
  end
end
