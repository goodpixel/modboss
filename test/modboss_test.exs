defmodule ModBossTest do
  use ExUnit.Case
  doctest ModBoss

  defmodule FakeSchema do
    use ModBoss.Schema

    modbus_schema do
      holding_register 1, :foo
      holding_register 2, :bar, mode: :r
      holding_register 3, :baz, mode: :w
      holding_register 4, :blah, mode: :rw
      holding_register 100..102, :qux, mode: :rw
      holding_register 103..104, :quux, mode: :rw
      holding_register 105, :corge, mode: :rw

      coil 106, :grault, mode: :rw
      coil 107, :garply, mode: :rw

      for i <- 201..330 do
        coil i, String.to_atom("foo_#{i}"), mode: :rw
      end
    end
  end

  @empty_agent %{
    writes: 0,
    registers: %{}
  }

  setup do
    {:ok, device_pid} = start_supervised({Agent, fn -> @empty_agent end})
    %{device: device_pid}
  end

  describe "ModBoss.write/4" do
    test "writes registers referenced by human-readable names from map", %{device: device} do
      :ok = ModBoss.write(FakeSchema, write_func(device), %{baz: 1, corge: 1234})
      assert %{3 => 1, 105 => 1234} = get_registers(device)
    end

    test "writes registers referenced by human-readable names from keyword", %{device: device} do
      :ok = ModBoss.write(FakeSchema, write_func(device), baz: 1, corge: 1234)
      assert %{3 => 1, 105 => 1234} = get_registers(device)
    end

    test "returns an error if any register names are unrecognized", %{device: device} do
      assert {:error, "Unknown register(s) :foobar, :bazqux for ModBossTest.FakeSchema."} =
               ModBoss.write(FakeSchema, write_func(device), %{foobar: 1, bazqux: 2})
    end

    test "refuses to write unless all registers are declared writeable", %{device: device} do
      initial_values = %{1 => 0, 2 => 0, 3 => 0}
      set_registers(device, initial_values)

      assert {:error, "Register(s) :foo, :bar in ModBossTest.FakeSchema are not writable."} =
               ModBoss.write(FakeSchema, write_func(device), %{foo: 1, bar: 2, baz: 3})

      assert get_registers(device) == initial_values

      assert :ok = ModBoss.write(FakeSchema, write_func(device), %{baz: 3})
      assert get_registers(device) == Map.put(initial_values, 3, 3)
    end

    test "writes named registers that span more than one actual register", %{device: device} do
      :ok = ModBoss.write(FakeSchema, write_func(device), %{qux: [0, 100, 200], quux: [-1, -2]})
      assert %{100 => 0, 101 => 100, 102 => 200, 103 => -1, 104 => -2} = get_registers(device)
    end

    test "returns an error if the number of values doesn't match the number of registers", %{
      device: device
    } do
      assert {:error,
              "Failed to encode :qux. Encoded value `[100, 200]` does not match the expected number of registers."} =
               ModBoss.write(FakeSchema, write_func(device), %{qux: [100, 200]})
    end

    test "batches contiguous writes", %{device: device} do
      :ok =
        ModBoss.write(FakeSchema, write_func(device), %{
          baz: 30,
          blah: 40,
          qux: [1000, 1001, 1002],
          quux: [1003, 1004]
        })

      assert 2 = get_write_count(device)

      assert %{
               3 => 30,
               4 => 40,
               100 => 1000,
               101 => 1001,
               102 => 1002,
               103 => 1003,
               104 => 1004
             } = get_registers(device)
    end

    test "separately batches contiguous writes of different register types", %{device: device} do
      register_types =
        FakeSchema.__modbus_schema__()
        |> Enum.map(fn {_name, mapping} -> mapping.type end)
        |> Enum.uniq()

      :ok = ModBoss.write(FakeSchema, write_func(device), %{corge: 1050, grault: 0, garply: 1})

      assert %{105 => 1050, 106 => 0, 107 => 1} = get_registers(device)
      assert get_write_count(device) == length(register_types)
    end

    # Max registers to write in one pass over TCP is 120. Over RTU it's 123. Keeping things simple here…
    @max_writes_per_batch 120

    test "writes up to #{@max_writes_per_batch} registers in a single batch", %{device: device} do
      single_batch =
        for i <- 201..(201 + @max_writes_per_batch - 1), into: %{} do
          {String.to_atom("foo_#{i}"), 1}
        end

      assert length(Map.keys(single_batch)) == 120

      :ok = ModBoss.write(FakeSchema, write_func(device), single_batch)
      assert 1 = get_write_count(device)
    end

    test "writes more than #{@max_writes_per_batch} registers in a 2nd batch", %{device: device} do
      multiple_batches =
        for i <- 201..(201 + @max_writes_per_batch), into: %{} do
          {String.to_atom("foo_#{i}"), 1}
        end

      :ok = ModBoss.write(FakeSchema, write_func(device), multiple_batches)
      assert 2 = get_write_count(device)
    end
  end

  defp set_registers(device, %{} = values) when is_pid(device) do
    keys_to_set = Map.keys(values)

    if not Enum.all?(keys_to_set, &is_integer/1) do
      raise """
      The fake test device uses a map with integer keys to simulate a real device. \n
      Manually set registers using their numeric address rather than their human name.
      """
    end

    Agent.update(device, fn state ->
      updated_registers = Map.merge(state.registers, values)
      %{state | registers: updated_registers}
    end)
  end

  defp get_registers(device) when is_pid(device) do
    Agent.get(device, fn state -> state.registers end)
  end

  defp get_write_count(device) when is_pid(device) do
    Agent.get(device, fn state -> state.writes end)
  end

  defp write_func(device) when is_pid(device) do
    fn _type, starting_address, values ->
      registers =
        values
        |> List.wrap()
        |> Enum.with_index(starting_address)
        |> Enum.into(%{}, fn {value, address} -> {address, value} end)

      Agent.update(device, fn state ->
        updated_registers = Map.merge(state.registers, registers)
        %{state | registers: updated_registers, writes: state.writes + 1}
      end)
    end
  end
end
