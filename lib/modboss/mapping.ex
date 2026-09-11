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
          supported: boolean() | (map() -> boolean() | {false, any()}),
          requested: boolean(),
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
    :supported,
    :requested,
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
    supported = Keyword.get(opts, :supported, true)

    opts =
      Keyword.merge(opts,
        mode: mode,
        name: name,
        type: type,
        starting_address: address_range.first,
        address_count: address_range.last - address_range.first + 1,
        as: as,
        gap_safe: gap_safe,
        supported: supported,
        requested: false
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

  @doc """
  Checks whether the starting address for `a` comes before `b`
  """
  defguard is_ordered(a, b) when a.starting_address < b.starting_address

  @doc """
  Checks whether two mappings are of the same type and `a` directly follows `b`
  """
  defguard is_adjacent(a, b)
           when a.type == b.type and
                  is_ordered(a, b) and
                  a.starting_address + a.address_count == b.starting_address

  @doc """
  Returns the number of addresses between two mappings.

  Returns `{:error, :disparate_types}` if the mappings aren't the same type.
  """
  def gap_size(%__MODULE__{} = a, %__MODULE__{} = b) when is_adjacent(a, b), do: 0

  def gap_size(%__MODULE__{type: t} = a, %__MODULE__{type: t} = b) when is_ordered(a, b) do
    b.starting_address - (a.starting_address + a.address_count)
  end

  def gap_size(%__MODULE__{type: t1}, %__MODULE__{type: t2}) when t1 != t2 do
    {:error, :disparate_types}
  end

  @read_modes [:r, :rw]
  @doc false
  def readable?(%__MODULE__{} = mapping), do: mapping.mode in @read_modes

  @write_modes [:w, :rw]
  @doc false
  def writable?(%__MODULE__{} = mapping), do: mapping.mode in @write_modes

  @doc """
  Evaluates whether or not the `mapping` is supported given the `context`
  """
  def supported?(%__MODULE__{} = mapping, %{} = context) do
    evaluate_support(mapping, context).supported == true
  end

  @doc false
  def evaluate_support(%__MODULE__{supported: true} = mapping, _), do: mapping

  def evaluate_support(%__MODULE__{supported: false} = mapping, _) do
    %{mapping | gap_safe: false}
  end

  def evaluate_support(%__MODULE__{supported: fun, name: name} = mapping, %{} = context)
      when is_function(fun, 1) do
    case fun.(context) do
      true -> %{mapping | supported: true}
      false -> %{mapping | supported: false, gap_safe: false}
      {false, custom_value} -> %{mapping | supported: false, value: custom_value, gap_safe: false}
      invalid -> raise_invalid_condition(name, context, invalid)
    end
  rescue
    e in FunctionClauseError ->
      f = Function.info(fun)

      if e.module == f[:module] and e.function == f[:name] and e.arity == f[:arity] do
        raise """
        Conditional evaluation of `#{inspect(name)}` failed with no matching clause. \
        Make sure your context always includes the necessary values for determining conditional \
        support or include a fallback clause. Provided context was: #{inspect(context)}.
        """
      else
        reraise e, __STACKTRACE__
      end
  end

  defp raise_invalid_condition(name, context, return_value) do
    raise """
    Invalid return from conditional evaluation on mapping #{inspect(name)} with context: \
    #{inspect(context)}.

    Conditional mappings must return `true` for mappings that are supported for the given context \
    and either `false` or `{false, custom_value}` for mappings that aren't supported. \
    Got #{inspect(return_value)}.
    """
  end
end
