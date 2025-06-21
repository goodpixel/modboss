defmodule ModBoss.Mapping do
  @moduledoc """
  Struct representing the Modbus mapping.
  """

  @type t() :: %__MODULE__{
          name: atom(),
          type: :holding_register | :input_register | :coil | :discrete_input,
          addresses: Range.t(),
          starting_address: integer(),
          register_count: integer(),
          as: atom() | {module(), atom()},
          value: any(),
          encoded_value: integer() | [integer()],
          mode: :r | :rw | :w
        }

  defstruct name: nil,
            type: nil,
            addresses: nil,
            starting_address: nil,
            register_count: nil,
            as: nil,
            value: nil,
            encoded_value: nil,
            mode: :r

  defguardp is_address_or_range(address) when is_integer(address) or is_struct(address, Range)

  @doc false
  def new(module, name, type, addresses, opts \\ [])
      when is_atom(module) and is_atom(name) and is_address_or_range(addresses) and is_list(opts) do
    {address_range, starting_address, register_count} = registers(addresses)
    as = Keyword.get(opts, :as) |> expand_as(module)

    opts =
      Keyword.merge(opts,
        name: name,
        type: type,
        addresses: address_range,
        starting_address: starting_address,
        register_count: register_count,
        as: as
      )

    __MODULE__
    |> struct!(opts)
    |> validate!(:type)
    |> validate!(:mode)
    |> validate!(:as)
  end

  defp expand_as(nil, _schema_module) do
    {ModBoss.Encoding, :raw}
  end

  defp expand_as({module, as}, _schema_module) when is_atom(module) and is_atom(as) do
    {module, as}
  end

  defp expand_as(as, schema_module) when is_atom(as) and is_atom(schema_module) do
    {schema_module, as}
  end

  defp validate!(mapping, :type) do
    case mapping.type do
      :holding_register -> mapping
      :input_register -> mapping
      :discrete_input -> mapping
      :coil -> mapping
      other -> raise("Invalid modbus type: #{inspect(other)}.")
    end
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

  defp validate!(%{as: nil} = mapping, :as), do: mapping

  defp validate!(%{as: {module, func}} = mapping, :as) when is_atom(module) and is_atom(func) do
    mapping
  end

  defp validate!(mapping, field) do
    value = Map.fetch!(mapping, field)
    raise "Invalid ModBoss option #{inspect([{field, value}])} for #{inspect(mapping.name)}."
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
  @doc false
  def readable?(%__MODULE__{} = mapping), do: mapping.mode in @read_modes

  @write_modes [:w, :rw]
  @doc false
  def writable?(%__MODULE__{} = mapping), do: mapping.mode in @write_modes
end
