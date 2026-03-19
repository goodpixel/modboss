defmodule ModBoss do
  @moduledoc """
  Human-friendly modbus reading, writing, and translation.

  Read and write modbus values by name, with automatic encoding and decoding.

  ## Telemetry

  ModBoss optionally emits telemetry events for reads and writes via the
  [`:telemetry`](https://hex.pm/packages/telemetry) library. See
  `ModBoss.Telemetry` for all event names, measurements, and metadata.
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
    * `:max_gap` — Allows reading across unrequested gaps to reduce the overall
      number of requests that need to be made. Results from gaps will be
      retrieved and discarded. This value can be specified as a single integer
      (which applies to all types) or per object type. Only readable ModBoss
      mappings will be included in gap reads. To opt a readable mapping out of
      gap reads, specify `gap_safe: false` on that mapping. See the `:gap_safe`
      option in `ModBoss.Schema` for details.
    * `:debug` — if `true`, returns a map of mapping details instead of just the value;
      defaults to `false`
    * `:decode` — if `false`, ModBoss doesn't attempt to decode the retrieved values;
      defaults to `true`. This option can be especially useful if you need insight
      into a particular value that is failing to decode as expected.
    * `:max_attempts` — maximum number of times each `read_func` callback will
      be attempted before giving up. Defaults to `1` (no retries). Callbacks that
      raise an exception or return an error tuple will trigger a retry.
    * `:telemetry_label` — an arbitrary term attached as `label` in telemetry
      event metadata. Useful for identifying which device or connection a
      request belongs to. See `ModBoss.Telemetry` for details.

  > #### Callback exceptions are rescued {: .warning}
  >
  > If `read_func` raises an exception, ModBoss rescues it and returns
  > `{:error, exception}`. This applies regardless of the `:max_attempts`
  > setting. The exception and stacktrace will be available via
  > [per-callback telemetry events](`ModBoss.Telemetry`).

  > #### Gaps {: .info}
  >
  > Every Modbus request incurs network round-trip overhead, so fewer, larger reads
  > are often faster than many small ones—even if some of the addresses in between
  > aren't needed.
  >
  > The `:max_gap` option allows you to specify how many unrequested addresses
  > you're willing to include in a single read in order to bridge the gap between
  > requested mappings and reduce the total number of requests.
  > If enabled, **a single request may bridge multiple gaps, each up to that size.**
  >
  > A gap will only be bridged if **every** address within it belongs to a
  > known, gap-safe mapping (`gap_safe: true`, the default for readable mappings).
  > Unmapped addresses and mappings with `gap_safe: false` both prevent a gap
  > from being bridged.
  >
  > For example, given this schema:
  >
  >     schema do
  >       holding_register 1, :temp, as: {ModBoss.Encoding, :signed_int}
  >       holding_register 2, :status, as: {ModBoss.Encoding, :unsigned_int}
  >       holding_register 3, :error_count, as: {ModBoss.Encoding, :unsigned_int}, gap_safe: false
  >       holding_register 4, :mode, as: {ModBoss.Encoding, :unsigned_int}
  >       holding_register 5, :humidity, as: {ModBoss.Encoding, :unsigned_int}
  >     end
  >
  > Reading `:temp` and `:humidity` with `max_gap: 5` will **not** batch them
  > into a single request because address 3 (`:error_count`) is not gap-safe.
  > Removing `:error_count` from the schema wouldn't help either—the address
  > would then be unmapped, which also prevents bridging.

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

      # Enable reading extra registers to reduce the number of requests
      ModBoss.read(SchemaModule, read_func, [:foo, :bar], max_gap: 10)
      {:ok, %{foo: 75, bar: "ABC"}}

      # …or allow reading across different gap sizes per type
      ModBoss.read(SchemaModule, read_func, [:foo, :bar], max_gap: %{holding_registers: 10})
      {:ok, %{foo: 75, bar: "ABC"}}

      # Get "raw" Modbus values (as returned by `read_func`)
      ModBoss.read(SchemaModule, read_func, decode: false)
      {:ok, bar: [16706, 17152]}
  """
  @spec read(module(), read_func(), atom() | [atom()], keyword()) ::
          {:ok, any()} | {:error, any()}
  def read(module, read_func, name_or_names, opts \\ []) do
    {names, opts} = evaluate_read_opts(module, name_or_names, opts)

    with {:ok, mappings} <- get_mappings(:readable, module, names) do
      do_reads(module, mappings, read_func, opts, names)
    end
  end

  defp evaluate_read_opts(module, name_or_names, opts) do
    {names, plurality} =
      case name_or_names do
        :all -> {readable_mappings(module), :plural}
        name when is_atom(name) -> {[name], :singular}
        names when is_list(names) -> {names, :plural}
      end

    opts =
      case Keyword.split(opts, [:max_gap, :max_attempts, :debug, :decode, :telemetry_label]) do
        {opts, []} -> Keyword.put(opts, :plurality, plurality)
        {_opts, unsupported_opts} -> raise "Unrecognized opts: #{inspect(unsupported_opts)}"
      end

    validate_max_attempts!(Keyword.get(opts, :max_attempts, 1))

    {names, opts}
  end

  defp readable_mappings(module) do
    module.__modboss_schema__()
    |> Enum.filter(fn {_, mapping} -> Mapping.readable?(mapping) end)
    |> Enum.map(fn {name, _mapping} -> name end)
  end

  if Code.ensure_loaded?(:telemetry) do
    defp do_reads(module, mappings, read_func, opts, names) do
      label = Keyword.get(opts, :telemetry_label)
      start_metadata = %{schema: module, names: names} |> maybe_put_label(label)

      :telemetry.span([:modboss, :read], start_metadata, fn ->
        {result, stats} = read_mappings(module, mappings, read_func, opts, label)

        stop_measurements = %{
          objects_requested: stats.objects,
          modbus_requests: stats.requests,
          addresses_read: stats.addresses,
          gap_addresses_read: stats.gap_addresses,
          max_gap_size: stats.largest_gap,
          total_attempts: stats.total_attempts
        }

        stop_metadata = Map.put(start_metadata, :result, result)
        {result, stop_measurements, stop_metadata}
      end)
    end

    defp maybe_put_label(metadata, nil), do: metadata
    defp maybe_put_label(metadata, label), do: Map.put(metadata, :label, label)
  else
    defp do_reads(module, mappings, read_func, opts, _names) do
      {result, _} = read_mappings(module, mappings, read_func, opts, _label = nil)
      result
    end
  end

  defp read_mappings(module, mappings, read_func, opts, label) do
    max_gaps = Keyword.get(opts, :max_gap, %{})
    max_attempts = Keyword.get(opts, :max_attempts, 1)
    debug = Keyword.get(opts, :debug, false)
    decode = Keyword.get(opts, :decode, true)
    plurality = Keyword.fetch!(opts, :plurality)
    field_to_return = if decode, do: :value, else: :encoded_value

    {read_result, stats} =
      mappings
      |> chunk_mappings(module, :read, max_gaps)
      |> read_chunks(module, read_func, max_attempts, label)

    with {:ok, values} <- read_result,
         {:ok, mappings} <- hydrate_values(mappings, values),
         {:ok, mappings} <- maybe_decode(mappings, decode) do
      result = collect_results(mappings, plurality, field_to_return, debug)
      {result, stats}
    else
      {:error, _error} = result -> {result, stats}
    end
  end

  defp read_chunks(chunks, module, read_func, max_attempts, label) do
    initial_stats = %{
      objects: 0,
      requests: 0,
      addresses: 0,
      gap_addresses: 0,
      largest_gap: 0,
      total_attempts: 0
    }

    initial = {{:ok, %{}}, initial_stats}

    Enum.reduce_while(chunks, initial, fn {mappings, gap_addresses, largest_gap}, acc ->
      {{:ok, values}, stats} = acc
      [first | _rest] = mappings
      last = List.last(mappings)

      names = Enum.map(mappings, & &1.name)
      starting_address = first.starting_address
      ending_address = last.starting_address + last.address_count - 1
      address_count = ending_address - starting_address + 1
      object_count = Enum.sum_by(mappings, & &1.address_count)

      {result, callback_attempts} =
        read_func
        |> wrap_read_callback(module, names, gap_addresses, largest_gap, max_attempts, label)
        |> read_batch(first.type, starting_address, address_count)

      updated_stats = %{
        objects: stats.objects + object_count,
        requests: stats.requests + 1,
        addresses: stats.addresses + address_count,
        gap_addresses: stats.gap_addresses + gap_addresses,
        largest_gap: max(stats.largest_gap, largest_gap),
        total_attempts: stats.total_attempts + callback_attempts
      }

      case result do
        {:ok, batch_values} -> {:cont, {{:ok, Map.merge(values, batch_values)}, updated_stats}}
        {:error, error} -> {:halt, {{:error, error}, updated_stats}}
      end
    end)
  end

  if Code.ensure_loaded?(:telemetry) do
    defp wrap_read_callback(
           read_func,
           module,
           names,
           gap_addresses,
           largest_gap,
           max_attempts,
           label
         ) do
      fn type, starting_address, address_count ->
        metadata =
          %{
            schema: module,
            names: names,
            object_type: type,
            starting_address: starting_address,
            address_count: address_count
          }
          |> maybe_put_label(label)

        retry(max_attempts, fn attempt ->
          start_metadata = Map.merge(metadata, %{attempt: attempt, max_attempts: max_attempts})

          :telemetry.span([:modboss, :read_callback], start_metadata, fn ->
            result = read_func.(type, starting_address, address_count)
            stop_measurements = %{gap_addresses_read: gap_addresses, max_gap_size: largest_gap}
            stop_metadata = Map.put(start_metadata, :result, result)

            {result, stop_measurements, stop_metadata}
          end)
        end)
      end
    end
  else
    defp wrap_read_callback(read_func, _, _, _, _, max_attempts, _) do
      fn type, starting_address, address_count ->
        retry(max_attempts, fn _attempt ->
          read_func.(type, starting_address, address_count)
        end)
      end
    end
  end

  @spec read_batch(fun(), atom(), non_neg_integer(), pos_integer()) ::
          {{:ok, map()} | {:error, any()}, pos_integer()}
  defp read_batch(read_func, type, starting_address, address_count) do
    {raw_result, attempts} = read_func.(type, starting_address, address_count)

    result =
      with {:ok, value_or_values} <- raw_result do
        values = List.wrap(value_or_values)
        value_count = length(values)

        if value_count != address_count do
          raise "Attempted to read #{address_count} values starting from address #{starting_address} but received #{value_count} values."
        end

        batch_results =
          values
          |> Enum.with_index(starting_address)
          |> Enum.into(%{}, fn {value, address} -> {address, value} end)

        {:ok, batch_results}
      end

    {result, attempts}
  end

  defp hydrate_values(mappings, values) do
    Enum.map(mappings, fn
      %Mapping{address_count: 1} = mapping ->
        encoded_value = Map.fetch!(values, mapping.starting_address)
        %{mapping | encoded_value: encoded_value}

      %Mapping{address_count: _plural} = mapping ->
        addresses = Mapping.address_range(mapping) |> Enum.to_list()

        encoded_values =
          values
          |> Map.take(addresses)
          |> Enum.sort_by(fn {address, _value} -> address end)
          |> Enum.map(fn {_address, value} -> value end)

        %{mapping | encoded_value: encoded_values}
    end)
    |> then(&{:ok, &1})
  end

  defp collect_results(mappings, plurality, field_to_return, _debug = true) do
    mappings
    |> Enum.map(fn %Mapping{} = mapping ->
      debug_map =
        mapping
        |> Map.take([:type, :as, :encoded_value, :mode, :gap_safe])
        |> Map.put(:address_range, Mapping.address_range(mapping))
        |> maybe_put_value(mapping, field_to_return)

      {mapping.name, debug_map}
    end)
    |> handle_plurality(plurality)
  end

  defp collect_results(mappings, plurality, field_to_return, _debug = false) do
    mappings
    |> Enum.map(&{&1.name, Map.fetch!(&1, field_to_return)})
    |> handle_plurality(plurality)
  end

  # If we're not decoding, don't include the `:value` field in the debug output
  defp maybe_put_value(debug_map, mapping, :value), do: Map.put(debug_map, :value, mapping.value)
  defp maybe_put_value(debug_map, _mapping, :encoded_value), do: debug_map

  defp handle_plurality([{_name, value}], :singular), do: {:ok, value}
  defp handle_plurality(values, :plural), do: {:ok, Enum.into(values, %{})}

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

  > #### Callback exceptions are rescued {: .warning}
  >
  > If `write_func` raises an exception, ModBoss rescues it and returns
  > `{:error, exception}`. This applies regardless of the `:max_attempts`
  > setting. The exception and stacktrace will be available via
  > [per-callback telemetry events](`ModBoss.Telemetry`).

  > #### Non-atomic writes! {: .warning}
  >
  > While `ModBoss.write/4` has the _feel_ of being atomic, it's important to recognize that it
  > is not! It's fully possible that a write might fail after prior writes within the same call to
  > `ModBoss.write/4` have already succeeded.
  >
  > Within `ModBoss.write/4`, if any call to `write_func` returns an error tuple,
  > the function will immediately abort, and any subsequent writes will be skipped.

  ## Opts
    * `:max_attempts` — maximum number of times each `write_func` callback will
      be attempted before giving up. Defaults to `1` (no retries). Callbacks that
      raise an exception or return an error tuple will trigger a retry.
    * `:telemetry_label` — an arbitrary term attached as `label` in telemetry
      event metadata. Useful for identifying which device or connection a
      request belongs to. See `ModBoss.Telemetry` for details.

  ## Example

      write_func = fn object_type, starting_address, value_or_values ->
        result = custom_write_logic(…)
        {:ok, result}
      end

      iex> ModBoss.write(MyDevice.Schema, write_func, foo: 75, bar: "ABC")
      :ok
  """
  @spec write(module(), write_func(), values(), keyword()) :: :ok | {:error, any()}
  def write(module, write_func, values, opts \\ [])
      when is_atom(module) and is_function(write_func) do
    names = get_keys(values)
    opts = evaluate_write_opts(opts)

    with {:ok, mappings} <- get_mappings(:writable, module, names),
         mappings <- put_values(mappings, values),
         {:ok, mappings} <- encode(mappings) do
      do_writes(module, mappings, write_func, names, opts)
    end
  end

  defp get_keys(params) when is_map(params), do: Map.keys(params)
  defp get_keys(params) when is_list(params), do: Keyword.keys(params)

  defp evaluate_write_opts(opts) do
    {label, remaining_opts} = Keyword.pop(opts, :telemetry_label)
    {max_attempts, remaining_opts} = Keyword.pop(remaining_opts, :max_attempts, 1)

    if remaining_opts != [] do
      raise "Unrecognized opts: #{inspect(remaining_opts)}"
    end

    validate_max_attempts!(max_attempts)

    [telemetry_label: label, max_attempts: max_attempts]
  end

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
      |> Enum.map(&Map.get(schema, &1, &1))
      |> Enum.split_with(&match?(%Mapping{}, &1))

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

  if Code.ensure_loaded?(:telemetry) do
    defp do_writes(module, mappings, write_func, names, opts) do
      max_attempts = Keyword.get(opts, :max_attempts, 1)
      label = Keyword.get(opts, :telemetry_label)
      start_metadata = %{schema: module, names: names} |> maybe_put_label(label)

      :telemetry.span([:modboss, :write], start_metadata, fn ->
        {result, stats} = write_mappings(module, mappings, write_func, max_attempts, label)

        stop_measurements = %{
          objects_requested: stats.objects,
          modbus_requests: stats.requests,
          total_attempts: stats.total_attempts
        }

        stop_metadata = Map.put(start_metadata, :result, result)
        {result, stop_measurements, stop_metadata}
      end)
    end
  else
    defp do_writes(module, mappings, write_func, _names, opts) do
      max_attempts = Keyword.get(opts, :max_attempts, 1)
      {result, _} = write_mappings(module, mappings, write_func, max_attempts, _label = nil)
      result
    end
  end

  defp write_mappings(module, mappings, write_func, max_attempts, label) do
    initial_stats = %{objects: 0, requests: 0, total_attempts: 0}

    mappings
    |> chunk_mappings(module, :write, 0)
    |> Enum.reduce_while({:ok, initial_stats}, fn chunk, {:ok, stats} ->
      {batched_mappings, _gap_addresses = 0, _largest_gap = 0} = chunk
      [first | _rest] = batched_mappings
      values = Enum.flat_map(batched_mappings, &List.wrap(&1.encoded_value))
      address_count = length(values)

      value_or_values =
        case values do
          [single_value] -> single_value
          [_ | _] = multiple_values -> multiple_values
        end

      names = Enum.map(batched_mappings, & &1.name)

      wrapped_write =
        wrap_write_callback(write_func, module, names, address_count, max_attempts, label)

      {result, attempts} = wrapped_write.(first.type, first.starting_address, value_or_values)

      updated_stats = %{
        objects: stats.objects + address_count,
        requests: stats.requests + 1,
        total_attempts: stats.total_attempts + attempts
      }

      case result do
        :ok -> {:cont, {:ok, updated_stats}}
        {:error, error} -> {:halt, {{:error, error}, updated_stats}}
      end
    end)
  end

  if Code.ensure_loaded?(:telemetry) do
    defp wrap_write_callback(write_func, module, names, address_count, max_attempts, label) do
      fn type, starting_address, value_or_values ->
        metadata =
          %{
            schema: module,
            names: names,
            object_type: type,
            starting_address: starting_address,
            address_count: address_count
          }
          |> maybe_put_label(label)

        retry(max_attempts, fn attempt ->
          start_metadata = Map.merge(metadata, %{attempt: attempt, max_attempts: max_attempts})

          :telemetry.span([:modboss, :write_callback], start_metadata, fn ->
            result = write_func.(type, starting_address, value_or_values)
            stop_measurements = %{}
            stop_metadata = Map.put(start_metadata, :result, result)
            {result, stop_measurements, stop_metadata}
          end)
        end)
      end
    end
  else
    defp wrap_write_callback(write_func, _, _, _, max_attempts, _) do
      fn type, starting_address, value_or_values ->
        retry(max_attempts, fn _attempt ->
          write_func.(type, starting_address, value_or_values)
        end)
      end
    end
  end

  defp retry(max_attempts, func) do
    Enum.reduce_while(1..max_attempts, nil, fn attempt, _prev ->
      result =
        try do
          func.(attempt)
        rescue
          e -> {:error, e}
        end

      case result do
        {:error, _} = error when attempt < max_attempts -> {:cont, error}
        result -> {:halt, {result, attempt}}
      end
    end)
  end

  defp validate_max_attempts!(max_attempts) do
    unless is_integer(max_attempts) and max_attempts >= 1 do
      raise "Invalid max_attempts: #{inspect(max_attempts)}. Must be a positive integer."
    end
  end

  @spec chunk_mappings([Mapping.t()], module(), :read | :write, integer()) ::
          [{Mapping.object_type(), integer(), [any()]}]
  defp chunk_mappings(mappings, module, mode, max_gaps) do
    max_gaps = normalize_max_gap(max_gaps)

    # Build a set of {type, address} pairs for all gap-safe objects.
    # During reads, gap tolerance must only bridge gaps where every address
    # in the gap belongs to a known gap-safe mapping.
    gap_safe_addresses =
      if mode == :read do
        module.__modboss_schema__()
        |> Map.values()
        |> Enum.filter(& &1.gap_safe)
        |> Enum.flat_map(fn mapping ->
          mapping |> Mapping.address_range() |> Enum.map(&{mapping.type, &1})
        end)
        |> MapSet.new()
      end

    initial_acc = {_mappings = [], _address_count = 0, _gap_address_count = 0, _largest_gap = 0}

    chunk_fun = fn %Mapping{} = mapping, acc ->
      max_chunk = module.__max_batch__(mode, mapping.type)

      if mapping.address_count > max_chunk do
        raise "Modbus mapping #{inspect(mapping.name)} exceeds the max #{mode} batch size of #{max_chunk} objects."
      end

      case acc do
        {_mappings = [], _address_count = 0, _gap_address_count = 0, _largest_gap = 0} ->
          {:cont, {[mapping], mapping.address_count, 0, 0}}

        {[prior_mapping | _] = mappings, running_count, running_gap_count, largest_gap} ->
          gap = compute_gap(prior_mapping, mapping)
          max_gap = if mode == :write, do: 0, else: Map.fetch!(max_gaps, mapping.type)
          total_addresses = running_count + gap.size + mapping.address_count

          if total_addresses <= max_chunk and allow_gap?(gap, mode, max_gap, gap_safe_addresses) do
            running_gap_count = running_gap_count + gap.size
            largest_gap = max(largest_gap, gap.size)

            {:cont, {[mapping | mappings], total_addresses, running_gap_count, largest_gap}}
          else
            chunk_to_emit = {Enum.reverse(mappings), running_gap_count, largest_gap}
            new_chunk = {[mapping], mapping.address_count, 0, 0}
            {:cont, chunk_to_emit, new_chunk}
          end
      end
    end

    after_fun = fn {mappings, _address_count, gap_address_count, largest_gap} ->
      {:cont, {Enum.reverse(mappings), gap_address_count, largest_gap}, :ignored}
    end

    mappings
    |> Enum.group_by(& &1.type)
    |> Enum.flat_map(fn {_type, mappings_for_type} ->
      mappings_for_type
      |> Enum.sort_by(& &1.starting_address)
      |> Enum.chunk_while(initial_acc, chunk_fun, after_fun)
    end)
  end

  defp compute_gap(%{type: type} = prior, %{type: type} = current) do
    gap_start = prior.starting_address + prior.address_count
    gap_end = current.starting_address - 1

    %{
      size: current.starting_address - gap_start,
      addresses: MapSet.new(gap_start..gap_end//1, &{current.type, &1})
    }
  end

  defp allow_gap?(gap, mode, max_gap, gap_safe_addresses) when mode in [:read, :write] do
    cond do
      gap.size == 0 -> true
      mode == :write -> false
      mode == :read -> gap.size <= max_gap and MapSet.subset?(gap.addresses, gap_safe_addresses)
    end
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
      {type, size} when is_integer(size) and size >= 0 ->
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
