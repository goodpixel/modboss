defmodule ModBoss.SchemaTest do
  use ExUnit.Case, async: true

  alias ModBoss.Mapping
  alias ModBoss.Schema

  defmodule ExampleSchema do
    use ModBoss.Schema

    schema do
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

  describe "create_mapping" do
    test "creates read-only mappings by default" do
      assert mapping(ExampleSchema, :foo_holding_register).mode == :r
    end

    test "allows a single address to be provided" do
      mapping = mapping(ExampleSchema, :qux_holding_register)
      assert mapping.starting_address == 4
      assert mapping.address_count == 1
    end

    test "allows a range of addresses to be provided" do
      mapping = mapping(ExampleSchema, :quux_holding_register)
      assert mapping.starting_address == 5
      assert mapping.address_count == 6
    end

    test "raises an exception if the same name is used twice" do
      assert_raise CompileError, ~r/names were used to identify more than one mapping/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          schema do
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

        schema do
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

          schema do
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

            schema do
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

                 schema do
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

            schema do
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

                 schema do
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

            schema do
              discrete_input 1, :foo, mode: #{inspect(mode)}
            end
          end
          """)
        end
      end
    end
  end

  describe "compile-time encode/decode validation" do
    test "raises a compile error when a writable local mapping has no encode function at either arity" do
      assert_raise CompileError, ~r/encode_missing/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          schema do
            holding_register 1, :foo, as: :missing, mode: :w
          end
        end
        """)
      end
    end

    test "does not raise when a writable local mapping has an arity-2 encode function" do
      Code.compile_string("""
      defmodule #{unique_module()} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo, as: :toggle, mode: :w
        end

        def encode_toggle(_value, _metadata), do: {:ok, 1}
      end
      """)
    end

    test "raises a compile error when both arity-1 and arity-2 encode functions are defined" do
      assert_raise CompileError,
                   ~r/define encode_boolean\/1 or encode_boolean\/2, but not both/,
                   fn ->
                     Code.compile_string("""
                     defmodule #{unique_module()} do
                       use ModBoss.Schema

                       schema do
                         holding_register 1, :foo, as: :boolean, mode: :w
                       end

                       def encode_boolean(true, _metadata), do: {:ok, 1}
                       def encode_boolean(true), do: {:ok, 1}
                     end
                     """)
                   end
    end

    test "does not raise when a writable local mapping has an arity-1 encode function" do
      Code.compile_string("""
      defmodule #{unique_module()} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo, as: :toggle, mode: :w
        end

        def encode_toggle(_value), do: {:ok, 1}
      end
      """)
    end

    test "raises a compile error when a readable local mapping has no decode function at either arity" do
      assert_raise CompileError, ~r/decode_missing/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          schema do
            holding_register 1, :foo, as: :missing
          end
        end
        """)
      end
    end

    test "does not raise when a readable local mapping has an arity-1 decode function" do
      Code.compile_string("""
      defmodule #{unique_module()} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo, as: :toggle
        end

        def decode_toggle(_value), do: {:ok, :on}
      end
      """)
    end

    test "does not raise when a readable local mapping has an arity-2 decode function" do
      Code.compile_string("""
      defmodule #{unique_module()} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo, as: :toggle
        end

        def decode_toggle(_value, _metadata), do: {:ok, :on}
      end
      """)
    end

    test "raises a compile error when both arity-1 and arity-2 decode functions are defined" do
      assert_raise CompileError,
                   ~r/define decode_toggle\/1 or decode_toggle\/2, but not both/,
                   fn ->
                     Code.compile_string("""
                     defmodule #{unique_module()} do
                       use ModBoss.Schema

                       schema do
                         holding_register 1, :foo, as: :toggle
                       end

                       def decode_toggle(_value, _metadata), do: {:ok, :on}
                       def decode_toggle(_value), do: {:ok, :on}
                     end
                     """)
                   end
    end

    test "raises a compile error for bogus `:if` options" do
      assert_raise CompileError, ~r/Invalid `:if` value/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          schema do
            holding_register 1, :foo, if: "not_valid"
          end
        end
        """)
      end
    end

    test "raises a compile error for anonymous `:if` callback that's not arity 1" do
      assert_raise CompileError, ~r/must be arity 1/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          schema do
            holding_register 1, :foo, if: fn _, _ -> false end
          end
        end
        """)
      end
    end

    test "raises a compile error for anonymous `:if` callback that's not arity 1 when a guard is in the mix" do
      assert_raise CompileError, ~r/must be arity 1/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          schema do
            holding_register 1, :foo, if: fn ctx, extra when is_map(ctx) -> extra end
          end
        end
        """)
      end
    end

    test "raises a compile error for a multi-clause anonymous `:if` callback that's not arity 1" do
      assert_raise CompileError, ~r/must be arity 1/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          schema do
            holding_register 1, :foo, if: fn %{firmware: v}, extra -> v + extra; _, _ -> false end
          end
        end
        """)
      end
    end

    test "does not raise for a multi-clause anonymous `:if` callback that's arity 1" do
      Code.compile_string("""
      defmodule #{unique_module()} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo, if: fn %{firmware: v} -> v >= 2; _ -> false end
        end
      end
      """)
    end

    test "raises a compile error when local `:if` function is not defined" do
      assert_raise CompileError, ~r/Expected supported\?\/1 to be defined/, fn ->
        Code.compile_string("""
        defmodule #{unique_module()} do
          use ModBoss.Schema

          schema do
            holding_register 1, :foo, if: :supported?
          end
        end
        """)
      end
    end
  end

  describe "__modboss_mapping_names__/0" do
    test "returns a map of address-to-Mapping lookups keyed by object type" do
      module = unique_module()

      Code.compile_string("""
      defmodule #{module} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo
          holding_register 2..4, :bar
          holding_register 100, :baz

          input_register 1, :qux

          coil 1, :quux

          discrete_input 1, :corge
        end
      end
      """)

      assert module.__modboss_mapping_names__() == %{
               holding_register: %{
                 1 => :foo,
                 2 => :bar,
                 3 => :bar,
                 4 => :bar,
                 100 => :baz
               },
               input_register: %{
                 1 => :qux
               },
               coil: %{
                 1 => :quux
               },
               discrete_input: %{
                 1 => :corge
               }
             }
    end
  end

  describe "__modboss_mapping_names__/1" do
    test "returns a map of address-to-Mapping lookups for the given object type" do
      module = unique_module()

      Code.compile_string("""
      defmodule #{module} do
        use ModBoss.Schema

        schema do
          holding_register 1..2, :foo
          input_register 1, :bar
          coil 1, :baz
          discrete_input 1, :qux
        end
      end
      """)

      assert module.__modboss_mapping_names__(:holding_register) == %{1 => :foo, 2 => :foo}
      assert module.__modboss_mapping_names__(:input_register) == %{1 => :bar}
      assert module.__modboss_mapping_names__(:coil) == %{1 => :baz}
      assert module.__modboss_mapping_names__(:discrete_input) == %{1 => :qux}
    end

    test "returns an empty map if there are no registered mappings for the object type" do
      module = unique_module()

      Code.compile_string("""
      defmodule #{module} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo
        end
      end
      """)

      assert module.__modboss_mapping_names__(:input_register) == %{}
    end
  end

  describe "__modboss_mapping__/2" do
    test "returns the ModBoss.Mapping for the given modbus object type/address" do
      module = unique_module()

      Code.compile_string("""
      defmodule #{module} do
        use ModBoss.Schema

        schema do
          holding_register 1..2, :foo
          input_register 1, :bar
          coil 1, :baz
          discrete_input 1, :qux
        end
      end
      """)

      assert %Mapping{name: :foo} = module.__modboss_mapping__(:holding_register, 1)
      assert %Mapping{name: :foo} = module.__modboss_mapping__(:holding_register, 2)
      assert %Mapping{name: :bar} = module.__modboss_mapping__(:input_register, 1)
      assert %Mapping{name: :baz} = module.__modboss_mapping__(:coil, 1)
      assert %Mapping{name: :qux} = module.__modboss_mapping__(:discrete_input, 1)
    end

    test "returns nil if no ModBoss.Mapping exists for the given modbus object type/address" do
      module = unique_module()

      Code.compile_string("""
      defmodule #{module} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo
        end
      end
      """)

      assert is_nil(module.__modboss_mapping__(:holding_register, 2))
      assert is_nil(module.__modboss_mapping__(:discrete_input, 1))
    end
  end

  describe "contiguous_mappings_between/3" do
    setup do
      module = unique_module()

      Code.compile_string("""
      defmodule #{module} do
        use ModBoss.Schema

        schema do
          holding_register 1..3, :foo
          holding_register 4, :bar, mode: :rw
          holding_register 5..9, :baz, mode: :r
          holding_register 10, :qux, mode: :w

          holding_register 20, :quux, mode: :w
          holding_register 21, :corge, mode: :w

          input_register 11, :grault
        end
      end
      """)

      %{
        module: module,
        foo: mapping(module, :foo),
        bar: mapping(module, :bar),
        baz: mapping(module, :baz),
        qux: mapping(module, :qux),
        quux: mapping(module, :quux),
        corge: mapping(module, :corge),
        grault: mapping(module, :grault)
      }
    end

    test "returns an ascending stream of contiguous mappings between any two mappings", ctx do
      assert [] =
               Schema.contiguous_mappings_between(ctx.module, ctx.foo, ctx.bar)
               |> Enum.map(fn %Mapping{name: name} -> name end)

      assert [:bar] =
               Schema.contiguous_mappings_between(ctx.module, ctx.foo, ctx.baz)
               |> Enum.map(fn %Mapping{name: name} -> name end)

      assert [:bar, :baz] =
               Schema.contiguous_mappings_between(ctx.module, ctx.foo, ctx.qux)
               |> Enum.map(fn %Mapping{name: name} -> name end)

      assert [:baz] =
               Schema.contiguous_mappings_between(ctx.module, ctx.bar, ctx.qux)
               |> Enum.map(fn %Mapping{name: name} -> name end)

      assert [] =
               Schema.contiguous_mappings_between(ctx.module, ctx.baz, ctx.qux)
               |> Enum.map(fn %Mapping{name: name} -> name end)
    end

    test "aborts stream at first address with no registered mapping", ctx do
      assert [:bar, :baz, :qux] =
               Schema.contiguous_mappings_between(ctx.module, ctx.foo, ctx.corge)
               |> Enum.map(fn %Mapping{name: name} -> name end)
    end

    test "requires mappings to be given in order", ctx do
      assert_raise RuntimeError, ~r/in order of starting address/, fn ->
        Schema.contiguous_mappings_between(ctx.module, ctx.quux, ctx.foo)
      end
    end

    test "requires mappings to be the same type", ctx do
      assert_raise RuntimeError, ~r/must be the same type/, fn ->
        Schema.contiguous_mappings_between(ctx.module, ctx.foo, ctx.grault)
      end
    end
  end

  defp unique_module do
    name = "#{__MODULE__}#{System.unique_integer([:positive])}"
    Module.concat([name])
  end

  defp mapping(module, name) do
    module.__modboss_schema__() |> Map.fetch!(name)
  end
end
