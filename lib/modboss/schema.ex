defmodule ModBoss.Schema do
  alias ModBoss.Mapping

  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__), only: [modbus_schema: 1]

      Module.register_attribute(__MODULE__, :register_mappings, accumulate: true)

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
             coil: 2,
             coil: 3
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

  defmacro coil(addresses, name, opts \\ []) do
    module = __CALLER__.module

    quote bind_quoted: binding() do
      ModBoss.Schema.create_register_mapping(module, :coil, addresses, name, opts)
    end
  end

  def create_register_mapping(module, register_type, address_or_range, name, opts) do
    if not Module.has_attribute?(module, :register_mappings) do
      raise """
      Cannot assign modbus register #{inspect(name)}. Please make sure you have invoked \
      `use ModBoss.Schema` in #{inspect(module)}.\
      """
    end

    mapping = Mapping.new(name, register_type, address_or_range, opts)
    Module.put_attribute(module, :register_mappings, mapping)
  end

  defmacro __before_compile__(env) do
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
      def __modbus_schema__, do: unquote(mappings)
    end
  end
end
