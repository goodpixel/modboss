defmodule ModBoss.Schema do
  @moduledoc """
  Macros for establishing Modbus schema.

  The schema allows names to be assigned to individual modbus objects or groups
  of contiguous modbus objects along with encoder/decoder functions. It also
  allows objects to be flagged as readable and/or writable.

  ## Naming a mapping

  You create a ModBoss mapping with this format:

      holding_register 17, :outdoor_temp, as: {ModBoss.Encoding, :signed_int}

  This establishes address 17 as a holding register with the name
  `:outdoor_temp`. The raw value from the register will be passed to
  `ModBoss.Encoding.decode_signed_int/1` when decoding.

  Similarly, to set aside a **group of** registers to hold a single logical
  value, it would look like:

      holding_register 20..23, :model_name, as: {ModBoss.Encoding, :ascii}

  This establishes addresses 20–23 as holding registers with the name
  `:model_name`. The raw values from these registers will be passed (as a list)
  to `ModBoss.Encoding.decode_ascii/1` when decoding.

  ## Mode

  All ModBoss mappings are read-only by default. Use `mode: :rw` to allow both
  reads & writes. Or use `mode: :w` to configure a mapping as write-only.

  ## Automatic encoding/decoding

  Depending on whether a mapping is flagged as readable/writable, it is expected
  that you will provide functions with `encode_` or `decode_` prepended to the
  value provided by the `:as` option.

  For example, if you specify `as: :on_off` for a writable mapping, ModBoss
  will expect that the schema module defines either:

  * `encode_on_off/1` — accepts the value to encode
  * `encode_on_off/2` — accepts the value to encode and a
    `ModBoss.Encoding.Metadata` struct

  Use the 2-arity version when you need access to metadata (e.g. address count,
  mapping name, or user-provided context). Both must return either
  `{:ok, encoded_value}` or `{:error, message}`.

  The same applies to decode functions: define either `decode_on_off/1` (accepts
  the encoded value) or `decode_on_off/2` (accepts the encoded value and
  metadata).

  If the function to be used lives outside of the current module, a tuple
  including the module name can be passed. For example, you can use built-in
  encoders from `ModBoss.Encoding`.

  > #### output of `encode_*` {: .info}
  >
  > Your encode function may need to encode for **one or multiple** objects,
  > depending on the mapping. You are free to return either a single value or
  > a list of values—the important thing is that the number of values returned
  > needs to match the number of objects from your mapping. If it doesn't,
  > ModBoss will return an error when encoding.
  >
  > For example, if encoding "ABC!" as ascii into a mapping with 3 registers,
  > these characters would technically only _require_ 2 registers (one 16-bit
  > register for every 2 characters). However, your encoding should return a
  > list of length equaling what you've assigned to the mapping in your schema—
  > i.e. in this example, a list of length 3.

  > #### input to `decode_*` {: .info}
  >
  > When decoding a mapping involving a single address, the decode function will
  > be passed the single value from that address/object as provided by your read
  > function.
  >
  > When decoding a mapping involving multiple addresses
  > (e.g. in `ModBoss.Encoding.decode_ascii/1`), the decode function will be
  > passed a **List** of values.

  ## Example

      defmodule MyDevice.Schema do
        use ModBoss.Schema

        schema do
          holding_register 1..5, :model, as: {ModBoss.Encoding, :ascii}
          holding_register 6, :outdoor_temp, as: {ModBoss.Encoding, :signed_int}
          holding_register 7, :indoor_temp, as: {ModBoss.Encoding, :unsigned_int}

          input_register 200, :foo, as: {ModBoss.Encoding, :unsigned_int}
          coil 300, :bar, as: :on_off, mode: :rw
          holding_register 301, :setpoint, as: :scaled, mode: :w
          discrete_input 400, :baz, as: {ModBoss.Encoding, :boolean}
        end

        # 1-arity: no metadata needed
        def encode_on_off(:on), do: {:ok, 1}
        def encode_on_off(:off), do: {:ok, 0}

        def decode_on_off(1), do: {:ok, :on}
        def decode_on_off(0), do: {:ok, :off}

        # 2-arity: uses metadata.context for runtime behavior
        def encode_scaled(value, metadata) do
          case metadata.context do
            %{unit: :fahrenheit} -> {:ok, round((value - 32) * 5 / 9)}
            _ -> {:ok, value}
          end
        end
      end
  """

  alias ModBoss.Mapping

  defmacro __using__(opts) do
    max_reads = Keyword.get(opts, :max_batch_reads, [])
    max_writes = Keyword.get(opts, :max_batch_writes, [])

    quote do
      import unquote(__MODULE__), only: [schema: 1]

      Module.register_attribute(__MODULE__, :modboss_mappings, accumulate: true)
      Module.put_attribute(__MODULE__, :max_reads_per_batch, unquote(max_reads))
      Module.put_attribute(__MODULE__, :max_writes_per_batch, unquote(max_writes))

      @before_compile unquote(__MODULE__)
    end
  end

  @doc """
  Establishes a Modbus schema in the current module.
  """
  defmacro schema(do: block) do
    quote do
      (fn ->
         import unquote(__MODULE__),
           only: [
             holding_register: 2,
             holding_register: 3,
             input_register: 2,
             input_register: 3,
             coil: 2,
             coil: 3,
             discrete_input: 2,
             discrete_input: 3
           ]

         unquote(block)
       end).()
    end
  end

  @doc """
  Adds a holding register to a schema.

  ## Opts
  * `:mode` — Makes the mapping readable/writable — can be one of `[:r, :rw, :w]` (default: `:r`)
  * `:as` — Determines which encoding/decoding functions to use when writing/reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  * `:gap_safe` — Whether this mapping's addresses are safe to read incidentally
    when bridging a gap between other requested mappings (default: `true` for readable
    mappings, `false` for write-only). You should set this to `false` for any register
    that triggers side effects when read (e.g. clear-on-read registers). See the
    `:max_gap` option in `ModBoss.read/4` for details on gap tolerance.
  """
  defmacro holding_register(addresses, name, opts \\ []) do
    ModBoss.Schema.validate_name!(__CALLER__, name)
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_mapping(module, :holding_register, addresses, name, opts)
    end
  end

  @doc """
  Adds a read-only input register to a schema.

  ## Opts
  * `:as` — Determines which decoding functions to use when reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  * `:gap_safe` — Whether this mapping's addresses are safe to read incidentally
    when bridging a gap between other requested mappings (default: `true`). You should
    set this to `false` for any register that triggers side effects when read (e.g.
    clear-on-read registers). See the `:max_gap` option in `ModBoss.read/4` for details
    on gap tolerance.
  """
  defmacro input_register(addresses, name, opts \\ []) do
    ModBoss.Schema.validate_name!(__CALLER__, name)
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_mapping(module, :input_register, addresses, name, opts)
    end
  end

  @doc """
  Adds a coil to a schema.

  ## Opts
  * `:mode` — Makes the mapping readable/writable — can be one of `[:r, :rw, :w]` (default: `:r`)
  * `:as` — Determines which encoding/decoding functions to use when writing/reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  * `:gap_safe` — Whether this mapping's addresses are safe to read incidentally
    when bridging a gap between other requested mappings (default: `true` for readable
    mappings, `false` for write-only). You should set this to `false` for any coil
    that triggers side effects when read (e.g. clear-on-read coils). See the `:max_gap`
    option in `ModBoss.read/4` for details on gap tolerance.
  """
  defmacro coil(addresses, name, opts \\ []) do
    ModBoss.Schema.validate_name!(__CALLER__, name)
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_mapping(module, :coil, addresses, name, opts)
    end
  end

  @doc """
  Adds a read-only discrete input to a schema.

  ## Opts
  * `:as` — Determines which decoding functions to use when reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  * `:gap_safe` — Whether this mapping's addresses are safe to read incidentally
    when bridging a gap between other requested mappings (default: `true`). You should
    set this to `false` for any input that triggers side effects when read (e.g.
    clear-on-read inputs). See the `:max_gap` option in `ModBoss.read/4` for details
    on gap tolerance.
  """
  defmacro discrete_input(addresses, name, opts \\ []) do
    ModBoss.Schema.validate_name!(__CALLER__, name)
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_mapping(module, :discrete_input, addresses, name, opts)
    end
  end

  @doc false
  def validate_name!(%Macro.Env{file: file, line: line}, :all) do
    raise CompileError,
      file: file,
      line: line,
      description: "The name `:all` is reserved by ModBoss and cannot be used for a mapping."
  end

  def validate_name!(_env, _name), do: :ok

  @doc false
  def create_mapping(module, object_type, address_or_range, name, opts) do
    if not Module.has_attribute?(module, :modboss_mappings) do
      raise """
      Cannot create modbus mappings. Please make sure you have invoked \
      `use ModBoss.Schema` in #{inspect(module)}.\
      """
    end

    with %Mapping{} = mapping <- Mapping.new(module, name, object_type, address_or_range, opts) do
      Module.put_attribute(module, :modboss_mappings, mapping)
    end
  end

  defmacro __before_compile__(env) do
    max_reads = Module.get_attribute(env.module, :max_reads_per_batch)
    max_writes = Module.get_attribute(env.module, :max_writes_per_batch)

    max_holding_register_reads = max_reads[:holding_registers] || 125
    max_input_register_reads = max_reads[:input_registers] || 125
    max_coil_reads = max_reads[:coils] || 2000
    max_discrete_input_reads = max_reads[:discrete_inputs] || 2000

    max_holding_register_writes = max_writes[:holding_registers] || 123
    max_coil_writes = max_writes[:coils] || 1968
    mappings = Module.get_attribute(env.module, :modboss_mappings)

    duplicate_names =
      mappings
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_mapping, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> inspect(name) end)

    if Enum.any?(duplicate_names) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "The following names were used to identify more than one mapping: [#{Enum.join(duplicate_names, ", ")}]."
    end

    duplicate_addresses =
      mappings
      |> Enum.flat_map(fn mapping ->
        mapping
        |> Mapping.address_range()
        |> Enum.to_list()
        |> Enum.map(&{mapping.type, &1})
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_address, count} -> count > 1 end)
      |> Enum.map(fn {address, _count} -> address end)
      |> Enum.reverse()

    if Enum.any?(duplicate_addresses) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: """
        Each address can only be mapped once per object type, but the following were mapped more than once:

        #{Enum.map_join(duplicate_addresses, "\n", fn dup -> "  * #{inspect(dup)}" end)}
        """
    end

    validate_local_encode_functions!(env, mappings)
    validate_local_decode_functions!(env, mappings)

    mappings =
      mappings
      |> Enum.reverse()
      |> Enum.into(%{}, &{&1.name, &1})
      |> Macro.escape()

    quote do
      def __max_batch__(:read, :holding_register), do: unquote(max_holding_register_reads)
      def __max_batch__(:read, :input_register), do: unquote(max_input_register_reads)
      def __max_batch__(:read, :coil), do: unquote(max_coil_reads)
      def __max_batch__(:read, :discrete_input), do: unquote(max_discrete_input_reads)

      def __max_batch__(:write, :holding_register), do: unquote(max_holding_register_writes)
      def __max_batch__(:write, :coil), do: unquote(max_coil_writes)

      def __modboss_schema__, do: unquote(mappings)
    end
  end

  @doc false
  def validate_local_encode_functions!(env, mappings) do
    mappings
    |> Enum.filter(fn mapping ->
      {module, _function} = mapping.as
      module == env.module and Mapping.writable?(mapping)
    end)
    |> Enum.uniq_by(fn mapping -> mapping.as end)
    |> Enum.each(fn mapping ->
      {_module, as} = mapping.as
      function = String.to_atom("encode_#{as}")

      has_arity_1 = Module.defines?(env.module, {function, 1})
      has_arity_2 = Module.defines?(env.module, {function, 2})

      cond do
        has_arity_1 and has_arity_2 ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description: "Please define #{function}/1 or #{function}/2, but not both."

        not (has_arity_1 or has_arity_2) ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "Expected #{function}/1 or #{function}/2 to be defined for writable mapping #{inspect(mapping.name)}."

        true ->
          :ok
      end
    end)
  end

  @doc false
  def validate_local_decode_functions!(env, mappings) do
    mappings
    |> Enum.filter(fn mapping ->
      {module, _function} = mapping.as
      module == env.module and Mapping.readable?(mapping)
    end)
    |> Enum.uniq_by(fn mapping -> mapping.as end)
    |> Enum.each(fn mapping ->
      {_module, as} = mapping.as
      function = String.to_atom("decode_#{as}")

      has_arity_1 = Module.defines?(env.module, {function, 1})
      has_arity_2 = Module.defines?(env.module, {function, 2})

      cond do
        has_arity_1 and has_arity_2 ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description: "Please define #{function}/1 or #{function}/2, but not both."

        not (has_arity_1 or has_arity_2) ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "Expected #{function}/1 or #{function}/2 to be defined for readable mapping #{inspect(mapping.name)}."

        true ->
          :ok
      end
    end)
  end
end
