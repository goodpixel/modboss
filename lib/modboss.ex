defmodule ModBoss do
  @moduledoc """
  Human-friendly modbus reading, writing, and translation.

  Read and write modbus values by name, with automatic encoding and decoding.
  """

  alias ModBoss.Mapping

  @typep mode :: :readable | :writable
  @type register_type :: :holding_register | :input_register | :coil | :discrete_input
  @type mapping_assignment :: {name :: atom(), any()}
  @type read_func :: (register_type(), starting_address :: integer(), count :: integer() ->
                        {:ok, any()} | {:error, any()})
  @type write_func :: (register_type(), starting_address :: integer(), value_or_values :: any() ->
                         :ok | {:error, any()})
  @type values_to_write :: mapping_assignment() | [mapping_assignment()]

  @doc """
  Read modbus registers from the schema in `module` using `read_func`.
  """
  def read_all(module, read_func) do
    names = module.__modbus_schema__() |> Map.keys()
    read(module, read_func, names)
  end

  @doc """
  Read modbus registers from the schema in `module` by name.

  This function takes either an atom or a list of atoms representing the mappings to read.
  If a single atom is provided, the result will be an :ok tuple including the singular value
  for that named mapping. If a list of atoms is given, the result will be an :ok tuple including
  a map with mapping names as keys and mapping values as results.

  ModBoss batches reads for contiguous registers of the same type.

  ## Opts
  * `:translate` — returns the translated value if `true` or the raw register value(s) if false
    (defaults to `true`)

  ## Examples

      # Read a single mapping
      ModBoss.read(
        SchemaModule,
        fn
          register_type, starting_address, count -> some_read_logic(...)
        end,
        :mapping1
      )
      1234

      # Read multiple mappings
      ModBoss.read(
        SchemaModule,
        fn
          register_type, starting_address, count -> some_read_logic(...)
        end,
        [:mapping1, :mapping2, :mapping3]
      )
      %{mapping1: 1234, mapping2: 2345, mapping3: 3456}
  """
  @spec read(module(), read_func(), atom() | [atom()]) :: {:ok, any()} | {:error, any()}
  def read(module, read_func, name_or_names) do
    {names, plurality} =
      case name_or_names do
        name when is_atom(name) -> {[name], :singular}
        names when is_list(names) -> {names, :plural}
      end

    with {:ok, mappings} <- get_mappings(:readable, module, names),
         {:ok, mappings} <- read_registers(module, mappings, read_func),
         {:ok, mappings} <- decode(mappings) do
      collect_results(mappings, plurality)
    end
  end

  defp collect_results(mappings, plurality) do
    mappings
    |> Enum.map(&{&1.name, Map.get(&1, :value)})
    |> then(fn results ->
      case {results, plurality} do
        {[{_, return_value}], :singular} -> {:ok, return_value}
        {results, :plural} -> {:ok, Enum.into(results, %{})}
      end
    end)
  end

  @doc """
  Write modbus registers by name using `write_func`.

  ModBoss automatically encodes your `values`, then batches any encoded values destined for
  contiguous registers—creating separate batches per register type.

  `write_func` must return either `:ok` or an `{:error, reason}` tuple.

  > #### Batch values {: .info}
  >
  > Each batch will contain **either a list or an individual value** based on the number of
  > addresses to be written—so you should be prepared for both.

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
         {:ok, _mappings} <- write_registers(module, mappings, write_func) do
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

  @spec get_mappings(mode(), module(), list()) :: {:ok, [Mapping.t()]} | {:error, String.t()}
  defp get_mappings(mode, module, register_names) when is_list(register_names) do
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

      mode == :readable and Enum.any?(unreadable(mappings)) ->
        names = unreadable(mappings) |> Enum.map_join(", ", fn %{name: name} -> inspect(name) end)
        {:error, "Register(s) #{names} in #{inspect(module)} are not readable."}

      mode == :writable and Enum.any?(unwritable(mappings)) ->
        names = unwritable(mappings) |> Enum.map_join(", ", fn %{name: name} -> inspect(name) end)
        {:error, "Register(s) #{names} in #{inspect(module)} are not writable."}

      true ->
        {:ok, mappings}
    end
  end

  defp unreadable(mappings), do: Enum.reject(mappings, &Mapping.readable?/1)
  defp unwritable(mappings), do: Enum.reject(mappings, &Mapping.writable?/1)

  @spec read_registers(module(), [Mapping.t()], fun) :: {:ok, [Mapping.t()]} | {:error, any()}
  defp read_registers(module, mappings, read_func) do
    with {:ok, all_values} <- do_read_registers(module, mappings, read_func) do
      Enum.map(mappings, fn
        %Mapping{register_count: 1} = mapping ->
          value = Map.fetch!(all_values, mapping.starting_address)
          %{mapping | encoded_value: value}

        %Mapping{register_count: _plural} = mapping ->
          registers = Enum.to_list(mapping.addresses)

          values =
            all_values
            |> Map.take(registers)
            |> Enum.sort_by(fn {address, _value} -> address end)
            |> Enum.map(fn {_address, value} -> value end)

          %{mapping | encoded_value: values}
      end)
      |> then(&{:ok, &1})
    end
  end

  @spec do_read_registers(module(), [Mapping.t()], fun) :: {:ok, map()}
  defp do_read_registers(module, mappings, read_func) do
    mappings
    |> chunk_mappings(module, :read)
    |> Enum.map(fn [first | _rest] = chunk ->
      initial_acc = {first.type, first.starting_address, 0}

      Enum.reduce(chunk, initial_acc, fn mapping, {type, starting_address, register_count} ->
        {type, starting_address, register_count + mapping.register_count}
      end)
    end)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, acc} ->
      case read_batch(read_func, batch) do
        {:ok, values_by_address} -> {:cont, {:ok, Map.merge(acc, values_by_address)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec read_batch(fun(), {any(), integer(), integer()}) :: {:ok, map()} | {:error, any()}
  defp read_batch(read_func, {type, starting_address, register_count}) do
    with {:ok, value_or_values} <- read_func.(type, starting_address, register_count) do
      values = List.wrap(value_or_values)
      value_count = Enum.count(values)

      if value_count != register_count do
        raise "Attempted to read #{register_count} registers starting from address #{starting_address} but received #{value_count} values."
      end

      batch_results =
        values
        |> Enum.with_index(starting_address)
        |> Enum.into(%{}, fn {value, address} -> {address, value} end)

      {:ok, batch_results}
    end
  end

  defp write_registers(module, mappings, write_func) do
    mappings
    |> chunk_mappings(module, :write)
    |> Enum.map(fn [first | _rest] = chunk ->
      Enum.reduce(chunk, {first.type, first.starting_address, []}, fn mapping, acc ->
        {type, starting_address, encoded_values} = acc
        {type, starting_address, encoded_values ++ List.wrap(mapping.encoded_value)}
      end)
    end)
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

  @spec chunk_mappings([Mapping.t()], module(), :read | :write) ::
          [{register_type(), integer(), [any()]}]
  defp chunk_mappings(mappings, module, mode) do
    chunk_fun = fn %Mapping{type: type, addresses: %Range{first: address}} = mapping, acc ->
      max_chunk = module.__max_batch__(mode, type)

      case acc do
        {[], 0} when mapping.register_count <= max_chunk ->
          {:cont, {[mapping], mapping.register_count}}

        {[prior | _] = mappings, count}
        when prior.addresses.last + 1 == address and count + mapping.register_count <= max_chunk ->
          {:cont, {[mapping | mappings], count + mapping.register_count}}

        {mappings, _count} when mapping.register_count <= max_chunk ->
          {:cont, Enum.reverse(mappings), {[mapping], mapping.register_count}}

        {_, _} when mapping.register_count > max_chunk ->
          raise "Modbus mapping #{inspect(mapping.name)} exceeds the max #{mode} batch size of #{max_chunk} registers."
      end
    end

    after_fun = fn {mappings, _count} -> {:cont, Enum.reverse(mappings), :ignored} end

    mappings
    |> Enum.group_by(& &1.type)
    |> Enum.flat_map(fn {_type, mappings_for_type} ->
      mappings_for_type
      |> Enum.sort_by(& &1.starting_address)
      |> Enum.chunk_while({[], 0}, chunk_fun, after_fun)
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

  defp encode_value(%Mapping{} = mapping) do
    with {module, function, args} <- get_encode_mfa(mapping),
         {:ok, encoded} <- apply(module, function, args),
         :ok <- verify_register_count(mapping, encoded) do
      {:ok, encoded}
    end
  end

  defp get_encode_mfa(%Mapping{as: {module, as}} = mapping) do
    function = String.to_atom("encode_" <> "#{as}")

    # In an effort to keep the API simple, when we call a user-defined encode function,
    # we only pass the value to be encoded.
    #
    # However, when calling built-in encoding functions, we pass both the value to be encoded
    # _and_ the mapping. We do this because in some cases we need to know how many registers
    # we're encoding for in order to provide truly generic encoders. For example, when encoding
    # a string to ASCII, we may need to add padding to fill out the mapped registers.
    arguments =
      case module do
        ModBoss.Encoding -> [mapping.value, mapping]
        _other -> [mapping.value]
      end

    if exists?(module, function, length(arguments)) do
      {module, function, arguments}
    else
      {:error,
       "Modbus mapping #{inspect(mapping.name)} expected #{inspect(module)} to define #{inspect(function)}, but it did not."}
    end
  end

  @spec decode([Mapping.t()]) :: {:ok, [Mapping.t()]}
  defp decode(mappings) do
    Enum.reduce_while(mappings, {:ok, []}, fn mapping, {:ok, acc} ->
      case decode_value(mapping) do
        {:ok, decoded_value} ->
          updated_mapping = %{mapping | value: decoded_value}
          {:cont, {:ok, [updated_mapping | acc]}}
      end
    end)
  end

  defp decode_value(%Mapping{} = mapping) do
    with {module, function, args} <- get_decode_mfa(mapping) do
      apply(module, function, args)
    end
  end

  defp get_decode_mfa(%Mapping{as: {module, as}} = mapping) do
    function = String.to_atom("decode_" <> "#{as}")
    arguments = [mapping.encoded_value]

    if exists?(module, function, length(arguments)) do
      {module, function, arguments}
    else
      {:error,
       "Modbus mapping #{inspect(mapping.name)} expected #{inspect(module)} to define #{inspect(function)}, but it did not."}
    end
  end

  defp verify_register_count(mapping, encoded) do
    expected_count = mapping.register_count

    case List.wrap(encoded) |> length() do
      ^expected_count ->
        :ok

      _ ->
        {:error,
         "Encoded value #{inspect(encoded)} for #{inspect(mapping.name)} does not match the number of registers."}
    end
  end

  defp exists?(module, function, arity) do
    module
    |> ensure_module_loaded!()
    |> function_exported?(function, arity)
  end

  defp ensure_module_loaded!(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> module
      {:error, reason} -> raise("Unable to load #{inspect(module)}: #{inspect(reason)}")
    end
  end
end
