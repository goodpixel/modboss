defmodule ModBoss.Encoding do
  @moduledoc """
  Built-in encoding/decoding functions to get you started.

  To make use of these functions, use the `:as` option in your `ModBoss.Schema` but leave off
  the `encode_` or `decode_` prefix.

  In other words, to use the built-in ASCII translation, specifiy `as: :ascii` in your schema.

  ### Note about that extra arg…

  Note that for built-in `encode_*` functions, we pass not just the value but also the mapping
  itself. That's why you'll see an extra argument passed to these encoders!

  We do this in order to provide more generic and helpful functions out the box (like
  encoding of ASCII, which requires knowledge of how many registers we're encoding for). However,
  when providing your own `encode_*` functions, you'll only be passed the value to be encoded
  (and not the mapping).
  """
  alias ModBoss.Mapping

  import Bitwise

  @doc false
  def encode_raw(value_or_values, _), do: {:ok, value_or_values}

  @doc false
  def decode_raw(value_or_values), do: {:ok, value_or_values}

  @doc """
  Encode `true` as `1` and `false` as `0`
  """
  @spec encode_boolean(boolean(), Mapping.t()) :: {:ok, integer()} | {:error, binary()}
  def encode_boolean(true, _mapping), do: {:ok, 1}
  def encode_boolean(false, _mapping), do: {:ok, 0}

  @doc """
  Interpret `1` as `true` and `0` as `false`
  """
  @spec decode_boolean(integer()) :: {:ok, boolean()} | {:error, binary()}
  def decode_boolean(1), do: {:ok, true}
  def decode_boolean(0), do: {:ok, false}

  @doc """
  Encode `value` as an unsigned integer.

  Valid values are 0 to 65,535.

  This function assumes the expected output is a regular Elixir integer. It simply provides a
  guard against overly large values, then returns the provided value.

  ## Examples

      iex> {:ok, 65_535} = encode_unsigned_int(65_535, %{})
      iex> {:error, _too_large} = encode_unsigned_int(65_536, %{})
  """
  @spec encode_unsigned_int(integer(), Mapping.t()) :: {:ok, integer()} | {:error, binary()}
  def encode_unsigned_int(value, _mapping) when value >= 0 and value <= 65_535 do
    {:ok, value}
  end

  def encode_unsigned_int(value, _mapping) do
    {:error, "Value #{value} is outside the range of a 16-bit unsigned integer (0 to 65,535)"}
  end

  @doc """
  Decode `value` to an unsigned integer.

  ## Examples

      iex> decode_unsigned_int(65_535)
      {:ok, 65_535}
  """
  @spec decode_unsigned_int(integer()) :: {:ok, integer()}
  def decode_unsigned_int(value) do
    <<decoded_value::unsigned-integer-size(16)>> = <<value::16>>
    {:ok, decoded_value}
  end

  @doc """
  Encode `value` as a signed integer.

  Valid values are -32,768 to 32,767.

  This function assumes the expected output is a regular Elixir integer. It simply provides a
  guard against overly large values, then returns the provided value.

  ## Examples

      iex> {:ok, -32_768} = encode_signed_int(-32_768, %{})
      iex> {:error, _too_large} = encode_signed_int(32_768, %{})
  """
  @spec encode_signed_int(integer(), Mapping.t()) :: {:ok, integer()} | {:error, binary()}
  def encode_signed_int(value, _mapping)
      when is_integer(value) and value >= -32768 and value <= 32767 do
    {:ok, value}
  end

  def encode_signed_int(value, _mapping) do
    {:error, "Value #{value} is outside the range of a 16-bit signed integer (-32768 to 32767)"}
  end

  @doc """
  Decode `value` to a signed integer.

  ## Examples

      iex> decode_signed_int(77)
      {:ok, 77}

      iex> decode_signed_int(65_535)
      {:ok, -1}
  """
  @spec decode_signed_int(integer()) :: {:ok, integer()}
  def decode_signed_int(value) when is_integer(value) do
    <<decoded_value::signed-integer-size(16)>> = <<value::16>>
    {:ok, decoded_value}
  end

  @doc """
  Encode `text` to integers representing ASCII characters.

  * Prepares zero or more characters to be stored in contiguous registers.
  * Up to 2 ASCII characters can be stored per register.
  * `0` is used as a terminator if fewer than the maximum characters are encoded.
  * The `ModBoss.Mapping` is required in order to determine how many characters are supported.

  ## Examples

      iex> encode_ascii("Hi!", %ModBoss.Mapping{register_count: 3})
      {:ok, [18537, 8448, 0]}

      iex> {:error, _too_many_characters} = encode_ascii("Hi!", %ModBoss.Mapping{register_count: 1})
  """
  @spec encode_ascii(binary(), Mapping.t()) :: {:ok, list(integer())} | {:error, binary()}
  def encode_ascii(text, %Mapping{} = mapping) do
    with :ok <- verify_ascii(text),
         {:ok, chars} <- get_chars(text),
         {:ok, padded_chars} <- pad(chars, mapping) do
      do_encode_ascii(padded_chars)
    end
  end

  defp do_encode_ascii(chars) when is_list(chars) do
    chars
    |> Enum.chunk_every(2, 2)
    |> Enum.map(fn [upper_byte, lower_byte] -> (upper_byte <<< 8) + lower_byte end)
    |> then(&{:ok, &1})
  end

  defp verify_ascii(text) do
    text
    |> String.to_charlist()
    |> Enum.all?(fn c -> c >= 0 and c < 127 end)
    |> case do
      true -> :ok
      false -> {:error, "Text contains non-ASCII characters."}
    end
  end

  defp get_chars(text) do
    {:ok, :binary.bin_to_list(text)}
  end

  defp pad(chars, mapping) do
    max_chars = mapping.register_count * 2
    pad_count = max_chars - length(chars)

    if pad_count < 0 do
      message = """
      Text for #{inspect(mapping.name)} contains too many characters. \
      With #{mapping.register_count} registers, it can hold up to #{max_chars} ASCII characters.\
      """

      {:error, message}
    else
      {:ok, chars ++ List.duplicate(0, pad_count)}
    end
  end

  @doc """
  Decode integer `value`(s) representing ASCII characters to text

  * Up to 2 ASCII characters are stored per register.
  * `0` is interpreted as a terminator.

  ## Examples

      iex> decode_ascii(18537)
      {:ok, "Hi"}

      iex> decode_ascii([18537, 8448, 0])
      {:ok, "Hi!"}
  """
  @spec decode_ascii(integer() | list(integer())) :: {:ok, binary()}
  def decode_ascii(value) when is_integer(value) or is_list(value) do
    # Split each 16-bit register into two bytes (i.e. two ASCII characters).
    value
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
