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

  ## Conditional mapping support

  Some mappings may only be available under specific circumstances, like when
  running a particular firmware version. ModBoss allows conditional support of
  mappings at runtime via the `:if` option.

  `:if` accepts an anonymous function, an atom referencing a function on the
  schema module, or a `{Module, :function}` tuple. The callback receives any
  `:context` provided to `ModBoss.read/4` or `ModBoss.write/4` and must return
  `true` for supported or `false` or `{false, custom_value}` for unsupported
  (custom return values are only supported on reads). Unsupported mappings are
  neither requested nor encoded/decoded. When attempted to be read, they will
  simply return `nil` or the custom value as specified.

  > #### Gap safety {: .info}
  >
  > Conditional mappings determined to be **unsupported** for the given context
  > are considered gap _unsafe_.

  `ModBoss.Telemetry` exposes an `:unsupported` metric to track which mappings were
  excluded from any given read or write.

  ## Examples

      defmodule MyDevice.Schema do
        use ModBoss.Schema

        schema do
          holding_register 1..5, :model, as: {ModBoss.Encoding, :ascii}
          holding_register 6, :outdoor_temp, as: {ModBoss.Encoding, :signed_int}
          holding_register 10, :setpoint, as: :scaled, mode: :w

          input_register 1, :foo, as: {ModBoss.Encoding, :unsigned_int}
          coil 1, :bar, as: :on_off, mode: :rw
          discrete_input 1, :baz, if: fn context -> context.supported end
        end

        def encode_on_off(:on), do: {:ok, 1}
        def encode_on_off(:off), do: {:ok, 0}

        def decode_on_off(1), do: {:ok, :on}
        def decode_on_off(0), do: {:ok, :off}

        # Optional 2-arity encoder: uses metadata.context for runtime-based logic
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
      Module.register_attribute(__MODULE__, :modboss_mapping_support, accumulate: true)
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
  * `:if` — Determines at runtime whether the mapping is supported.
    See [conditional mapping support](#module-conditional-mapping-support).
  * `:gap_safe` — Whether this mapping's addresses are safe to read incidentally
    when bridging a gap between other requested mappings (default: `true` for readable
    mappings, `false` for write-only). You should set this to `false` for any register
    that triggers side effects when read (e.g. clear-on-read registers). See the
    `:max_gap` option in `ModBoss.read/4` for details on gap tolerance.
  """
  defmacro holding_register(addresses, name, opts \\ []) do
    define_mapping(__CALLER__, :holding_register, addresses, name, opts)
  end

  @doc """
  Adds a read-only input register to a schema.

  ## Opts
  * `:as` — Determines which decoding functions to use when reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  * `:if` — Determines at runtime whether the mapping is supported.
    See [conditional mapping support](#module-conditional-mapping-support).
  * `:gap_safe` — Whether this mapping's addresses are safe to read incidentally
    when bridging a gap between other requested mappings (default: `true`). You should
    set this to `false` for any register that triggers side effects when read (e.g.
    clear-on-read registers). See the `:max_gap` option in `ModBoss.read/4` for details
    on gap tolerance.
  """
  defmacro input_register(addresses, name, opts \\ []) do
    define_mapping(__CALLER__, :input_register, addresses, name, opts)
  end

  @doc """
  Adds a coil to a schema.

  ## Opts
  * `:mode` — Makes the mapping readable/writable — can be one of `[:r, :rw, :w]` (default: `:r`)
  * `:as` — Determines which encoding/decoding functions to use when writing/reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  * `:if` — Determines at runtime whether the mapping is supported.
    See [conditional mapping support](#module-conditional-mapping-support).
  * `:gap_safe` — Whether this mapping's addresses are safe to read incidentally
    when bridging a gap between other requested mappings (default: `true` for readable
    mappings, `false` for write-only). You should set this to `false` for any coil
    that triggers side effects when read (e.g. clear-on-read coils). See the `:max_gap`
    option in `ModBoss.read/4` for details on gap tolerance.
  """
  defmacro coil(addresses, name, opts \\ []) do
    define_mapping(__CALLER__, :coil, addresses, name, opts)
  end

  @doc """
  Adds a read-only discrete input to a schema.

  ## Opts
  * `:as` — Determines which decoding functions to use when reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  * `:if` — Determines at runtime whether the mapping is supported.
    See [conditional mapping support](#module-conditional-mapping-support).
  * `:gap_safe` — Whether this mapping's addresses are safe to read incidentally
    when bridging a gap between other requested mappings (default: `true`). You should
    set this to `false` for any input that triggers side effects when read (e.g.
    clear-on-read inputs). See the `:max_gap` option in `ModBoss.read/4` for details
    on gap tolerance.
  """
  defmacro discrete_input(addresses, name, opts \\ []) do
    define_mapping(__CALLER__, :discrete_input, addresses, name, opts)
  end

  defp define_mapping(caller, type, addresses, name, opts) do
    module = caller.module
    {if_ast, opts} = Keyword.pop(opts, :if, true)

    validate_name!(caller, name)
    validate_if_ast!(caller, name, if_ast)

    create_mapping =
      quote bind_quoted: [
              module: module,
              type: type,
              addresses: addresses,
              name: name,
              opts: opts
            ] do
        ModBoss.Schema.create_mapping(module, type, addresses, name, opts)
      end

    quote do
      @modboss_mapping_support {unquote(name), unquote(Macro.escape(if_ast))}
      unquote(create_mapping)
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

  defp validate_if_ast!(env, name, {:fn, _, [{:->, _, [args, _body]}]}) do
    if fn_arity(args) != 1 do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "Anonymous `:if` callback for #{inspect(name)} mapping must be arity 1."
    end
  end

  defp validate_if_ast!(_env, _name, _), do: :ok

  # When guards are in the mix, the function args are everything but
  # the final "when_args." Otherwise, it's just the top-level "args."
  defp fn_arity([{:when, _, when_args}]), do: length(when_args) - 1
  defp fn_arity(args), do: length(args)

  defp to_supported_ast(true, _env, _name), do: true
  defp to_supported_ast(false, _env, _name), do: false
  defp to_supported_ast({:fn, _, _} = fn_ast, _env, _name), do: fn_ast

  defp to_supported_ast(fun_name, env, _name) when is_atom(fun_name) do
    quote do: &(unquote(env.module).unquote(fun_name) / 1)
  end

  defp to_supported_ast({mod_ast, fun_name}, _env, _name) when is_atom(fun_name) do
    quote do: &(unquote(mod_ast).unquote(fun_name) / 1)
  end

  defp to_supported_ast(_invalid, env, name) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: "Invalid `:if` value for #{inspect(name)} mapping."
  end

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
    validate_local_if_functions!(env)

    escaped_mappings =
      mappings
      |> Enum.reverse()
      |> Enum.into(%{}, &{&1.name, &1})
      |> Macro.escape()

    mappings_with_normalized_conditions =
      env.module
      |> Module.get_attribute(:modboss_mapping_support)
      |> Enum.reduce(escaped_mappings, fn {mapping_name, if_ast}, acc ->
        supported_ast = to_supported_ast(if_ast, env, mapping_name)

        quote do
          Map.update!(unquote(acc), unquote(mapping_name), fn mapping ->
            %{mapping | supported: unquote(supported_ast)}
          end)
        end
      end)

    Module.delete_attribute(env.module, :modboss_mappings)
    Module.delete_attribute(env.module, :modboss_mapping_support)

    quote do
      def __max_batch__(:read, :holding_register), do: unquote(max_holding_register_reads)
      def __max_batch__(:read, :input_register), do: unquote(max_input_register_reads)
      def __max_batch__(:read, :coil), do: unquote(max_coil_reads)
      def __max_batch__(:read, :discrete_input), do: unquote(max_discrete_input_reads)

      def __max_batch__(:write, :holding_register), do: unquote(max_holding_register_writes)
      def __max_batch__(:write, :coil), do: unquote(max_coil_writes)

      def __modboss_schema__, do: unquote(mappings_with_normalized_conditions)
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

  defp validate_local_if_functions!(env) do
    env.module
    |> Module.get_attribute(:modboss_mapping_support)
    |> Enum.each(fn
      {name, fun_name} when is_atom(fun_name) and fun_name not in [true, false] ->
        unless Module.defines?(env.module, {fun_name, 1}) do
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "Expected #{fun_name}/1 to be defined for `:if` callback on mapping #{inspect(name)}."
        end

      _ ->
        :ok
    end)
  end
end
