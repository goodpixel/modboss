defmodule ModBoss do
  @moduledoc """
  Human-friendly modbus reading, writing, and translation.

  Read and write modbus values by name, with automatic decoding and encoding.
  """

  alias ModBoss.Mapping

  @type register_type :: :holding_register | :input_register | :coil | :discrete_input
  @type mapping_name :: atom()
  @type value :: any()
  @type mapping_assignment :: {mapping_name(), value()}
  @type write_func :: (register_type(), integer(), any() -> :ok | {:error, any()})
  @type values_to_write :: %{mapping_name() => value()} | [mapping_assignment()]

  @doc """
  Write modbus registers by name using `write_func`.

  ModBoss automatically encodes your `values`, then batches any encoded values destined for
  contiguous registers—creating separate batches per register type.

  `write_func` must return either `:ok` or an `{:error, reason}` tuple.

  > #### Batch values {: .info}
  >
  > Each batch will contain **either a list or an individual value**, so
  > you should be prepared for either.

  > #### Non-atomic writes! {: .warning}
  >
  > While `ModBoss.write/3` has the _feel_ of being atomic, it's important to recognize that it
  > is not! It's fully possible that a write might fail after prior writes within the same call to
  > `ModBoss.write/3` have already succeeded.
  >
  > Within `ModBoss.write/3`, if any call to `write_func` returns an error tuple,
  > the function will immediately abort, and any subsequent writes will be skipped.

  ## Example

      defmodule DeviceDriver do
        @device_address 101

        defp modbus_pid do
          # …
        end

        # Provide a wrapper function for the Modbus library of your choosing…
        def write(register_type, starting_address, value_or_values) do
          command = case register_type do
            :holding_register -> {:phr, @device_address, starting_address, value_or_values}
            :coil -> {:fc, @device_address, starting_address, value_or_values}
          end

          ModbusLibrary.request(modbus_pid(), command)
        end
      end

      ModBoss.write(DeviceSchema, &DeviceDriver.write/3, %{heat_setpoint: 68, cool_setpoint: 73})
      #=> :ok
  """
  @spec write(module(), write_func(), values_to_write()) :: :ok | {:error, any()}
  def write(module, write_func, values) when is_atom(module) and is_function(write_func) do
    with {:ok, mappings} <- get_mappings(:writable, module, get_keys(values)),
         mappings <- put_values(mappings, values),
         {:ok, mappings} <- encode(mappings),
         {:ok, _mappings} <- write_registers(mappings, write_func) do
      :ok
    end
  end

  defp get_keys(params) when is_map(params), do: Map.keys(params)
  defp get_keys(params) when is_list(params), do: Keyword.keys(params)

  defp put_values(mappings, params) do
    for mapping <- mappings do
      %{mapping | value: params[mapping.name]}
    end
  end

  @spec get_mappings(:writable, module(), list()) :: {:ok, [Mapping.t()]} | {:error, String.t()}
  defp get_mappings(_mode, module, register_names) when is_list(register_names) do
    schema = module.__modbus_schema__()

    {mappings, unknown_names} =
      register_names
      |> Enum.map(fn name ->
        case Map.get(schema, name, :unknown) do
          :unknown -> name
          mapping -> mapping
        end
      end)
      |> Enum.split_with(fn
        %Mapping{} -> true
        _name -> false
      end)

    cond do
      Enum.any?(unknown_names) ->
        names = unknown_names |> Enum.map_join(", ", fn name -> inspect(name) end)
        {:error, "Unknown register(s) #{names} for #{inspect(module)}."}

      Enum.any?(unwritable(mappings)) ->
        names = unwritable(mappings) |> Enum.map_join(", ", fn %{name: name} -> inspect(name) end)
        {:error, "Register(s) #{names} in #{inspect(module)} are not writable."}

      true ->
        {:ok, mappings}
    end
  end

  defp unwritable(mappings), do: Enum.reject(mappings, &Mapping.writable?/1)

  defp write_registers(mappings, write_func) do
    mappings
    |> batch_contiguous_mappings()
    |> Enum.reduce_while(:ok, fn {type, starting_address, batch_values}, :ok ->
      value_or_values =
        case batch_values do
          [single_value] -> single_value
          [_ | _] = multiple_values -> multiple_values
        end

      case write_func.(type, starting_address, value_or_values) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @max_writes_per_batch 120

  @spec batch_contiguous_mappings([Mapping.t()], integer()) ::
          [{register_type(), integer(), [any()]}]
  defp batch_contiguous_mappings(mappings, max_batch_size \\ @max_writes_per_batch) do
    chunk_fun = fn %Mapping{type: type, addresses: %Range{first: address}} = mapping, acc ->
      case acc do
        {[], _count} ->
          {:cont, {[mapping], 1}}

        {[%{type: prior_type, addresses: %{last: prior_address}} | _] = mappings, count}
        when prior_address + 1 == address and prior_type == type and
               count < max_batch_size ->
          {:cont, {[mapping | mappings], count + 1}}

        {mappings, _count} ->
          {:cont, Enum.reverse(mappings), {[mapping], 1}}
      end
    end

    after_fun = fn {mappings, _count} -> {:cont, Enum.reverse(mappings), :ignored} end

    mappings
    |> Enum.sort_by(& &1.starting_address)
    |> Enum.chunk_while({[], 0}, chunk_fun, after_fun)
    |> Enum.map(fn [first | _rest] = batch ->
      Enum.reduce(batch, {first.type, first.starting_address, []}, fn mapping, acc ->
        {type, starting_address, encoded_values} = acc
        {type, starting_address, encoded_values ++ List.wrap(mapping.encoded_value)}
      end)
    end)
  end

  defp encode(mappings) do
    Enum.reduce_while(mappings, {:ok, []}, fn mapping, {:ok, acc} ->
      case encode_value(mapping) do
        {:ok, encoded_value} ->
          updated_mapping = %{mapping | encoded_value: encoded_value}
          {:cont, {:ok, [updated_mapping | acc]}}

        {:error, error} ->
          # error = if is_binary(error), do: error, else: inspect(error)
          message = "Failed to encode #{inspect(mapping.name)}. #{error}"
          {:halt, {:error, message}}
      end
    end)
  end

  defp encode_value(mapping) do
    # Temporary; we'll add a translation layer here to encode the value
    encoded = mapping.value
    value_count = List.wrap(encoded) |> length()

    if mapping.register_count == value_count do
      {:ok, encoded}
    else
      msg = "Encoded value `#{inspect(encoded)}` does not match the expected number of registers."
      {:error, msg}
    end
  end
end
