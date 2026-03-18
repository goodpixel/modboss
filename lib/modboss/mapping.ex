defmodule ModBoss.Mapping do
  @moduledoc """
  Struct representing a modbus mapping.
  """

  @type name() :: atom()
  @type object_type :: :holding_register | :input_register | :coil | :discrete_input
  @type address :: non_neg_integer()
  @type count :: pos_integer()

  @type t() :: %__MODULE__{
          name: name(),
          type: object_type(),
          starting_address: address(),
          address_count: count(),
          as: atom() | {module(), atom()},
          value: any(),
          encoded_value: integer() | [integer()],
          mode: :r | :rw | :w,
          gap_safe: boolean()
        }

  defstruct [
    :name,
    :type,
    :starting_address,
    :address_count,
    :as,
    :value,
    :encoded_value,
    :mode,
    :gap_safe
  ]

  defguardp is_address_or_range(address) when is_integer(address) or is_struct(address, Range)

  @doc false
  def new(module, name, type, addresses, opts \\ [])
      when is_atom(module) and is_atom(name) and is_address_or_range(addresses) and is_list(opts) do
    address_range =
      case addresses do
        %Range{step: 1} -> addresses
        %Range{step: _other} -> raise("Only address ranges with step `1` are supported.")
        address when is_integer(address) -> address..address
      end

    as = Keyword.get(opts, :as) |> expand_as(module)
    mode = Keyword.get(opts, :mode, :r)
    gap_safe = Keyword.get_lazy(opts, :gap_safe, fn -> mode in [:r, :rw] end)

    opts =
      Keyword.merge(opts,
        mode: mode,
        name: name,
        type: type,
        starting_address: address_range.first,
        address_count: address_range.last - address_range.first + 1,
        as: as,
        gap_safe: gap_safe
      )

    __MODULE__
    |> struct!(opts)
    |> validate!(:type)
    |> validate!(:mode)
    |> validate!(:as)
    |> validate!(:gap_safe)
  end

  @doc """
  Get the Range of addresses for the given `ModBoss.Mapping`
  """
  def address_range(%__MODULE__{starting_address: start, address_count: count}) do
    start..(start + count - 1)
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

  defp validate!(%{gap_safe: false} = mapping, :gap_safe), do: mapping

  defp validate!(%{gap_safe: true, mode: :w} = mapping, :gap_safe) do
    raise "gap_safe: true is not allowed on write-only mapping #{inspect(mapping.name)}"
  end

  defp validate!(%{gap_safe: true} = mapping, :gap_safe), do: mapping

  defp validate!(%{as: nil} = mapping, :as), do: mapping

  defp validate!(%{as: {module, func}} = mapping, :as) when is_atom(module) and is_atom(func) do
    mapping
  end

  defp validate!(mapping, field) do
    value = Map.fetch!(mapping, field)
    raise "Invalid ModBoss option #{inspect([{field, value}])} for #{inspect(mapping.name)}."
  end

  @read_modes [:r, :rw]
  @doc false
  def readable?(%__MODULE__{} = mapping), do: mapping.mode in @read_modes

  @write_modes [:w, :rw]
  @doc false
  def writable?(%__MODULE__{} = mapping), do: mapping.mode in @write_modes
end
