defmodule ModBoss.TelemetryTest do
  use ExUnit.Case, async: true
  import ModBoss.CallbackHelpers
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
        [:modboss, :read_callback, :start],
        [:modboss, :read_callback, :stop],
        [:modboss, :read_callback, :exception]
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
      assert stop_measurements.total_attempts == 1
      assert stop_metadata.schema == TestSchema
      assert stop_metadata.names == [:foo]
      assert stop_metadata.result == {:ok, 42}
    end

    test "emits :read_callback start and stop spans for each read callback", %{device: device} do
      set_objects(device, %{{:holding_register, 1} => 42})

      {:ok, 42} = ModBoss.read(TestSchema, read_func(device), :foo)

      # Per-request start
      assert_receive {:telemetry, [:modboss, :read_callback, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.schema == TestSchema
      assert start_metadata.names == [:foo]
      assert start_metadata.object_type == :holding_register
      assert start_metadata.starting_address == 1
      assert start_metadata.address_count == 1
      assert start_metadata.attempt == 1
      assert start_metadata.max_attempts == 1

      # Per-request stop
      assert_receive {:telemetry, [:modboss, :read_callback, :stop], stop_measurements,
                      stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_measurements.gap_addresses_read == 0
      assert stop_measurements.max_gap_size == 0
      assert stop_metadata.schema == TestSchema
      assert stop_metadata.names == [:foo]
      assert stop_metadata.object_type == :holding_register
      assert stop_metadata.starting_address == 1
      assert stop_metadata.address_count == 1
      assert stop_metadata.attempt == 1
      assert stop_metadata.max_attempts == 1
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
      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _m1, meta1}
      assert meta1.attempt == 1
      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _m2, meta2}
      assert meta2.attempt == 1

      # Batched reads
      assert_receive {:telemetry, [:modboss, :read, :stop], read_measurements, _stop_metadata}
      assert read_measurements.modbus_requests == 2
      assert read_measurements.objects_requested == 3
      assert read_measurements.total_attempts == 2

      types = Enum.sort([meta1.object_type, meta2.object_type])
      assert types == [:coil, :holding_register]

      # Each callback only includes names for its batch
      hr_meta = Enum.find([meta1, meta2], &(&1.object_type == :holding_register))
      coil_meta = Enum.find([meta1, meta2], &(&1.object_type == :coil))
      assert Enum.sort(hr_meta.names) == [:bar, :foo]
      assert coil_meta.names == [:grault]
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
      assert read_measurements.total_attempts == 1

      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _req_measurements, req_meta}
      assert req_meta.address_count == 3
      assert req_meta.attempt == 1
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
      assert measurements.total_attempts == 1

      # Per-request: single request spanning addresses 1-5
      assert_receive {:telemetry, [:modboss, :read_callback, :stop], req_measurements, req_meta}
      assert req_meta.address_count == 5
      assert req_meta.attempt == 1
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
      assert measurements.total_attempts == 1

      assert_receive {:telemetry, [:modboss, :read_callback, :stop], req_measurements, req_meta}
      assert req_meta.attempt == 1
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
      assert measurements.total_attempts == 1
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

      assert_receive {:telemetry, [:modboss, :read, :stop], stop_measurements, read_metadata}
      assert read_metadata.schema == TestSchema
      assert read_metadata.names == [:foo]
      assert read_metadata.result == {:error, "connection refused"}

      # 1 object requested, 1 request attempted, 1 address attempted
      assert stop_measurements.objects_requested == 1
      assert stop_measurements.modbus_requests == 1
      assert stop_measurements.addresses_read == 1
      assert stop_measurements.gap_addresses_read == 0
      assert stop_measurements.max_gap_size == 0
      assert stop_measurements.total_attempts == 1

      assert_receive {:telemetry, [:modboss, :read_callback, :start], _, _}
      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _, req_metadata}
      assert req_metadata.attempt == 1
      assert req_metadata.result == {:error, "connection refused"}
    end

    test "reports attempted stats on partial read failure", %{device: device} do
      # 3 batches planned:
      # We'll succeed on the 1st and fail on the 2nd — the 3rd is never attempted.
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema

        schema do
          holding_register 1, :alpha
          holding_register 2..3, :filler_a
          holding_register 4, :bravo

          holding_register 6, :charlie
          holding_register 7..9, :filler_b
          holding_register 10, :delta

          holding_register 12, :echo
          holding_register 13..19, :foxtrot
          holding_register 20, :golf
        end
      end
      """)

      set_objects(device, Enum.into(1..11, %{}, &{{:holding_register, &1}, &1}))

      failing_on_second = fn type, starting_address, count ->
        reads = Agent.get(device, & &1.reads)

        if reads > 0 do
          {:error, "timeout"}
        else
          read_func(device).(type, starting_address, count)
        end
      end

      {:error, "timeout"} =
        ModBoss.read(
          schema,
          failing_on_second,
          [:alpha, :bravo, :charlie, :delta, :echo, :golf],
          max_gap: 5
        )

      assert_receive {:telemetry, [:modboss, :read, :stop], measurements, metadata}
      assert metadata.result == {:error, "timeout"}

      # 3 planned, but only 2 attempted (1 succeeded + 1 failed)
      assert measurements.modbus_requests == 2

      # 2 objects in chunk 1 + 2 objects in chunk 2
      assert measurements.objects_requested == 4

      # 4 addresses in chunk 1 + 5 addresses in chunk 2
      assert measurements.addresses_read == 9

      # 2 gap addresses in chunk 1 + 3 gap addresses in chunk 2
      assert measurements.gap_addresses_read == 5

      # 3 gap addresses from chunk 2 (vs. 2 gap address from chunk 1)
      assert measurements.max_gap_size == 3

      # attempted the read callback twice
      assert measurements.total_attempts == 2
    end

    test "retries emit per-attempt callback spans and total_attempts", %{device: device} do
      # 2 batches (holding_register + coil), each fails once before succeeding
      set_objects(device, %{
        {:holding_register, 1} => 10,
        {:coil, 100} => 1
      })

      flaky_read = flakify(read_func(device), fn -> {:error, "flaky"} end, flakes: 1)

      # Each callback will be attempted twice for a total of 4 attempts in the end…
      {:ok, %{foo: 10, grault: 1}} =
        ModBoss.read(TestSchema, flaky_read, [:foo, :grault], max_attempts: 2)

      # Batch 1: attempt 1 fails, attempt 2 succeeds
      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _, cb1_attempt1}
      assert cb1_attempt1.attempt == 1
      assert cb1_attempt1.max_attempts == 2
      assert cb1_attempt1.result == {:error, "flaky"}

      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _, cb1_attempt2}
      assert cb1_attempt2.attempt == 2
      assert cb1_attempt2.max_attempts == 2
      assert {:ok, _} = cb1_attempt2.result

      # Batch 2: same pattern
      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _, cb2_attempt1}
      assert cb2_attempt1.attempt == 1
      assert cb2_attempt1.max_attempts == 2
      assert {:error, "flaky"} = cb2_attempt1.result

      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _, cb2_attempt2}
      assert cb2_attempt2.attempt == 2
      assert cb2_attempt2.max_attempts == 2
      assert {:ok, _} = cb2_attempt2.result

      # Outer span: 2 batches x 2 attempts = 4 total
      assert_receive {:telemetry, [:modboss, :read, :stop], measurements, _}
      assert measurements.total_attempts == 4
    end

    test "retries through exceptions and succeeds", %{device: device} do
      set_objects(device, %{{:holding_register, 1} => 42})
      raising_read = flakify(read_func(device), fn -> raise "raised!" end, flakes: 1)

      {:ok, 42} = ModBoss.read(TestSchema, raising_read, :foo, max_attempts: 2)

      # Attempt 1: raise, callback exception span
      assert_receive {:telemetry, [:modboss, :read_callback, :exception], _, meta1}
      assert meta1.attempt == 1
      assert meta1.max_attempts == 2

      # Attempt 2: success, callback stop span
      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _, meta2}
      assert meta2.attempt == 2
      assert meta2.max_attempts == 2
      assert {:ok, _} = meta2.result

      # Outer span: normal stop, no exception
      assert_receive {:telemetry, [:modboss, :read, :stop], measurements, stop_meta}
      assert measurements.total_attempts == 2
      assert {:ok, _} = stop_meta.result
      refute_receive {:telemetry, [:modboss, :read, :exception], _, _}
    end

    test "rescued read_func raise emits callback exception and outer stop with error", %{
      device: _device
    } do
      boom_func = fn _type, _addr, _count ->
        raise "boom!"
      end

      {:error, %RuntimeError{message: "boom!"}} = ModBoss.read(TestSchema, boom_func, :foo)

      # Callback-level: exception event with full metadata
      assert_receive {:telemetry, [:modboss, :read_callback, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.schema == TestSchema
      assert start_metadata.names == [:foo]
      assert start_metadata.object_type == :holding_register
      assert start_metadata.starting_address == 1
      assert start_metadata.address_count == 1
      assert start_metadata.attempt == 1
      assert start_metadata.max_attempts == 1

      assert_receive {:telemetry, [:modboss, :read_callback, :exception], cb_measurements,
                      cb_metadata}

      assert is_integer(cb_measurements.duration)
      assert cb_metadata.schema == TestSchema
      assert cb_metadata.names == [:foo]
      assert cb_metadata.object_type == :holding_register
      assert cb_metadata.starting_address == 1
      assert cb_metadata.address_count == 1
      assert cb_metadata.attempt == 1
      assert cb_metadata.max_attempts == 1
      assert cb_metadata.kind == :error
      assert %RuntimeError{message: "boom!"} = cb_metadata.reason
      assert is_list(cb_metadata.stacktrace)

      # Outer span: normal stop (not exception) with error result
      assert_receive {:telemetry, [:modboss, :read, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.modbus_requests == 1
      assert measurements.total_attempts == 1
      assert measurements.objects_requested == 1
      assert measurements.addresses_read == 1
      assert measurements.gap_addresses_read == 0
      assert measurements.max_gap_size == 0
      assert metadata.schema == TestSchema
      assert metadata.names == [:foo]
      assert {:error, %RuntimeError{message: "boom!"}} = metadata.result

      refute_receive {:telemetry, [:modboss, :read, :exception], _, _}
    end

    test "does not emit events for validation errors (e.g. unknown names)", %{device: device} do
      {:error, _} = ModBoss.read(TestSchema, read_func(device), :nonexistent)

      refute_receive {:telemetry, [:modboss, :read, :start], _, _}
      refute_receive {:telemetry, [:modboss, :read_callback, :start], _, _}
    end

    test "includes label in all event metadata when telemetry_label is provided", %{
      device: device
    } do
      set_objects(device, %{{:holding_register, 1} => 42})

      {:ok, 42} = ModBoss.read(TestSchema, read_func(device), :foo, telemetry_label: :foo_label)

      assert_receive {:telemetry, [:modboss, :read, :start], _, start_metadata}
      assert start_metadata.label == :foo_label

      assert_receive {:telemetry, [:modboss, :read, :stop], _, stop_metadata}
      assert stop_metadata.label == :foo_label

      assert_receive {:telemetry, [:modboss, :read_callback, :start], _, cb_start_metadata}
      assert cb_start_metadata.label == :foo_label

      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _, cb_stop_metadata}
      assert cb_stop_metadata.label == :foo_label
    end

    test "includes label in exception metadata when telemetry_label is provided" do
      boom_func = fn _type, _addr, _count -> raise "boom!" end

      {:error, %RuntimeError{}} =
        ModBoss.read(TestSchema, boom_func, :foo, telemetry_label: :my_device)

      assert_receive {:telemetry, [:modboss, :read, :stop], _, meta}
      assert meta.label == :my_device

      assert_receive {:telemetry, [:modboss, :read_callback, :exception], _, cb_meta}
      assert cb_meta.label == :my_device
    end

    test "does not include label key in metadata when telemetry_label is not provided", %{
      device: device
    } do
      set_objects(device, %{{:holding_register, 1} => 42})

      {:ok, 42} = ModBoss.read(TestSchema, read_func(device), :foo)

      assert_receive {:telemetry, [:modboss, :read, :start], _, metadata}
      refute Map.has_key?(metadata, :label)

      assert_receive {:telemetry, [:modboss, :read, :stop], _, stop_metadata}
      refute Map.has_key?(stop_metadata, :label)

      assert_receive {:telemetry, [:modboss, :read_callback, :start], _, cb_metadata}
      refute Map.has_key?(cb_metadata, :label)

      assert_receive {:telemetry, [:modboss, :read_callback, :stop], _, cb_stop_metadata}
      refute Map.has_key?(cb_stop_metadata, :label)
    end
  end

  describe "write/3 telemetry" do
    setup do
      attach_many([
        [:modboss, :write, :start],
        [:modboss, :write, :stop],
        [:modboss, :write_callback, :start],
        [:modboss, :write_callback, :stop],
        [:modboss, :write_callback, :exception]
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
      assert stop_measurements.total_attempts == 1
      assert stop_metadata.schema == TestSchema
      assert stop_metadata.names == [:baz]
      assert stop_metadata.result == :ok
    end

    test "emits :write_callback start and stop spans for each write callback", %{device: device} do
      :ok = ModBoss.write(TestSchema, write_func(device), baz: 99)

      # Per-request start
      assert_receive {:telemetry, [:modboss, :write_callback, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.schema == TestSchema
      assert start_metadata.names == [:baz]
      assert start_metadata.object_type == :holding_register
      assert start_metadata.starting_address == 3
      assert start_metadata.address_count == 1

      # Per-request stop
      assert_receive {:telemetry, [:modboss, :write_callback, :stop], stop_measurements,
                      stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.schema == TestSchema
      assert stop_metadata.names == [:baz]
      assert stop_metadata.object_type == :holding_register
      assert stop_metadata.starting_address == 3
      assert stop_metadata.address_count == 1
      assert stop_metadata.attempt == 1
      assert stop_metadata.result == :ok
    end

    test "emits aggregated data for the :write event", %{device: device} do
      :ok = ModBoss.write(TestSchema, write_func(device), baz: 1, blah: 1, grault: 1)

      # Callback requests
      assert_receive {:telemetry, [:modboss, :write_callback, :stop], _, meta1}
      assert_receive {:telemetry, [:modboss, :write_callback, :stop], _, meta2}

      assert meta1.attempt == 1
      assert meta2.attempt == 1

      # Batched writes
      assert_receive {:telemetry, [:modboss, :write, :stop], write_measurements, _}
      assert write_measurements.modbus_requests == 2
      assert write_measurements.objects_requested == 3
      assert write_measurements.total_attempts == 2

      types = Enum.sort([meta1.object_type, meta2.object_type])
      assert types == [:coil, :holding_register]

      # baz(3) + blah(4) are batched into one callback spanning 2 addresses
      hr_meta = Enum.find([meta1, meta2], &(&1.object_type == :holding_register))
      assert hr_meta.address_count == 2
      assert hr_meta.names == [:baz, :blah]

      coil_meta = Enum.find([meta1, meta2], &(&1.object_type == :coil))
      assert coil_meta.names == [:grault]
    end

    test "emits correct counts for multi-address writes", %{device: device} do
      :ok = ModBoss.write(TestSchema, write_func(device), qux: [1, 2, 3])

      assert_receive {:telemetry, [:modboss, :write, :stop], write_measurements, _}
      assert write_measurements.objects_requested == 3
      assert write_measurements.modbus_requests == 1
      assert write_measurements.total_attempts == 1

      assert_receive {:telemetry, [:modboss, :write_callback, :stop], _req_measurements, req_meta}
      assert req_meta.address_count == 3
      assert req_meta.attempt == 1
    end

    test "emits stop with error result when write_func returns an error", %{device: _device} do
      failing_write_func = fn _type, _addr, _values ->
        {:error, "device busy"}
      end

      {:error, "device busy"} = ModBoss.write(TestSchema, failing_write_func, baz: 1)

      assert_receive {:telemetry, [:modboss, :write, :start], _, _}

      assert_receive {:telemetry, [:modboss, :write, :stop], stop_measurements, write_metadata}
      assert write_metadata.result == {:error, "device busy"}
      assert stop_measurements.modbus_requests == 1
      assert stop_measurements.objects_requested == 1
      assert stop_measurements.total_attempts == 1

      assert_receive {:telemetry, [:modboss, :write_callback, :start], _, _}
      assert_receive {:telemetry, [:modboss, :write_callback, :stop], _, req_metadata}
      assert req_metadata.attempt == 1
      assert req_metadata.result == {:error, "device busy"}
    end

    test "reports attempted stats on partial write failure", %{device: device} do
      # max_batch_writes: 1 forces each register into its own callback.
      # 3 callbacks planned, succeed on the 1st, fail on the 2nd — the 3rd is skipped.
      schema = unique_module()

      Code.compile_string("""
      defmodule #{schema} do
        use ModBoss.Schema, max_batch_writes: [holding_registers: 1]

        schema do
          holding_register 1, :first, mode: :w
          holding_register 2, :second, mode: :w
          holding_register 3, :third, mode: :w
        end
      end
      """)

      failing_on_second = fn type, starting_address, values ->
        writes = Agent.get(device, & &1.writes)

        if writes > 0 do
          {:error, "timeout"}
        else
          write_func(device).(type, starting_address, values)
        end
      end

      {:error, "timeout"} =
        ModBoss.write(schema, failing_on_second, first: 1, second: 2, third: 3)

      assert_receive {:telemetry, [:modboss, :write, :stop], measurements, metadata}
      assert metadata.result == {:error, "timeout"}

      # 3 planned, but only 2 attempted (1 succeeded + 1 failed)
      assert measurements.modbus_requests == 2
      assert measurements.objects_requested == 2
      assert measurements.total_attempts == 2
    end

    test "retries emit per-attempt callback spans and total_attempts", %{device: device} do
      flaky_write = flakify(write_func(device), fn -> {:error, "flaky"} end, flakes: 1)

      :ok = ModBoss.write(TestSchema, flaky_write, [baz: 99], max_attempts: 3)

      assert_receive {:telemetry, [:modboss, :write_callback, :stop], _, attempt1}
      assert attempt1.attempt == 1
      assert attempt1.max_attempts == 3
      assert attempt1.result == {:error, "flaky"}

      assert_receive {:telemetry, [:modboss, :write_callback, :stop], _, attempt2}
      assert attempt2.attempt == 2
      assert attempt2.max_attempts == 3
      assert attempt2.result == :ok

      assert_receive {:telemetry, [:modboss, :write, :stop], measurements, _}
      assert measurements.total_attempts == 2
    end

    test "rescued write_func raise emits callback exception and outer stop with error", %{
      device: _device
    } do
      kaboom_func = fn _type, _addr, _values ->
        raise "kaboom!"
      end

      {:error, %RuntimeError{message: "kaboom!"}} =
        ModBoss.write(TestSchema, kaboom_func, baz: 1)

      # Callback-level: exception event with full metadata
      assert_receive {:telemetry, [:modboss, :write_callback, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.schema == TestSchema
      assert start_metadata.names == [:baz]
      assert start_metadata.object_type == :holding_register
      assert start_metadata.starting_address == 3
      assert start_metadata.address_count == 1
      assert start_metadata.attempt == 1
      assert start_metadata.max_attempts == 1

      assert_receive {:telemetry, [:modboss, :write_callback, :exception], cb_measurements,
                      cb_metadata}

      assert is_integer(cb_measurements.duration)
      assert cb_metadata.schema == TestSchema
      assert cb_metadata.names == [:baz]
      assert cb_metadata.object_type == :holding_register
      assert cb_metadata.starting_address == 3
      assert cb_metadata.address_count == 1
      assert cb_metadata.attempt == 1
      assert cb_metadata.max_attempts == 1
      assert cb_metadata.kind == :error
      assert %RuntimeError{message: "kaboom!"} = cb_metadata.reason
      assert is_list(cb_metadata.stacktrace)

      # Outer span: normal stop (not exception) with error result
      assert_receive {:telemetry, [:modboss, :write, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.modbus_requests == 1
      assert measurements.total_attempts == 1
      assert measurements.objects_requested == 1
      assert metadata.schema == TestSchema
      assert metadata.names == [:baz]
      assert {:error, %RuntimeError{message: "kaboom!"}} = metadata.result

      refute_receive {:telemetry, [:modboss, :write, :exception], _, _}
    end

    test "does not emit events for validation errors (e.g. unknown names)", %{device: device} do
      {:error, _} = ModBoss.write(TestSchema, write_func(device), nonexistent: 1)

      refute_receive {:telemetry, [:modboss, :write, :start], _, _}
      refute_receive {:telemetry, [:modboss, :write_callback, :start], _, _}
    end

    test "includes label in all event metadata when telemetry_label is provided", %{
      device: device
    } do
      :ok =
        ModBoss.write(TestSchema, write_func(device), [baz: 99],
          telemetry_label: %{port: :rs485, address: 12}
        )

      assert_receive {:telemetry, [:modboss, :write, :start], _, start_metadata}
      assert start_metadata.label == %{port: :rs485, address: 12}

      assert_receive {:telemetry, [:modboss, :write, :stop], _, stop_metadata}
      assert stop_metadata.label == %{port: :rs485, address: 12}

      assert_receive {:telemetry, [:modboss, :write_callback, :start], _, cb_start_metadata}
      assert cb_start_metadata.label == %{port: :rs485, address: 12}

      assert_receive {:telemetry, [:modboss, :write_callback, :stop], _, cb_stop_metadata}
      assert cb_stop_metadata.label == %{port: :rs485, address: 12}
    end

    test "retries through exceptions and succeeds", %{device: device} do
      raising_write = flakify(write_func(device), fn -> raise "raised!" end, flakes: 1)

      :ok = ModBoss.write(TestSchema, raising_write, [baz: 99], max_attempts: 2)

      # Attempt 1: raise, callback exception span
      assert_receive {:telemetry, [:modboss, :write_callback, :exception], _, meta1}
      assert meta1.attempt == 1
      assert meta1.max_attempts == 2

      # Attempt 2: success, callback stop span
      assert_receive {:telemetry, [:modboss, :write_callback, :stop], _, meta2}
      assert meta2.attempt == 2
      assert meta2.max_attempts == 2
      assert meta2.result == :ok

      # Outer span: normal stop, no exception
      assert_receive {:telemetry, [:modboss, :write, :stop], measurements, stop_meta}
      assert measurements.total_attempts == 2
      assert stop_meta.result == :ok
      refute_receive {:telemetry, [:modboss, :write, :exception], _, _}
    end

    test "includes label in exception metadata when telemetry_label is provided" do
      kaboom_func = fn _type, _addr, _values -> raise "kaboom!" end

      {:error, %RuntimeError{}} =
        ModBoss.write(TestSchema, kaboom_func, [baz: 1], telemetry_label: :my_device)

      assert_receive {:telemetry, [:modboss, :write, :stop], _, meta}
      assert meta.label == :my_device

      assert_receive {:telemetry, [:modboss, :write_callback, :exception], _, cb_meta}
      assert cb_meta.label == :my_device
    end

    test "does not include label key in metadata when telemetry_label is not provided", %{
      device: device
    } do
      :ok = ModBoss.write(TestSchema, write_func(device), baz: 99)

      assert_receive {:telemetry, [:modboss, :write, :start], _, metadata}
      refute Map.has_key?(metadata, :label)

      assert_receive {:telemetry, [:modboss, :write, :stop], _, stop_metadata}
      refute Map.has_key?(stop_metadata, :label)

      assert_receive {:telemetry, [:modboss, :write_callback, :start], _, cb_metadata}
      refute Map.has_key?(cb_metadata, :label)

      assert_receive {:telemetry, [:modboss, :write_callback, :stop], _, cb_stop_metadata}
      refute Map.has_key?(cb_stop_metadata, :label)
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

  defp unique_module do
    name = "#{__MODULE__}#{System.unique_integer([:positive])}"
    Module.concat([name])
  end
end
