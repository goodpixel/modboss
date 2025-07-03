defmodule ModBoss.SchemaTest do
  use ExUnit.Case

  defmodule ExampleSchema do
    use ModBoss.Schema

    modbus_schema do
      holding_register 1, :foo_holding_register
      holding_register 2, :bar_holding_register, mode: :r
      holding_register 3, :baz_holding_register, mode: :rw
      holding_register 4, :qux_holding_register, mode: :w
      holding_register 5..10, :quux_holding_register

      input_register 100, :foo_input_register

      coil 200, :foo_coil
      coil 201, :bar_coil, mode: :rw

      discrete_input 300, :foo_discrete_input
    end
  end

  describe "create_register_mapping" do
    test "creates read-only mappings by default" do
      assert mapping(ExampleSchema, :foo_holding_register).mode == :r
    end

    test "allows a single address to be provided" do
      mapping = mapping(ExampleSchema, :qux_holding_register)
      assert mapping.addresses == 4..4
    end

    test "allows a range of addresses to be provided" do
      mapping = mapping(ExampleSchema, :quux_holding_register)
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

    test "allows addresses to be reused across object types" do
      # This shouldn't raise an exception, so the test should pass…
      Code.compile_string("""
      defmodule #{unique_module()} do
        use ModBoss.Schema

        modbus_schema do
          holding_register 1, :foo
          input_register 1, :bar
          coil 1, :baz
          discrete_input 1, :qux
        end
      end
      """)
    end

    test "raises an exception if any addresses are mapped more than once for any given object" do
      message = ~r/mapped more than once.*{:holding_register, 1}.*{:coil, 2}/s

      assert_raise CompileError, message, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          modbus_schema do
            holding_register 1, :nope
            holding_register 1, :nah
            coil 1, :okay
            coil 2, :uh_oh
            coil 2, :yeah_no
          end
        end
        """)
      end
    end

    test "raises an exception if any mapping uses the reserved name `:all`" do
      Enum.each([:holding_register, :input_register, :coil, :discrete_input], fn object_type ->
        assert_raise CompileError, ~r/reserved by ModBoss/, fn ->
          Code.compile_string("""
          defmodule #{unique_module()} do
            use ModBoss.Schema

            modbus_schema do
              #{object_type} 1, :all
            end
          end
          """)
        end
      end)
    end
  end

  describe "holding_register/3" do
    test "is read-only by default" do
      %{mode: :r} = mapping(ExampleSchema, :foo_holding_register)
    end

    test "can be flagged as readable or writable" do
      for mode <- [:r, :rw, :w] do
        assert Code.compile_string("""
               defmodule #{unique_module()} do
                 use ModBoss.Schema

                 modbus_schema do
                   holding_register 1, :foo, mode: #{inspect(mode)}
                 end
               end
               """)
      end
    end
  end

  describe "input_register/3" do
    test "is read-only by default" do
      %{mode: :r} = mapping(ExampleSchema, :foo_input_register)
    end

    test "cannot be flagged as writable" do
      for mode <- [:rw, :w] do
        assert_raise RuntimeError, ~r/Invalid mode (:rw|:w) for input_register/, fn ->
          Code.compile_string("""
          defmodule #{unique_module()} do
            use ModBoss.Schema

            modbus_schema do
              input_register 1, :foo, mode: #{inspect(mode)}
            end
          end
          """)
        end
      end
    end
  end

  describe "coil/3" do
    test "is read-only by default" do
      %{mode: :r} = mapping(ExampleSchema, :foo_coil)
    end

    test "can be flagged as readable or writable" do
      for mode <- [:r, :rw, :w] do
        assert Code.compile_string("""
               defmodule #{unique_module()} do
                 use ModBoss.Schema

                 modbus_schema do
                   coil 1, :foo, mode: #{inspect(mode)}
                 end
               end
               """)
      end
    end
  end

  describe "discrete_input/3" do
    test "is read-only by default" do
      %{mode: :r} = mapping(ExampleSchema, :foo_discrete_input)
    end

    test "cannot be flagged as writable" do
      for mode <- [:rw, :w] do
        assert_raise RuntimeError, ~r/Invalid mode (:rw|:w) for discrete_input/, fn ->
          Code.compile_string("""
          defmodule #{unique_module()} do
            use ModBoss.Schema

            modbus_schema do
              discrete_input 1, :foo, mode: #{inspect(mode)}
            end
          end
          """)
        end
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
