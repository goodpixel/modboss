defmodule ModBoss.Encoding do
  @moduledoc """
  Built-in encoding/decoding functions

  The following encoders are provided out of the box to get you started.
  * ascii
  * boolean
  * signed_int
  * unsigned_int

  To use them, pass them along with this module name to the `:as` option. For example:

      schema do
        holding_register 1..5, :model, as: {ModBoss.Encoding, :ascii}
      end

  """
  import Bitwise
  alias ModBoss.Encoding.Metadata

  @doc false
  def encode_raw(value_or_values, _), do: {:ok, value_or_values}

  @doc false
  def decode_raw(value_or_values), do: {:ok, value_or_values}

  @doc """
  Encode `true` as `1` and `false` as `0`

  ## Examples

      iex> encode_boolean(true, %{})
      {:ok, 1}

      iex> encode_boolean(false, %{})
      {:ok, 0}
  """
  @spec encode_boolean(boolean(), Metadata.t()) :: {:ok, integer()} | {:error, binary()}
  def encode_boolean(true, _metadata), do: {:ok, 1}
  def encode_boolean(false, _metadata), do: {:ok, 0}

  @doc """
  Interpret `1` as `true` and `0` as `false`

  ## Examples

      iex> decode_boolean(0)
      {:ok, false}

      iex> decode_boolean(1)
      {:ok, true}
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
  @spec encode_unsigned_int(non_neg_integer(), Metadata.t()) ::
          {:ok, non_neg_integer()} | {:error, binary()}
  def encode_unsigned_int(value, _metadata) when value >= 0 and value <= 65_535 do
    {:ok, value}
  end

  def encode_unsigned_int(value, _metadata) do
    {:error, "Value #{value} is outside the range of a 16-bit unsigned integer (0 to 65,535)"}
  end

  @doc """
  Decode `value` to an unsigned integer.

  ## Examples

      iex> decode_unsigned_int(65_535)
      {:ok, 65_535}
  """
  @spec decode_unsigned_int(non_neg_integer()) :: {:ok, non_neg_integer()}
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
  @spec encode_signed_int(integer(), Metadata.t()) :: {:ok, integer()} | {:error, binary()}
  def encode_signed_int(value, _metadata)
      when is_integer(value) and value >= -32768 and value <= 32767 do
    {:ok, value}
  end

  def encode_signed_int(value, _metadata) do
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

      iex> metadata = %ModBoss.Encoding.Metadata{type: :holding_register, address_count: 3}
      iex> encode_ascii("Hi!", metadata)
      {:ok, [18537, 8448, 0]}

      iex> metadata = %ModBoss.Encoding.Metadata{type: :holding_register, address_count: 1}
      iex> {:error, reason} = encode_ascii("Hi!", metadata)
      iex> String.match?(reason, ~r/Too many characters/)
      true
  """
  @spec encode_ascii(binary(), Metadata.t()) :: {:ok, list(integer())} | {:error, binary()}
  def encode_ascii(text, %Metadata{type: :holding_register} = metadata) when is_binary(text) do
    with :ok <- verify_ascii(text, metadata),
         {:ok, chars} <- get_chars(text),
         {:ok, padded_chars} <- pad(chars, text, metadata),
         registers <- chars_to_registers(padded_chars) do
      {:ok, registers}
    end
  end

  defp verify_ascii(text, %Metadata{name: name}) do
    text
    |> String.to_charlist()
    |> Enum.all?(fn c -> c >= 0 and c < 127 end)
    |> case do
      true -> :ok
      false -> {:error, "Non-ASCII characters in #{text} for ModBoss mapping #{inspect(name)}."}
    end
  end

  defp get_chars(text) do
    {:ok, :binary.bin_to_list(text)}
  end

  defp pad(chars, text, %Metadata{name: name, address_count: address_count}) do
    max_chars = address_count * 2
    pad_count = max_chars - length(chars)

    if pad_count < 0 do
      message = """
      Too many characters in #{inspect(text)} for ModBoss mapping #{inspect(name)}. \
      With #{address_count} registers, it can hold up to #{max_chars} ASCII characters.\
      """

      {:error, message}
    else
      {:ok, chars ++ List.duplicate(0, pad_count)}
    end
  end

  defp chars_to_registers(chars) when is_list(chars) and rem(length(chars), 2) == 0 do
    chars
    |> Enum.chunk_every(2, 2)
    |> Enum.map(fn [upper_byte, lower_byte] -> (upper_byte <<< 8) + lower_byte end)
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
