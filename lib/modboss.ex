defmodule ModBoss do
  @moduledoc """
  Human-friendly modbus reading, writing, and translation.

  Read and write modbus values by name, with automatic encoding and decoding.
  """

  require Logger
  alias ModBoss.Mapping

  @typep mode :: :readable | :writable | :any

  @type read_func :: (Mapping.object_type(),
                      starting_address :: Mapping.address(),
                      count :: Mapping.count() ->
                        {:ok, any()} | {:error, any()})

  @type write_func :: (Mapping.object_type(),
                       starting_address :: Mapping.address(),
                       value_or_values :: any() ->
                         :ok | {:error, any()})

  @type values :: [{atom(), any()}] | %{atom() => any()}

  @object_types [:holding_registers, :input_registers, :coils, :discrete_inputs]

  @doc """
  Read from modbus using named mappings.

  This function takes either an atom or a list of atoms representing the mappings to read,
  batches the mappings into contiguous addresses per type, then reads and decodes the values
  before returning them.

  For each batch, `read_func` will be called with the type of modbus object (`:holding_register`,
  `:input_register`, `:coil`, or `:discrete_input`), the starting address for the batch
  to be read, and the count of addresses to read from. It must return either `{:ok, result}`
  or `{:error, message}`.

  If a single name is requested, the result will be an :ok tuple including the singule result
  for that named mapping. If a list of names is requested, the result will be an :ok tuple
  including a map with mapping names as keys and mapping values as results.

  ## Opts
    * `:decode` — if `false`, returns the "raw" result as provided by `read_func`; defaults to `true`
    * `:max_gap` — gap tolerance for reads. Accepts an integer (applies to all types) or per-type values; defaults to 0

  ## Examples

      read_func = fn object_type, starting_address, count ->
        result = custom_read_logic(…)
        {:ok, result}
      end

      # Read one mapping
      ModBoss.read(SchemaModule, read_func, :foo)
      {:ok, 75}

      # Read multiple mappings
      ModBoss.read(SchemaModule, read_func, [:foo, :bar, :baz])
      {:ok, %{foo: 75, bar: "ABC", baz: true}}

      # Read *all* readable mappings
      ModBoss.read(SchemaModule, read_func, :all)
      {:ok, %{foo: 75, bar: "ABC", baz: true, qux: 1024}}

      # Get "raw" Modbus values (as returned by `read_func`)
      ModBoss.read(SchemaModule, read_func, :all, decode: false)
      {:ok, %{foo: 75, bar: [16706, 17152], baz: 1, qux: 1024}}

      # Allow reading across unrequested gaps during batched reads
      ModBoss.read(SchemaModule, read_func, [:foo, :bar], max_gap: 10)
      {:ok, %{foo: 75, bar: "ABC"}}

      # …or allow reading across different gap sizes per type
      ModBoss.read(SchemaModule, read_func, [:foo, :bar], max_gap: %{coils: 10})
      {:ok, %{foo: 75, bar: "ABC"}}
  """
  @spec read(module(), read_func(), atom() | [atom()], keyword()) ::
          {:ok, any()} | {:error, any()}
  def read(module, read_func, name_or_names, opts \\ []) do
    {names, plurality} =
      case name_or_names do
        :all -> {readable_mappings(module), :plural}
        name when is_atom(name) -> {[name], :singular}
        names when is_list(names) -> {names, :plural}
      end

    should_decode = Keyword.get(opts, :decode, true)
    max_gaps = opts |> Keyword.get(:max_gap, %{}) |> normalize_max_gap()
    field_to_return = if should_decode, do: :value, else: :encoded_value

    with {:ok, mappings} <- get_mappings(:readable, module, names),
         {:ok, mappings} <- read_mappings(module, mappings, read_func, max_gaps),
         {:ok, mappings} <- maybe_decode(mappings, should_decode) do
      collect_results(mappings, plurality, field_to_return)
    end
  end

  defp readable_mappings(module) do
    module.__modboss_schema__()
    |> Enum.filter(fn {_, mapping} -> Mapping.readable?(mapping) end)
    |> Enum.map(fn {name, _mapping} -> name end)
  end

  defp collect_results(mappings, plurality, field_to_return) do
    mappings
    |> Enum.map(&{&1.name, Map.get(&1, field_to_return)})
    |> then(fn results ->
      case {results, plurality} do
        {[{_, return_value}], :singular} -> {:ok, return_value}
        {results, :plural} -> {:ok, Enum.into(results, %{})}
      end
    end)
  end

  @doc """
  Encode values per the mapping without actually writing them.

  This can be useful in test scenarios and enables values to be encoded in bulk without actually
  being written via Modbus.

  Returns a map with keys of the form `{type, address}` and `encoded_value` as values.

  ## Example

      iex> ModBoss.encode(MyDevice.Schema, foo: "Yay")
      {:ok, %{{:holding_register, 15} => 22881, {:holding_register, 16} => 30976}}
  """
  @spec encode(module(), values()) :: {:ok, map()} | {:error, String.t()}
  def encode(module, values) when is_atom(module) do
    with {:ok, mappings} <- get_mappings(:any, module, get_keys(values)),
         mappings <- put_values(mappings, values),
         {:ok, mappings} <- encode(mappings) do
      {:ok, flatten_encoded_values(mappings)}
    end
  end

  defp flatten_encoded_values(mappings) do
    mappings
    |> Enum.flat_map(fn %Mapping{} = mapping ->
      mapping.encoded_value
      |> List.wrap()
      |> Enum.with_index(mapping.starting_address)
      |> Enum.map(fn {value_for_object, address} ->
        {{mapping.type, address}, value_for_object}
      end)
    end)
    |> Enum.into(%{})
  end

  @doc """
  Write to modbus using named mappings.

  ModBoss automatically encodes your `values`, then batches any encoded values destined for
  contiguous objects—creating separate batches per object type.

  For each batch, `write_func` will be called with the type of object (`:holding_register` or
  `:coil`), the starting address for the batch to be written, and a list of values to write.
  It must return either `:ok` or `{:error, message}`.

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

      write_func = fn object_type, starting_address, value_or_values ->
        result = custom_write_logic(…)
        {:ok, result}
      end

      iex> ModBoss.write(MyDevice.Schema, write_func, foo: 75, bar: "ABC")
      :ok
  """
  @spec write(module(), write_func(), values()) :: :ok | {:error, any()}
  def write(module, write_func, values) when is_atom(module) and is_function(write_func) do
    with {:ok, mappings} <- get_mappings(:writable, module, get_keys(values)),
         mappings <- put_values(mappings, values),
         {:ok, mappings} <- encode(mappings),
         {:ok, _mappings} <- write_mappings(module, mappings, write_func) do
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
  defp get_mappings(mode, module, mapping_names) when is_list(mapping_names) do
    schema = module.__modboss_schema__()

    {mappings, unknown_names} =
      mapping_names
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
        {:error, "Unknown mapping(s) #{names} for #{inspect(module)}."}

      mode == :readable and Enum.any?(unreadable(mappings)) ->
        names = unreadable(mappings) |> Enum.map_join(", ", fn %{name: name} -> inspect(name) end)
        {:error, "ModBoss Mapping(s) #{names} in #{inspect(module)} are not readable."}

      mode == :writable and Enum.any?(unwritable(mappings)) ->
        names = unwritable(mappings) |> Enum.map_join(", ", fn %{name: name} -> inspect(name) end)
        {:error, "ModBoss Mapping(s) #{names} in #{inspect(module)} are not writable."}

      true ->
        {:ok, mappings}
    end
  end

  defp unreadable(mappings), do: Enum.reject(mappings, &Mapping.readable?/1)
  defp unwritable(mappings), do: Enum.reject(mappings, &Mapping.writable?/1)

  @spec read_mappings(module(), [Mapping.t()], fun, map()) ::
          {:ok, [Mapping.t()]} | {:error, any()}
  defp read_mappings(module, mappings, read_func, max_gaps) do
    with {:ok, all_values} <- do_read_mappings(module, mappings, read_func, max_gaps) do
      Enum.map(mappings, fn
        %Mapping{address_count: 1} = mapping ->
          value = Map.fetch!(all_values, mapping.starting_address)
          %{mapping | encoded_value: value}

        %Mapping{address_count: _plural} = mapping ->
          addresses = Mapping.address_range(mapping) |> Enum.to_list()

          values =
            all_values
            |> Map.take(addresses)
            |> Enum.sort_by(fn {address, _value} -> address end)
            |> Enum.map(fn {_address, value} -> value end)

          %{mapping | encoded_value: values}
      end)
      |> then(&{:ok, &1})
    end
  end

  @spec do_read_mappings(module(), [Mapping.t()], fun, map()) :: {:ok, map()}
  defp do_read_mappings(module, mappings, read_func, max_gaps) do
    mappings
    |> chunk_mappings(module, :read, max_gaps)
    |> Enum.map(fn [first | _rest] = chunk ->
      last = List.last(chunk)
      starting_address = first.starting_address
      ending_address = last.starting_address + last.address_count - 1
      address_count = ending_address - starting_address + 1

      {first.type, starting_address, address_count}
    end)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, acc} ->
      case read_batch(read_func, batch) do
        {:ok, values_by_address} -> {:cont, {:ok, Map.merge(acc, values_by_address)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec read_batch(fun(), {any(), integer(), integer()}) :: {:ok, map()} | {:error, any()}
  defp read_batch(read_func, {type, starting_address, address_count}) do
    with {:ok, value_or_values} <- read_func.(type, starting_address, address_count) do
      values = List.wrap(value_or_values)
      value_count = Enum.count(values)

      if value_count != address_count do
        raise "Attempted to read #{address_count} values starting from address #{starting_address} but received #{value_count} values."
      end

      batch_results =
        values
        |> Enum.with_index(starting_address)
        |> Enum.into(%{}, fn {value, address} -> {address, value} end)

      {:ok, batch_results}
    end
  end

  defp write_mappings(module, mappings, write_func) do
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

  @spec chunk_mappings([Mapping.t()], module(), :read | :write, map()) ::
          [{Mapping.object_type(), integer(), [any()]}]
  defp chunk_mappings(mappings, module, mode, max_gaps \\ %{}) do
    chunk_fun = fn %Mapping{type: type, starting_address: address} = mapping, acc ->
      max_chunk = module.__max_batch__(mode, type)
      max_gap = if mode == :read, do: Map.fetch!(max_gaps, type), else: 0

      if mapping.address_count > max_chunk do
        raise "Modbus mapping #{inspect(mapping.name)} exceeds the max #{mode} batch size of #{max_chunk} objects."
      end

      case acc do
        {[], 0} ->
          {:cont, {[mapping], mapping.address_count}}

        {[prior | _] = mappings, count} ->
          gap = address - (prior.starting_address + prior.address_count)
          total_with_gap = count + gap + mapping.address_count
          fits_in_current_chunk = gap <= max_gap and total_with_gap <= max_chunk

          if fits_in_current_chunk do
            {:cont, {[mapping | mappings], total_with_gap}}
          else
            {:cont, Enum.reverse(mappings), {[mapping], mapping.address_count}}
          end
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

  defp normalize_max_gap(size) when is_integer(size) do
    normalize_max_gap(%{}, size)
  end

  defp normalize_max_gap(sizes) when is_list(sizes) do
    sizes
    |> Enum.into(%{})
    |> normalize_max_gap()
  end

  defp normalize_max_gap(sizes, default_size \\ 0) when is_map(sizes) do
    {sizes, others} = Map.split(sizes, @object_types)

    Enum.each(others, fn {key, _value} ->
      Logger.warning("Invalid #{inspect(key)} gap size specified")
    end)

    %{
      holding_register: Map.get(sizes, :holding_registers, default_size),
      input_register: Map.get(sizes, :input_registers, default_size),
      coil: Map.get(sizes, :coils, default_size),
      discrete_input: Map.get(sizes, :discrete_inputs, default_size)
    }
    |> Enum.into(%{}, fn
      {type, size} when is_integer(size) ->
        {type, size}

      {type, value} ->
        Logger.warning("Invalid max gap size #{inspect(value)} for #{inspect(type)}")
        {type, default_size}
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
         :ok <- verify_value_count(mapping, encoded) do
      {:ok, encoded}
    end
  end

  defp get_encode_mfa(%Mapping{as: {module, as}} = mapping) do
    function = String.to_atom("encode_" <> "#{as}")

    if exists?(module, function, 2) do
      metadata = ModBoss.Encoding.Metadata.from_mapping(mapping)
      {module, function, [mapping.value, metadata]}
    else
      {:error,
       "Expected #{inspect(module)}.#{function}/2 to be defined for ModBoss mapping #{inspect(mapping.name)}."}
    end
  end

  @spec maybe_decode([Mapping.t()], boolean()) :: {:ok, [Mapping.t()]} | {:error, String.t()}
  defp maybe_decode(mappings, false), do: {:ok, mappings}

  defp maybe_decode(mappings, true) do
    Enum.reduce_while(mappings, {:ok, []}, fn mapping, {:ok, acc} ->
      case decode_value(mapping) do
        {:ok, decoded_value} ->
          updated_mapping = %{mapping | value: decoded_value}
          {:cont, {:ok, [updated_mapping | acc]}}

        {:error, error} ->
          message = "Failed to decode #{inspect(mapping.name)}. #{error}"
          {:halt, {:error, message}}
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

    if exists?(module, function, 1) do
      {module, function, [mapping.encoded_value]}
    else
      {:error,
       "Expected #{inspect(module)}.#{function}/1 to be defined for ModBoss mapping #{inspect(mapping.name)}."}
    end
  end

  defp verify_value_count(mapping, encoded) do
    expected_count = mapping.address_count

    case List.wrap(encoded) |> length() do
      ^expected_count ->
        :ok

      _ ->
        {:error,
         "Encoded value #{inspect(encoded)} for #{inspect(mapping.name)} does not match the number of mapped addresses."}
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
