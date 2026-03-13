defmodule ModBoss.TelemetryTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  defmodule TestSchema do
    use ModBoss.Schema

    schema do
      holding_register 1, :foo
      holding_register 2, :bar, mode: :r
      holding_register 3, :baz, mode: :w
      holding_register 4, :blah, mode: :rw
      holding_register 10..12, :qux, mode: :rw

      coil 100, :grault, mode: :rw
    end
  end

  # A schema where all addresses are readable, enabling gap bridging
  defmodule GapSchema do
    use ModBoss.Schema

    schema do
      holding_register 1, :alpha, mode: :rw
      holding_register 2, :bravo, mode: :rw
      holding_register 3, :charlie, mode: :rw
      holding_register 4, :delta, mode: :rw
      holding_register 5, :echo, mode: :rw

      holding_register 10, :foxtrot, mode: :rw
      holding_register 11, :golf, mode: :rw
      holding_register 12, :hotel, mode: :rw
    end
  end

  describe "read/4 telemetry" do
    setup do
      attach_many([
        [:modboss, :read, :start],
        [:modboss, :read, :stop],
        [:modboss, :read, :exception],
        [:modboss, :read_request, :start],
        [:modboss, :read_request, :stop],
        [:modboss, :read_request, :exception]
      ])

      device = start_supervised!({Agent, fn -> %{reads: 0, writes: 0, objects: %{}} end})
      %{device: device}
    end

    test "emits :read start and stop spans for a successful read", %{device: device} do
      set_objects(device, %{{:holding_register, 1} => 42})

      {:ok, 42} = ModBoss.read(TestSchema, read_func(device), :foo)

      # Per-operation start
      assert_receive {:telemetry, [:modboss, :read, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.schema == TestSchema
      assert start_metadata.names == [:foo]

      # Per-operation stop
      assert_receive {:telemetry, [:modboss, :read, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_measurements.modbus_requests == 1
      assert stop_measurements.objects_requested == 1
      assert stop_measurements.addresses_read == 1
      assert stop_measurements.gap_addresses_read == 0
      assert stop_measurements.max_gap_size == 0
      assert stop_metadata.schema == TestSchema
      assert stop_metadata.names == [:foo]
      assert stop_metadata.result == {:ok, 42}
    end

    test "emits :read_request start and stop spans for each read callback", %{device: device} do
      set_objects(device, %{{:holding_register, 1} => 42})

      {:ok, 42} = ModBoss.read(TestSchema, read_func(device), :foo)

      # Per-request start
      assert_receive {:telemetry, [:modboss, :read_request, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.schema == TestSchema
      assert start_metadata.object_type == :holding_register
      assert start_metadata.starting_address == 1
      assert start_metadata.address_count == 1

      # Per-request stop
      assert_receive {:telemetry, [:modboss, :read_request, :stop], stop_measurements,
                      stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_measurements.gap_addresses_read == 0
      assert stop_measurements.max_gap_size == 0
      assert stop_metadata.schema == TestSchema
      assert stop_metadata.object_type == :holding_register
      assert stop_metadata.starting_address == 1
      assert stop_metadata.address_count == 1
      assert stop_metadata.result == {:ok, 42}
    end

    test "emits aggregated data for the :read event", %{device: device} do
      # holding_register 1 and coil 100 are different types, so they'll be separate requests
      set_objects(device, %{
        {:holding_register, 1} => 10,
        {:holding_register, 2} => 20,
        {:coil, 100} => 1
      })

      {:ok, %{foo: 10, bar: 20, grault: 1}} =
        ModBoss.read(TestSchema, read_func(device), [:foo, :bar, :grault])

      # Callback requests
      assert_receive {:telemetry, [:modboss, :read_request, :stop], _m1, meta1}
      assert_receive {:telemetry, [:modboss, :read_request, :stop], _m2, meta2}

      # Batched reads
      assert_receive {:telemetry, [:modboss, :read, :stop], read_measurements, _stop_metadata}
      assert read_measurements.modbus_requests == 2
      assert read_measurements.objects_requested == 3

      types = Enum.sort([meta1.object_type, meta2.object_type])
      assert types == [:coil, :holding_register]
    end

    test "emits correct counts for multi-address mappings", %{device: device} do
      set_objects(device, %{
        {:holding_register, 10} => 1,
        {:holding_register, 11} => 2,
        {:holding_register, 12} => 3
      })

      {:ok, [1, 2, 3]} = ModBoss.read(TestSchema, read_func(device), :qux)

      assert_receive {:telemetry, [:modboss, :read, :stop], read_measurements, _}
      assert read_measurements.objects_requested == 3
      assert read_measurements.addresses_read == 3
      assert read_measurements.modbus_requests == 1

      assert_receive {:telemetry, [:modboss, :read_request, :stop], _req_measurements, req_meta}
      assert req_meta.address_count == 3
    end

    test "reports gap measurements when max_gap bridges addresses", %{device: device} do
      # GapSchema: alpha(1), bravo(2), charlie(3), delta(4), echo(5)
      # Request alpha(1) and echo(5) with max_gap: 10
      # Gap addresses: 2, 3, 4 (bravo, charlie, delta — all readable)
      # Should bridge into one request reading addresses 1-5
      set_objects(device, %{
        {:holding_register, 1} => 10,
        {:holding_register, 2} => 20,
        {:holding_register, 3} => 30,
        {:holding_register, 4} => 40,
        {:holding_register, 5} => 50
      })

      {:ok, %{alpha: 10, echo: 50}} =
        ModBoss.read(GapSchema, read_func(device), [:alpha, :echo], max_gap: 10)

      # Per-operation: 1 request, 2 objects requested, 5 addresses read, 3 gap addresses
      assert_receive {:telemetry, [:modboss, :read, :stop], measurements, _}
      assert measurements.modbus_requests == 1
      assert measurements.objects_requested == 2
      assert measurements.addresses_read == 5
      assert measurements.gap_addresses_read == 3
      assert measurements.max_gap_size == 3

      # Per-request: single request spanning addresses 1-5
      assert_receive {:telemetry, [:modboss, :read_request, :stop], req_measurements, req_meta}
      assert req_meta.address_count == 5
      assert req_measurements.gap_addresses_read == 3
      assert req_measurements.max_gap_size == 3
    end

    test "reports multiple gaps correctly", %{device: device} do
      # GapSchema: alpha(1), charlie(3), echo(5) with gaps at 2 and 4
      # All addresses are readable so gaps can be bridged
      set_objects(device, %{
        {:holding_register, 1} => 10,
        {:holding_register, 2} => 20,
        {:holding_register, 3} => 30,
        {:holding_register, 4} => 40,
        {:holding_register, 5} => 50
      })

      {:ok, %{alpha: 10, charlie: 30, echo: 50}} =
        ModBoss.read(GapSchema, read_func(device), [:alpha, :charlie, :echo], max_gap: 10)

      assert_receive {:telemetry, [:modboss, :read, :stop], measurements, _}
      assert measurements.modbus_requests == 1
      assert measurements.objects_requested == 3
      assert measurements.addresses_read == 5
      assert measurements.gap_addresses_read == 2
      # Two gaps of size 1 each (addr 2 and addr 4)
      assert measurements.max_gap_size == 1

      assert_receive {:telemetry, [:modboss, :read_request, :stop], req_measurements, _}
      assert req_measurements.gap_addresses_read == 2
      assert req_measurements.max_gap_size == 1
    end

    test "reports zero gap measurements without max_gap", %{device: device} do
      set_objects(device, %{
        {:holding_register, 1} => 10,
        {:holding_register, 2} => 20
      })

      {:ok, %{foo: 10, bar: 20}} = ModBoss.read(TestSchema, read_func(device), [:foo, :bar])

      assert_receive {:telemetry, [:modboss, :read, :stop], measurements, _}
      assert measurements.gap_addresses_read == 0
      assert measurements.max_gap_size == 0
      assert measurements.addresses_read == measurements.objects_requested
    end

    test "includes names as a list even for singular reads", %{device: device} do
      set_objects(device, %{{:holding_register, 1} => 42})
      {:ok, 42} = ModBoss.read(TestSchema, read_func(device), :foo)

      assert_receive {:telemetry, [:modboss, :read, :start], _, %{names: names}}
      assert names == [:foo]
    end

    test "includes all requested names for plural reads", %{device: device} do
      set_objects(device, %{
        {:holding_register, 1} => 10,
        {:holding_register, 2} => 20
      })

      {:ok, %{foo: 10, bar: 20}} = ModBoss.read(TestSchema, read_func(device), [:foo, :bar])

      assert_receive {:telemetry, [:modboss, :read, :start], _, %{names: names}}
      assert Enum.sort(names) == [:bar, :foo]
    end

    test "emits stop with error result when read_func returns an error", %{device: _device} do
      failing_read_func = fn _type, _addr, _count -> {:error, "connection refused"} end
      {:error, "connection refused"} = ModBoss.read(TestSchema, failing_read_func, :foo)

      assert_receive {:telemetry, [:modboss, :read, :start], _, _}
      assert_receive {:telemetry, [:modboss, :read, :stop], _, read_metadata}
      assert read_metadata.result == {:error, "connection refused"}

      assert_receive {:telemetry, [:modboss, :read_request, :start], _, _}
      assert_receive {:telemetry, [:modboss, :read_request, :stop], _, req_metadata}
      assert req_metadata.result == {:error, "connection refused"}
    end

    test "emits exception event when read_func raises", %{device: _device} do
      boom_func = fn _type, _addr, _count ->
        raise "boom!"
      end

      assert_raise RuntimeError, "boom!", fn ->
        ModBoss.read(TestSchema, boom_func, :foo)
      end

      assert_receive {:telemetry, [:modboss, :read_request, :start], _, _}
      assert_receive {:telemetry, [:modboss, :read_request, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "boom!"} = metadata.reason
      assert is_list(metadata.stacktrace)

      assert_receive {:telemetry, [:modboss, :read, :start], _, _}
      assert_receive {:telemetry, [:modboss, :read, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "boom!"} = metadata.reason
    end

    test "does not emit events for validation errors (e.g. unknown names)", %{device: device} do
      {:error, _} = ModBoss.read(TestSchema, read_func(device), :nonexistent)

      refute_receive {:telemetry, [:modboss, :read, :start], _, _}
      refute_receive {:telemetry, [:modboss, :read_request, :start], _, _}
    end
  end

  describe "write/3 telemetry" do
    setup do
      attach_many([
        [:modboss, :write, :start],
        [:modboss, :write, :stop],
        [:modboss, :write, :exception],
        [:modboss, :write_request, :start],
        [:modboss, :write_request, :stop],
        [:modboss, :write_request, :exception]
      ])

      device = start_supervised!({Agent, fn -> %{reads: 0, writes: 0, objects: %{}} end})
      %{device: device}
    end

    test "emits :write start and stop spans for a successful write", %{device: device} do
      :ok = ModBoss.write(TestSchema, write_func(device), baz: 99)

      # Per-operation start
      assert_receive {:telemetry, [:modboss, :write, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.schema == TestSchema
      assert start_metadata.names == [:baz]

      # Per-operation stop
      assert_receive {:telemetry, [:modboss, :write, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_measurements.modbus_requests == 1
      assert stop_measurements.objects_requested == 1
      assert stop_metadata.schema == TestSchema
      assert stop_metadata.names == [:baz]
      assert stop_metadata.result == :ok
    end

    test "emits :write_request start and stop spans for each write callback", %{device: device} do
      :ok = ModBoss.write(TestSchema, write_func(device), baz: 99)

      # Per-request start
      assert_receive {:telemetry, [:modboss, :write_request, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.schema == TestSchema
      assert start_metadata.object_type == :holding_register
      assert start_metadata.starting_address == 3
      assert start_metadata.address_count == 1

      # Per-request stop
      assert_receive {:telemetry, [:modboss, :write_request, :stop], stop_measurements,
                      stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.schema == TestSchema
      assert stop_metadata.object_type == :holding_register
      assert stop_metadata.starting_address == 3
      assert stop_metadata.address_count == 1
      assert stop_metadata.result == :ok
    end

    test "emits aggregated data for the :write event", %{device: device} do
      :ok = ModBoss.write(TestSchema, write_func(device), baz: 1, blah: 1, grault: 1)

      # Callback requests
      assert_receive {:telemetry, [:modboss, :write_request, :stop], _, meta1}
      assert_receive {:telemetry, [:modboss, :write_request, :stop], _, meta2}

      # Batched writes
      assert_receive {:telemetry, [:modboss, :write, :stop], write_measurements, _}
      assert write_measurements.modbus_requests == 2
      assert write_measurements.objects_requested == 3

      types = Enum.sort([meta1.object_type, meta2.object_type])
      assert types == [:coil, :holding_register]
    end

    test "emits correct counts for multi-address writes", %{device: device} do
      :ok = ModBoss.write(TestSchema, write_func(device), qux: [1, 2, 3])

      assert_receive {:telemetry, [:modboss, :write, :stop], write_measurements, _}
      assert write_measurements.objects_requested == 3
      assert write_measurements.modbus_requests == 1

      assert_receive {:telemetry, [:modboss, :write_request, :stop], _req_measurements, req_meta}
      assert req_meta.address_count == 3
    end

    test "emits stop with error result when write_func returns an error", %{device: _device} do
      failing_write_func = fn _type, _addr, _values ->
        {:error, "device busy"}
      end

      {:error, "device busy"} = ModBoss.write(TestSchema, failing_write_func, baz: 1)

      assert_receive {:telemetry, [:modboss, :write, :start], _, _}
      assert_receive {:telemetry, [:modboss, :write, :stop], _, write_metadata}
      assert write_metadata.result == {:error, "device busy"}

      assert_receive {:telemetry, [:modboss, :write_request, :start], _, _}
      assert_receive {:telemetry, [:modboss, :write_request, :stop], _, req_metadata}
      assert req_metadata.result == {:error, "device busy"}
    end

    test "emits exception event when write_func raises", %{device: _device} do
      kaboom_func = fn _type, _addr, _values ->
        raise "kaboom!"
      end

      assert_raise RuntimeError, "kaboom!", fn ->
        ModBoss.write(TestSchema, kaboom_func, baz: 1)
      end

      assert_receive {:telemetry, [:modboss, :write_request, :start], _, _}
      assert_receive {:telemetry, [:modboss, :write_request, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "kaboom!"} = metadata.reason
      assert is_list(metadata.stacktrace)

      assert_receive {:telemetry, [:modboss, :write, :start], _, _}
      assert_receive {:telemetry, [:modboss, :write, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "kaboom!"} = metadata.reason
    end

    test "does not emit events for validation errors (e.g. unknown names)", %{device: device} do
      {:error, _} = ModBoss.write(TestSchema, write_func(device), nonexistent: 1)

      refute_receive {:telemetry, [:modboss, :write, :start], _, _}
      refute_receive {:telemetry, [:modboss, :write_request, :start], _, _}
    end
  end

  defp attach_many(events) do
    handler_id = "test-#{inspect(make_ref())}"
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach_many(handler_id, events, test_handler(self()), nil)
  end

  defp test_handler(test_pid) do
    fn event, measurements, metadata, _config ->
      # Ensure we're only handling telemetry we triggered within our own test,
      # not telemetry triggered by other tests running asynchronously.
      if self() == test_pid do
        send(test_pid, {:telemetry, event, measurements, metadata})
      end
    end
  end

  defp set_objects(device, %{} = values) do
    Agent.update(device, fn state ->
      %{state | objects: Map.merge(state.objects, values)}
    end)
  end

  defp read_func(device) do
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

  defp write_func(device) do
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
end
