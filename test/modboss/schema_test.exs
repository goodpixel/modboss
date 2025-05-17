defmodule Modboss.SchemaTest do
  use ExUnit.Case

  defmodule ExampleSchema do
    use ModBoss.Schema

    modbus_schema do
      holding_register 1, :foo
      holding_register 2, :bar, mode: :r
      holding_register 3, :baz, mode: :rw
      holding_register 4, :qux, mode: :w
      holding_register 5..10, :quux
    end
  end

  describe "create_register_mapping" do
    test "creates read-only mappings by default" do
      assert mapping(ExampleSchema, :foo).mode == :r
    end

    test "allows mode to be specified" do
      for {register_name, mode} <- [bar: :r, baz: :rw, qux: :w] do
        assert mapping(ExampleSchema, register_name).mode == mode
      end
    end

    test "allows a single address to be provided" do
      mapping = mapping(ExampleSchema, :qux)
      assert mapping.addresses == 4..4
    end

    test "allows a range of addresses to be provided" do
      mapping = mapping(ExampleSchema, :quux)
      assert mapping.addresses == 5..10
    end

    test "raises an exception if the same name is used twice" do
      assert_raise CompileError, ~r/names were used to identify more than one register/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          modbus_schema do
            holding_register 1, :foo
            holding_register 2, :foo
          end
        end
        """)
      end
    end

    test "raises an exception if any addresses are mapped twice" do
      assert_raise CompileError, ~r/addresses were mapped more than once in/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          modbus_schema do
            holding_register 1, :foo
            holding_register 1, :bar
          end
        end
        """)
      end
    end
  end

  defp unique_module do
    "#{__MODULE__}#{System.unique_integer([:positive])}"
  end

  defp mapping(module, name) do
    module.__modbus_schema__() |> Map.fetch!(name)
  end
end
