defmodule ModBoss.Schema do
  @moduledoc """
  Macros for establishing Modbus schema.

  The schema allows names to be assigned to individual registers or groups of contiguous
  registers along with encoder/decoder functions. It also allows registers to be flagged
  as readable and/or writable.

  ## Naming an address

  You'll name a Modbus address with this format:

      holding_register 17, :outdoor_temp, as: {ModBoss.Encoding, :signed_int}

  This establishes address 17 as a holding register with the name `:outdoor_temp`.
  The raw value from the register will be passed to `ModBoss.Encoding.decode_signed_int/1`
  before being returned.

  Similarly, to set aside a **group of** registers to hold a single logical value,
  it would look like:

      holding_register 20..23, :model_name, as: {ModBoss.Encoding, :ascii}

  This establishes addresses 20–23 as holding registers with the name `:model_name`. The raw
  values from these registers will be passed (as a list) to `ModBoss.Encoding.decode_ascii/1`
  before being returned.

  ## Mode

  All registers are read-only by default. Use `mode: :rw` to allow both reads & writes.
  Or use `mode: :w` to mark a register as write-only.

  ## Automatic encoding/decoding

  Depending on whether a mapping is flagged as readable/writable, it is expected that you
  will provide functions with `encode_` or `decode_` prepended to the value provided by the `:as`
  option.

  For example, if you specify `as: :on_off` for a read-only register, ModBoss will expect that
  the schema module defines an `encode_on_off/1` function that accepts the value to encode and
  returns either `{:ok, encoded_value}` or `{:error, messsage}`.

  If the function to be used lives outside of the current module, a tuple including the module
  name can be passed. For example, you can use built-in translation from `ModBoss.Encoding` such
  as `:boolean`, `:signed_int`, `:unsigned_int`, and `:ascii`.

  > #### output of `encode_*` {: .info}
  >
  > Your encode function may need to encode for **one or multiple** registers, depending on the
  > mapping. You are free to return either a single value or a list of values—the important thing
  > is that the number of values returned needs to match the number of registers for your mapping.
  > If it doesn't, ModBoss will detect that and return an error during encoding.
  >
  > For example, if encoding "ABC!" as ascii into a mapping with 3 registers, this would
  > technically only "require" 2 registers (one 16-bit register for every 2 characters).
  > However, your encoding should return a list of 3 values if that's what you've assigned
  > to the mapping in your schema.

  > #### input to `decode_*` {: .info}
  >
  > When decoding a single register, the decode function will be passed the single value from that
  > register as provided by your read function.
  >
  > When decoding multiple registers (e.g. in `ModBoss.Encoding.decode_ascii/1`), the decode
  > function will be passed a **List** of values.

  ## Example

      defmodule MyDevice.Schema do
        use ModBoss.Schema

        modbus_schema do
          holding_register 1..5, :model, as: {ModBoss.Encoding, :ascii}
          holding_register 6, :outdoor_temp, as: {ModBoss.Encoding, :signed_int}
          holding_register 7, :indoor_temp, as: {ModBoss.Encoding, :unsigned_int}

          input_register 200, :foo, as: {ModBoss.Encoding, :unsigned_int}
          coil 300, :bar, as: :on_off, mode: :rw
          discrete_input 400, :baz, as: {ModBoss.Encoding, :boolean}
        end

        def encode_on_off(:on), do: {:ok, 1}
        def encode_on_off(:off), do: {:ok, 0}

        def decode_on_off(1), do: {:ok, :on}
        def decode_on_off(0), do: {:ok, :off}
      end
  """

  alias ModBoss.Mapping

  defmacro __using__(opts) do
    max_reads = Keyword.get(opts, :max_batch_reads, [])
    max_writes = Keyword.get(opts, :max_batch_writes, [])

    quote do
      import unquote(__MODULE__), only: [modbus_schema: 1]

      Module.register_attribute(__MODULE__, :register_mappings, accumulate: true)
      Module.put_attribute(__MODULE__, :max_reads_per_batch, unquote(max_reads))
      Module.put_attribute(__MODULE__, :max_writes_per_batch, unquote(max_writes))

      @before_compile unquote(__MODULE__)
    end
  end

  @doc """
  Establishes a Modbus schema in the current module.
  """
  defmacro modbus_schema(do: block) do
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
  """
  defmacro holding_register(addresses, name, opts \\ []) do
    ModBoss.Schema.validate_name!(__CALLER__, name)
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_register_mapping(module, :holding_register, addresses, name, opts)
    end
  end

  @doc """
  Adds a read-only input register to a schema.

  ## Opts
  * `:as` — Determines which decoding functions to use when reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  """
  defmacro input_register(addresses, name, opts \\ []) do
    ModBoss.Schema.validate_name!(__CALLER__, name)
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_register_mapping(module, :input_register, addresses, name, opts)
    end
  end

  @doc """
  Adds a coil to a schema.

  ## Opts
  * `:mode` — Makes the mapping readable/writable — can be one of `[:r, :rw, :w]` (default: `:r`)
  * `:as` — Determines which encoding/decoding functions to use when writing/reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  """
  defmacro coil(addresses, name, opts \\ []) do
    ModBoss.Schema.validate_name!(__CALLER__, name)
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_register_mapping(module, :coil, addresses, name, opts)
    end
  end

  @doc """
  Adds a read-only discrete input to a schema.

  ## Opts
  * `:as` — Determines which decoding functions to use when reading values.
    See explanation of [automatic encoding/decoding](ModBoss.Schema.html#module-automatic-encoding-decoding).
  """
  defmacro discrete_input(addresses, name, opts \\ []) do
    ModBoss.Schema.validate_name!(__CALLER__, name)
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_register_mapping(module, :discrete_input, addresses, name, opts)
    end
  end

  def validate_name!(%Macro.Env{file: file, line: line}, :all) do
    raise CompileError,
      file: file,
      line: line,
      description: "The name `:all` is reserved by ModBoss and cannot be used for a mapping."
  end

  def validate_name!(_env, _name), do: :ok

  def create_register_mapping(module, register_type, address_or_range, name, opts) do
    if not Module.has_attribute?(module, :register_mappings) do
      raise """
      Cannot assign modbus registers. Please make sure you have invoked \
      `use ModBoss.Schema` in #{inspect(module)}.\
      """
    end

    with %Mapping{} = mapping <- Mapping.new(module, name, register_type, address_or_range, opts) do
      Module.put_attribute(module, :register_mappings, mapping)
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
    mappings = Module.get_attribute(env.module, :register_mappings)

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
          "The following names were used to identify more than one register: [#{Enum.join(duplicate_names, ", ")}]."
    end

    duplicate_addresses =
      mappings
      |> Enum.flat_map(fn mapping ->
        mapping.addresses
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
        Each address can only be registered once per object type, but the following were mapped more than once:

        #{Enum.map_join(duplicate_addresses, "\n", fn dup -> "  * #{inspect(dup)}" end)}
        """
    end

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

      def __modbus_schema__, do: unquote(mappings)
    end
  end
end
