defmodule ModBoss.Schema do
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

  defmacro holding_register(addresses, name, opts \\ []) do
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_register_mapping(module, :holding_register, addresses, name, opts)
    end
  end

  defmacro input_register(addresses, name, opts \\ []) do
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_register_mapping(module, :input_register, addresses, name, opts)
    end
  end

  defmacro coil(addresses, name, opts \\ []) do
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_register_mapping(module, :coil, addresses, name, opts)
    end
  end

  defmacro discrete_input(addresses, name, opts \\ []) do
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_register_mapping(module, :discrete_input, addresses, name, opts)
    end
  end

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
      |> Enum.map(fn {name, _count} -> name end)

    if Enum.any?(duplicate_names) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "The following names were used to identify more than one register in #{env.module}: #{Enum.join(duplicate_names, ", ")}."
    end

    duplicate_addresses =
      mappings
      |> Enum.flat_map(&Enum.to_list(&1.addresses))
      |> Enum.frequencies()
      |> Enum.filter(fn {_address, count} -> count > 1 end)
      |> Enum.map(fn {address, _count} -> address end)

    if Enum.any?(duplicate_addresses) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "The following addresses were mapped more than once in #{env.module}: #{Enum.join(duplicate_addresses, ", ")}."
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
