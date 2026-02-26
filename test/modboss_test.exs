defmodule ModBossTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  defmodule FakeSchema do
    use ModBoss.Schema

    schema do
      holding_register 1, :foo
      holding_register 2, :bar, mode: :r
      holding_register 3, :baz, mode: :w
      holding_register 4, :blah, mode: :rw
      holding_register 10..12, :qux, mode: :rw
      holding_register 13..14, :quux, mode: :rw
      holding_register 15, :corge, mode: :rw

      coil 100, :grault, mode: :rw
      coil 101, :garply, mode: :rw

      # max 120 writes per batch, so making a giant mapping to test that
      coil 201..320, :maximus, mode: :rw
      coil 321, :trop, mode: :rw

      input_register 400, :waldo

      discrete_input 500, :fred
    end
  end

  @initial_state %{
    reads: 0,
    writes: 0,
    objects: %{}
  }

  describe "ModBoss.read/4" do
    test "gap tolerance does not read across unmapped registers" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo
          holding_register 3, :baz
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})
      encode_and_set(device, schema, foo: 11, baz: 33)

      # Even with a large gap tolerance, unmapped address 2 must prevent batching
      {:ok, %{foo: 11, baz: 33}} =
        ModBoss.read(schema, read_func(device), [:foo, :baz], max_gap: 10)

      assert 2 = get_read_count(device)
    end

    test "gap tolerance does not read across write-only registers" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo
          holding_register 2, :bar, mode: :w
          holding_register 3, :baz
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})
      encode_and_set(device, schema, foo: 11, baz: 33)

      # Even with a large gap tolerance, we'll need two reads since address 2 is unreadable
      {:ok, %{foo: 11, baz: 33}} =
        ModBoss.read(schema, read_func(device), [:foo, :baz], max_gap: 10)

      assert 2 = get_read_count(device)
    end

    test "reads an individual mapping by name, returning a single result" do
      device = start_supervised!({Agent, fn -> @initial_state end})
      encode_and_set(device, FakeSchema, foo: 123)
      {:ok, 123} = ModBoss.read(FakeSchema, read_func(device), :foo)
    end

    test "reads values for mappings that cover multiple address" do
      device = start_supervised!({Agent, fn -> @initial_state end})
      encode_and_set(device, FakeSchema, qux: [10, 11, 12])
      {:ok, [10, 11, 12]} = ModBoss.read(FakeSchema, read_func(device), :qux)
    end

    test "reads multiple (and non-contiguous) mappings by name, returning a map of requested values" do
      device = start_supervised!({Agent, fn -> @initial_state end})
      encode_and_set(device, FakeSchema, foo: :a, bar: :b, baz: :c, qux: [:x, :y, :z])

      assert {:ok, result} = ModBoss.read(FakeSchema, read_func(device), [:foo, :qux])
      assert %{foo: :a, qux: [:x, :y, :z]} == result
    end

    test "returns an error if any mapping names are unrecognized" do
      device = start_supervised!({Agent, fn -> @initial_state end})

      assert {:error, "Unknown mapping(s) :foobar, :bazqux for ModBossTest.FakeSchema."} =
               ModBoss.read(FakeSchema, read_func(device), [:foobar, :bazqux])
    end

    test "refuses to read unless all mappings are declared readable" do
      device = start_supervised!({Agent, fn -> @initial_state end})

      assert {:error, "ModBoss Mapping(s) :baz in ModBossTest.FakeSchema are not readable."} =
               ModBoss.read(FakeSchema, read_func(device), [:bar, :baz])
    end

    test "batches contiguous reads for each type up to the Modbus protocol's maximum" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1..124, :holding_1
          holding_register 125, :holding_125
          holding_register 126, :holding_126

          input_register 201..324, :input_201
          input_register 325, :input_325
          input_register 326, :input_326

          coil 2001..3999, :coil_2001
          coil 4000, :coil_4000
          coil 4001, :coil_4001

          discrete_input 5001..6999, :discrete_input_5001
          discrete_input 7000, :discrete_input_7000
          discrete_input 7001, :discrete_input_7001
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      holding_register_values = for i <- 1..126, into: %{}, do: {{:holding_register, i}, 1}
      input_register_values = for i <- 201..326, into: %{}, do: {{:input_register, i}, 1}
      coil_values = for i <- 2001..4001, into: %{}, do: {{:coil, i}, 1}
      discrete_input_values = for i <- 5001..7001, into: %{}, do: {{:discrete_input, i}, 1}

      all_values =
        %{}
        |> Map.merge(holding_register_values)
        |> Map.merge(input_register_values)
        |> Map.merge(coil_values)
        |> Map.merge(discrete_input_values)

      set_objects(device, all_values)

      single = [:holding_1, :holding_125]
      double = [:holding_1, :holding_125, :holding_126]

      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), single)
      assert 1 = get_read_count(device)

      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), double)
      assert 2 = get_read_count(device)

      single = [:input_201, :input_325]
      double = [:input_201, :input_325, :input_326]

      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), single)
      assert 1 = get_read_count(device)

      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), double)
      assert 2 = get_read_count(device)

      single = [:coil_2001, :coil_4000]
      double = [:coil_2001, :coil_4000, :coil_4001]

      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), single)
      assert 1 = get_read_count(device)

      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), double)
      assert 2 = get_read_count(device)

      single = [:discrete_input_5001, :discrete_input_7000]
      double = [:discrete_input_5001, :discrete_input_7000, :discrete_input_7001]

      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), single)
      assert 1 = get_read_count(device)

      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), double)
      assert 2 = get_read_count(device)
    end

    test "can customize batch sizes per object type" do
      schema = unique_module()
      max_holding_register_reads = Enum.random(1..3)
      max_input_register_reads = Enum.random(1..3)
      max_coil_reads = Enum.random(1..3)
      max_discrete_input_reads = Enum.random(1..3)

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema, max_batch_reads: [
            holding_registers: #{max_holding_register_reads},
            input_registers: #{max_input_register_reads},
            coils: #{max_coil_reads},
            discrete_inputs: #{max_discrete_input_reads}
          ]

        schema do
          holding_register 1, :holding_foo
          holding_register 2, :holding_bar
          holding_register 3, :holding_baz
          holding_register 4, :holding_qux

          input_register 5, :input_foo
          input_register 6, :input_bar
          input_register 7, :input_baz
          input_register 8, :input_qux

          coil 9, :coil_foo
          coil 10, :coil_bar
          coil 11, :coil_baz
          coil 12, :coil_qux

          discrete_input 13, :discrete_foo
          discrete_input 14, :discrete_bar
          discrete_input 15, :discrete_baz
          discrete_input 16, :discrete_qux
        end
      end
      """)

      values =
        for type <- [:holding_register, :input_register, :coil, :discrete_input],
            i <- 1..16,
            into: %{},
            do: {{type, i}, 1}

      device = start_supervised!({Agent, fn -> @initial_state end})
      set_objects(device, values)

      # Holding registers
      holding_registers = [:holding_foo, :holding_bar, :holding_baz, :holding_qux]

      single_read = Enum.take(holding_registers, max_holding_register_reads)
      assert {:ok, _} = ModBoss.read(schema, read_func(device), single_read)
      assert 1 = get_read_count(device)

      double_read = Enum.take(holding_registers, max_holding_register_reads + 1)
      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), double_read)
      assert 2 = get_read_count(device)

      # Input registers
      input_registers = [:input_foo, :input_bar, :input_baz, :input_qux]

      single_read = Enum.take(input_registers, max_input_register_reads)
      assert {:ok, _} = ModBoss.read(schema, read_func(device), single_read)
      assert 1 = get_read_count(device)

      double_read = Enum.take(input_registers, max_input_register_reads + 1)
      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), double_read)
      assert 2 = get_read_count(device)

      # Coils
      coils = [:coil_foo, :coil_bar, :coil_baz, :coil_qux]

      single_read = Enum.take(coils, max_coil_reads)
      assert {:ok, _} = ModBoss.read(schema, read_func(device), single_read)
      assert 1 = get_read_count(device)

      double_read = Enum.take(coils, max_coil_reads + 1)
      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), double_read)
      assert 2 = get_read_count(device)

      # Discrete Inputs
      discrete_inputs = [:discrete_foo, :discrete_bar, :discrete_baz, :discrete_qux]

      single_read = Enum.take(discrete_inputs, max_discrete_input_reads)
      assert {:ok, _} = ModBoss.read(schema, read_func(device), single_read)
      assert 1 = get_read_count(device)

      double_read = Enum.take(discrete_inputs, max_discrete_input_reads + 1)
      assert {:ok, %{}} = ModBoss.read(schema, read_func(device), double_read)
      assert 2 = get_read_count(device)
    end

    test "reads mappings of different object types separately" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1..2, :holding_1

          coil 101, :coil_1
          coil 102, :coil_2

          input_register 201, :input_1

          discrete_input 301, :discrete_1
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      set_objects(device, %{
        {:holding_register, 1} => 1,
        {:holding_register, 2} => 2,
        {:coil, 101} => 101,
        {:coil, 102} => 102,
        {:input_register, 201} => 201,
        {:discrete_input, 301} => 301
      })

      names = [:holding_1, :coil_1, :coil_2, :input_1, :discrete_1]

      {:ok, %{holding_1: [1, 2], coil_1: 101, coil_2: 102, input_1: 201, discrete_1: 301}} =
        ModBoss.read(schema, read_func(device), names)

      assert 4 == get_read_count(device)
    end

    test "raises an error if it doesn't get back the expected number of values" do
      device = start_supervised!({Agent, fn -> @initial_state end})
      encode_and_set(device, FakeSchema, foo: 1)

      assert_raise RuntimeError,
                   "Attempted to read 3 values starting from address 10 but received 0 values.",
                   fn ->
                     ModBoss.read(FakeSchema, read_func(device), [:foo, :qux])
                   end
    end

    test "decodes values per the `:as` option" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema
        alias ModBoss.Encoding

        schema do
          # Assumes the function lives in the current module…
          holding_register 1, :yep, as: :boolean
          holding_register 2, :nope, as: :boolean

          # Can explicitly specify the module
          holding_register 3..5, :text, as: {Encoding, :ascii}
        end

        def decode_boolean(0), do: {:ok, false}
        def decode_boolean(1), do: {:ok, true}
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      set_objects(device, %{
        {:holding_register, 1} => 1,
        {:holding_register, 2} => 0,
        {:holding_register, 3} => 20328,
        {:holding_register, 4} => 8311,
        {:holding_register, 5} => 28535
      })

      assert {:ok, %{yep: true, nope: false, text: "Oh wow"}} =
               ModBoss.read(schema, read_func(device), [:yep, :nope, :text])
    end

    test "returns an error if decoding fails" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          # Assumes the function lives in the current module…
          holding_register 1, :yep, as: :boolean
          holding_register 2, :nope, as: :boolean
        end

        def decode_boolean(0), do: {:ok, false}
        def decode_boolean(1), do: {:ok, true}
        def decode_boolean(value), do: {:error, "Not sure what to do with \#{value}."}
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      # only 1 and 2 are values expected to be decoded, so this will break…
      set_objects(device, %{
        {:holding_register, 1} => 1,
        {:holding_register, 2} => 33
      })

      message = "Failed to decode :nope. Not sure what to do with 33."
      assert {:error, ^message} = ModBoss.read(schema, read_func(device), [:yep, :nope])
    end

    test "allows reading of 'raw' values" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1, :yep, as: :boolean
          holding_register 2, :nope, as: :boolean
          holding_register 3..5, :text, as: {ModBoss.Encoding, :ascii}
        end

        def decode_boolean(0), do: {:ok, false}
        def decode_boolean(1), do: {:ok, true}
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      set_objects(device, %{
        {:holding_register, 1} => 1,
        {:holding_register, 2} => 0,
        {:holding_register, 3} => 18533,
        {:holding_register, 4} => 27756,
        {:holding_register, 5} => 28416
      })

      assert {:ok, %{yep: true, nope: false, text: "Hello"}} =
               ModBoss.read(schema, read_func(device), [:yep, :nope, :text])

      assert {:ok, %{yep: 1, nope: 0, text: [18533, 27756, 28416]}} =
               ModBoss.read(schema, read_func(device), [:yep, :nope, :text], decode: false)
    end

    test "bypasses (potentially-buggy) decode logic when asked to return raw values" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1, :yep, as: :boolean
          holding_register 2, :nope, as: :boolean
        end

        def decode_boolean(0), do: raise "bam!"
        def decode_boolean(1), do: raise "kapow!"
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      set_objects(device, %{
        {:holding_register, 1} => 1,
        {:holding_register, 2} => 0
      })

      assert {:ok, %{yep: 1, nope: 0}} =
               ModBoss.read(schema, read_func(device), [:yep, :nope], decode: false)
    end

    test "fetches all readable mappings if told to read `:all`" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1..2, :foo
          input_register 300, :bar
          coil 400, :baz
          discrete_input 500, :qux
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      set_objects(device, %{
        {:holding_register, 1} => 10,
        {:holding_register, 2} => 20,
        {:input_register, 300} => 30,
        {:coil, 400} => 0,
        {:discrete_input, 500} => 1
      })

      assert {:ok, result} = ModBoss.read(schema, read_func(device), :all)

      assert %{
               foo: [10, 20],
               bar: 30,
               baz: 0,
               qux: 1
             } == result
    end

    test "without `:max_gap` opt, makes separate requests for each non-contiguous mapping" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 0..1, :first_group
          holding_register 3..5, :filler
          holding_register 7..8, :second_group
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      values = Enum.into(0..8, %{}, fn i -> {{:holding_register, i}, i} end)
      set_objects(device, values)

      {:ok, _result} = ModBoss.read(schema, read_func(device), [:first_group, :second_group])

      # Should make 2 separate requests since they're not contiguous
      assert 2 = get_read_count(device)
    end

    test "accepts `:max_gap` scalar to batch reads across (known readable) unrequested mappings" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 0..5, :first_group
          holding_register 6..15, :filler_a
          holding_register 16..23, :second_group
          holding_register 24..34, :filler_b
          holding_register 35..37, :third_group
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      # Set up values for addresses 0-37 (including gaps between requested mappings)
      # The gaps (6-15 and 24-34) are mapped as readable filler, so gap tolerance can bridge them
      values = Enum.into(0..37, %{}, fn i -> {{:holding_register, i}, i} end)

      set_objects(device, values)

      {:ok, result} =
        ModBoss.read(schema, read_func(device), [:first_group, :second_group, :third_group],
          max_gap: 10
        )

      # Should make 2 requests:
      # 1. Addresses 0-23 (combines first_group and second_group with gap of exactly 10)
      # 2. Addresses 35-37 (gap of 11 is too large to combine with previous)
      assert 2 = get_read_count(device)

      # Verify correct values were read
      assert result[:first_group] == [0, 1, 2, 3, 4, 5]
      assert result[:second_group] == [16, 17, 18, 19, 20, 21, 22, 23]
      assert result[:third_group] == [35, 36, 37]
    end

    test "also accepts `:max_gap` as keyword list" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 0..5, :first_group
          holding_register 6..15, :filler_a
          holding_register 16..23, :second_group
          holding_register 24..34, :filler_b
          holding_register 35..37, :third_group
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})
      values = Enum.into(0..37, %{}, fn i -> {{:holding_register, i}, i} end)

      set_objects(device, values)

      {:ok, result} =
        ModBoss.read(schema, read_func(device), [:first_group, :second_group, :third_group],
          max_gap: [holding_registers: 10]
        )

      assert 2 = get_read_count(device)

      # Verify correct values were read
      assert result[:first_group] == [0, 1, 2, 3, 4, 5]
      assert result[:second_group] == [16, 17, 18, 19, 20, 21, 22, 23]
      assert result[:third_group] == [35, 36, 37]
    end

    test "also accepts `:max_gap` as map" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 0..5, :first_group
          holding_register 6..15, :filler_a
          holding_register 16..23, :second_group
          holding_register 24..34, :filler_b
          holding_register 35..37, :third_group
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})
      values = Enum.into(0..37, %{}, fn i -> {{:holding_register, i}, i} end)

      set_objects(device, values)

      {:ok, result} =
        ModBoss.read(schema, read_func(device), [:first_group, :second_group, :third_group],
          max_gap: %{holding_registers: 10}
        )

      assert 2 = get_read_count(device)

      # Verify correct values were read
      assert result[:first_group] == [0, 1, 2, 3, 4, 5]
      assert result[:second_group] == [16, 17, 18, 19, 20, 21, 22, 23]
      assert result[:third_group] == [35, 36, 37]
    end

    test "supports `:max_gap` for all object types" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 0..1, :first_group
          holding_register 2..3, :filler_a
          holding_register 4..5, :second_group

          input_register 0..1, :third_group
          input_register 2..3, :filler_b
          input_register 4..5, :fourth_group

          coil 0..1, :fifth_group
          coil 2..3, :filler_c
          coil 4..5, :sixth_group

          discrete_input 0..1, :seventh_group
          discrete_input 2..3, :filler_d
          discrete_input 4..5, :eighth_group
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      values =
        for type <- [:holding_register, :input_register, :coil, :discrete_input],
            i <- 0..5,
            into: %{},
            do: {{type, i}, i}

      set_objects(device, values)

      {:ok, result} =
        ModBoss.read(
          schema,
          read_func(device),
          [
            :first_group,
            :second_group,
            :third_group,
            :fourth_group,
            :fifth_group,
            :sixth_group,
            :seventh_group,
            :eighth_group
          ],
          max_gap: 10
        )

      assert 4 = get_read_count(device)

      # Verify correct values were read
      assert result[:first_group] == [0, 1]
      assert result[:second_group] == [4, 5]
      assert result[:third_group] == [0, 1]
      assert result[:fourth_group] == [4, 5]
      assert result[:fifth_group] == [0, 1]
      assert result[:sixth_group] == [4, 5]
      assert result[:seventh_group] == [0, 1]
      assert result[:eighth_group] == [4, 5]
    end

    test "logs a warning and uses the default gap size if unsupported keys are used with `max_gap`" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 0..5, :first_group
          holding_register 6..15, :filler_a
          holding_register 16..23, :second_group
          holding_register 24..34, :filler_b
          holding_register 35..37, :third_group
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})
      values = Enum.into(0..37, %{}, fn i -> {{:holding_register, i}, i} end)

      set_objects(device, values)

      # max_gap as a map
      assert capture_log(fn ->
               ModBoss.read(schema, read_func(device), [:first_group, :second_group],
                 max_gap: %{foo: 1}
               )
             end) =~ "Invalid :foo gap size specified"

      assert 2 = get_read_count(device)

      # max_gap as a keyword list
      assert capture_log(fn ->
               ModBoss.read(schema, read_func(device), [:first_group, :second_group],
                 max_gap: [bar: 10]
               )
             end) =~ "Invalid :bar gap size specified"

      assert 2 = get_read_count(device)
    end

    test "logs a warning and uses the default gap size when `:max_gap` value is not an integer" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 0..5, :first_group
          holding_register 6..15, :filler_a
          holding_register 16..23, :second_group
          holding_register 24..34, :filler_b
          holding_register 35..37, :third_group
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})
      values = Enum.into(0..37, %{}, fn i -> {{:holding_register, i}, i} end)

      set_objects(device, values)

      # max_gap as a map
      assert capture_log(fn ->
               ModBoss.read(schema, read_func(device), [:first_group, :second_group],
                 max_gap: %{holding_registers: "nope", input_registers: 3.14159}
               )
             end) =~ "Invalid max gap size"

      assert 2 = get_read_count(device)

      # max_gap as a keyword list
      assert capture_log(fn ->
               ModBoss.read(schema, read_func(device), [:first_group, :second_group],
                 max_gap: [holding_registers: {:yikes}]
               )
             end) =~ "Invalid max gap size"

      assert 2 = get_read_count(device)
    end
  end

  describe "ModBoss.write/3" do
    test "writes objects referenced by human-readable names from map" do
      device = start_supervised!({Agent, fn -> @initial_state end})
      :ok = ModBoss.write(FakeSchema, write_func(device), %{baz: 1, corge: 1234})
      assert %{{:holding_register, 3} => 1, {:holding_register, 15} => 1234} = get_objects(device)
    end

    test "writes objects referenced by human-readable names from keyword" do
      device = start_supervised!({Agent, fn -> @initial_state end})
      :ok = ModBoss.write(FakeSchema, write_func(device), baz: 1, corge: 1234)
      assert %{{:holding_register, 3} => 1, {:holding_register, 15} => 1234} = get_objects(device)
    end

    test "returns an error if any mapping names are unrecognized" do
      device = start_supervised!({Agent, fn -> @initial_state end})

      assert {:error, "Unknown mapping(s) :foobar, :bazqux for ModBossTest.FakeSchema."} =
               ModBoss.write(FakeSchema, write_func(device), %{foobar: 1, bazqux: 2})
    end

    test "refuses to write unless all mappings are declared writable" do
      device = start_supervised!({Agent, fn -> @initial_state end})

      initial_values = %{
        {:holding_register, 1} => 0,
        {:holding_register, 2} => 0,
        {:holding_register, 3} => 0
      }

      set_objects(device, initial_values)

      assert {:error, "ModBoss Mapping(s) :foo, :bar in ModBossTest.FakeSchema are not writable."} =
               ModBoss.write(FakeSchema, write_func(device), %{foo: 1, bar: 2, baz: 3})

      assert get_objects(device) == initial_values

      assert :ok = ModBoss.write(FakeSchema, write_func(device), %{baz: 3})
      assert get_objects(device) == Map.put(initial_values, {:holding_register, 3}, 3)
    end

    test "writes named mappings that span more than one address" do
      device = start_supervised!({Agent, fn -> @initial_state end})
      :ok = ModBoss.write(FakeSchema, write_func(device), %{qux: [0, 10, 20], quux: [-1, -2]})

      assert %{
               {:holding_register, 10} => 0,
               {:holding_register, 11} => 10,
               {:holding_register, 12} => 20,
               {:holding_register, 13} => -1,
               {:holding_register, 14} => -2
             } = get_objects(device)
    end

    test "encodes values per the `:as` option" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema
        alias ModBoss.Encoding

        schema do
          # Assumes the function lives in the current module…
          holding_register 1, :yep, as: :boolean, mode: :w
          holding_register 2, :nope, as: :boolean, mode: :w

          # Can explicitly specify the module
          holding_register 3..5, :text, as: {Encoding, :ascii}, mode: :w
        end

        def encode_boolean(false, _), do: {:ok, 0}
        def encode_boolean(true, _), do: {:ok, 1}
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      :ok = ModBoss.write(schema, write_func(device), %{yep: true, nope: false, text: "Oh wow"})

      assert %{
               {:holding_register, 1} => 1,
               {:holding_register, 2} => 0,
               {:holding_register, 3} => 20328,
               {:holding_register, 4} => 8311,
               {:holding_register, 5} => 28535
             } = get_objects(device)
    end

    test "returns an error if the number of values doesn't match the number of mapped addresses" do
      device = start_supervised!({Agent, fn -> @initial_state end})

      assert {:error,
              "Failed to encode :qux. Encoded value [100, 200] for :qux does not match the number of mapped addresses."} =
               ModBoss.write(FakeSchema, write_func(device), %{qux: [100, 200]})
    end

    test "batches contiguous writes for each object type up to the Modbus protocol's maximum" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1..122, :holding_1, mode: :w
          holding_register 123, :holding_123, mode: :w
          holding_register 124, :holding_124, mode: :w

          coil 1001..2967, :coil_1001, mode: :w
          coil 2968, :coil_2968, mode: :w
          coil 2969, :coil_2969, mode: :w
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      single_batch = %{holding_1: values(122), holding_123: 1}
      double_double = %{holding_1: values(122), holding_123: 1, holding_124: 1}

      assert :ok = ModBoss.write(schema, write_func(device), single_batch)
      assert 1 = get_write_count(device)

      assert :ok = ModBoss.write(schema, write_func(device), double_double)
      assert 2 = get_write_count(device)

      single_batch = %{coil_1001: values(1967), coil_2968: 1}
      double_batch = %{coil_1001: values(1967), coil_2968: 1, coil_2969: 1}

      assert :ok = ModBoss.write(schema, write_func(device), single_batch)
      assert 1 = get_write_count(device)

      assert :ok = ModBoss.write(schema, write_func(device), double_batch)
      assert 2 = get_write_count(device)
    end

    test "writes mappings of different object types separately" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1, :holding_1, mode: :w
          holding_register 2, :holding_2, mode: :w

          coil 101, :coil_1, mode: :w
          coil 102, :coil_2, mode: :w
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      values = %{holding_1: 1, holding_2: 2, coil_1: 3, coil_2: 4}
      :ok = ModBoss.write(schema, write_func(device), values)

      assert 2 == get_write_count(device)

      assert %{
               {:holding_register, 1} => 1,
               {:holding_register, 2} => 2,
               {:coil, 101} => 3,
               {:coil, 102} => 4
             } = get_objects(device)
    end

    # TODO: implication: mappings larger than the max batch size will fail
    test "doesn't split writes for a single mapping across batches" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema, max_batch_writes: %{holding_registers: 2, coils: 2}

        schema do
          holding_register 1, :holding_foo, mode: :w
          holding_register 2..3, :holding_bar, mode: :w
          holding_register 4, :holding_baz, mode: :w

          coil 9, :coil_foo, mode: :w
          coil 10..11, :coil_bar, mode: :w
          coil 12, :coil_baz, mode: :w
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      assert :ok =
               ModBoss.write(schema, write_func(device), %{
                 holding_foo: 1,
                 holding_bar: [1, 1],
                 holding_baz: 1
               })

      assert 3 = get_write_count(device)

      assert :ok =
               ModBoss.write(schema, write_func(device), %{
                 coil_foo: 1,
                 coil_bar: [1, 1],
                 coil_baz: 1
               })

      assert 3 = get_write_count(device)
    end

    test "doesn't batch writes across address gaps" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo, mode: :rw
          holding_register 3, :bar, mode: :rw
        end
      end
      """)

      device = start_supervised!({Agent, fn -> @initial_state end})

      :ok = ModBoss.write(schema, write_func(device), %{foo: 10, bar: 50})

      assert 2 = get_write_count(device)
      assert %{{:holding_register, 1} => 10, {:holding_register, 3} => 50} = get_objects(device)
    end
  end

  describe "ModBoss.encode/2" do
    test "translates values from a Keyword List per the schema" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema
        alias ModBoss.Encoding

        schema do
          holding_register 1, :foo, as: {Encoding, :boolean}
          holding_register 2, :bar, as: {Encoding, :boolean}
          holding_register 3..4, :baz, as: {Encoding, :ascii}
          input_register 100, :qux
          coil 101, :quux
          discrete_input 102, :corge
        end
      end
      """)

      assert {:ok,
              %{
                {:holding_register, 1} => 1,
                {:holding_register, 2} => 0,
                {:holding_register, 3} => 22383,
                {:holding_register, 4} => 30497,
                {:input_register, 100} => 3,
                {:coil, 101} => 2,
                {:discrete_input, 102} => 1
              }} =
               ModBoss.encode(schema,
                 foo: true,
                 bar: false,
                 baz: "Wow!",
                 qux: 3,
                 quux: 2,
                 corge: 1
               )
    end

    test "translates values from a map per the schema" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema
        alias ModBoss.Encoding

        schema do
          holding_register 1, :foo, as: {Encoding, :boolean}
          holding_register 2, :bar, as: {Encoding, :boolean}
          holding_register 3..4, :baz, as: {Encoding, :ascii}
          input_register 100, :qux
          coil 101, :quux
          discrete_input 102, :corge
        end
      end
      """)

      assert {:ok,
              %{
                {:holding_register, 1} => 1,
                {:holding_register, 2} => 0,
                {:holding_register, 3} => 22383,
                {:holding_register, 4} => 30497,
                {:input_register, 100} => 3,
                {:coil, 101} => 2,
                {:discrete_input, 102} => 1
              }} =
               ModBoss.encode(schema, %{
                 foo: true,
                 bar: false,
                 baz: "Wow!",
                 qux: 3,
                 quux: 2,
                 corge: 1
               })
    end

    test "returns an error if any mapping names are unrecognized" do
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1, :foo
          holding_register 2, :bar
        end
      end
      """)

      assert {:error, message} = ModBoss.encode(schema, %{foo: 1, bar: 2, baz: 3})
      assert String.match?(message, ~r/Unknown mapping/i)

      assert {:ok, _encoded_values} = ModBoss.encode(schema, %{foo: 1, bar: 2})
    end
  end

  defp encode_and_set(device, schema, values) do
    {:ok, encoded} = ModBoss.encode(schema, values)
    set_objects(device, encoded)
  end

  defp set_objects(device, %{} = values) when is_pid(device) do
    keys = Map.keys(values)

    if not Enum.all?(keys, &match?({type, addr} when is_atom(type) and is_integer(addr), &1)) do
      raise """
      The fake test device expects {type, address} tuple keys.
      Use set_objects/2 with keys like {:holding_register, 1} or use encode_and_set/3.
      """
    end

    Agent.update(device, fn state ->
      updated_objects = Map.merge(state.objects, values)
      %{state | objects: updated_objects}
    end)
  end

  defp get_objects(device) when is_pid(device) do
    Agent.get(device, fn state -> state.objects end)
  end

  # Getting the write count also resets it
  defp get_write_count(device) when is_pid(device) do
    Agent.get_and_update(device, fn state -> {state.writes, %{state | writes: 0}} end)
  end

  # Getting the read count also resets it
  defp get_read_count(device) when is_pid(device) do
    Agent.get_and_update(device, fn state -> {state.reads, %{state | reads: 0}} end)
  end

  defp read_func(device) when is_pid(device) do
    fn type, starting_address, count ->
      range = starting_address..(starting_address + count - 1)
      keys = Enum.map(range, &{type, &1})

      values =
        Agent.get(device, fn state ->
          state.objects
          |> Map.take(keys)
          |> Enum.sort_by(fn {{_type, address}, _value} -> address end)
          |> Enum.map(fn {_key, value} -> value end)
        end)

      Agent.update(device, fn state -> %{state | reads: state.reads + 1} end)

      case values do
        [single_value] -> {:ok, single_value}
        values when is_list(values) -> {:ok, values}
      end
    end
  end

  defp write_func(device) when is_pid(device) do
    fn type, starting_address, values ->
      objects =
        values
        |> List.wrap()
        |> Enum.with_index(starting_address)
        |> Enum.into(%{}, fn {value, address} -> {{type, address}, value} end)

      Agent.update(device, fn state ->
        updated_objects = Map.merge(state.objects, objects)
        %{state | objects: updated_objects, writes: state.writes + 1}
      end)
    end
  end

  defp values(count) do
    for _i <- 1..count do
      1
    end
  end

  defp unique_module do
    name = "#{__MODULE__}#{System.unique_integer([:positive])}"
    Module.concat([name])
  end
end
