defmodule ModBoss.Mapping do
  @type t() :: %__MODULE__{}

  @enforce_keys [:name, :type, :addresses, :starting_address, :register_count]
  defstruct name: nil,
            type: nil,
            addresses: nil,
            starting_address: nil,
            register_count: nil,
            encoded_value: nil,
            value: nil,
            mode: :r

  defguardp is_address_or_range(address) when is_integer(address) or is_struct(address, Range)

  def new(name, type, addresses, opts \\ [])
      when is_atom(name) and is_address_or_range(addresses) and is_list(opts) do
    {address_range, starting_address, register_count} = registers(addresses)

    opts =
      Keyword.merge(opts,
        name: name,
        type: type,
        addresses: address_range,
        starting_address: starting_address,
        register_count: register_count
      )

    __MODULE__
    |> struct!(opts)
    |> validate!(:mode)
  end

  defp validate!(mapping, :mode) do
    case {mapping.type, mapping.mode} do
      {:holding_register, mode} when mode in [:r, :rw, :w] -> mapping
      {:input_register, :r} -> mapping
      {:discrete_input, :r} -> mapping
      {:coil, mode} when mode in [:r, :rw, :w] -> mapping
      {type, mode} -> raise("Invalid mode #{inspect(mode)} for #{type} #{inspect(mapping.name)}")
    end
  end

  defp registers(addresses) do
    range =
      case addresses do
        %Range{step: 1} -> addresses
        %Range{step: _other} -> raise("Only address ranges with step `1` are supported.")
        address when is_integer(address) -> address..address
      end

    {range, range.first, range.last - range.first + 1}
  end

  @read_modes [:r, :rw]
  def readable?(%__MODULE__{} = mapping), do: mapping.mode in @read_modes

  @write_modes [:w, :rw]
  def writable?(%__MODULE__{} = mapping), do: mapping.mode in @write_modes
end
