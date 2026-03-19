defmodule ModBoss.CallbackHelpers do
  @moduledoc false

  @doc """
  Wraps a callback so it invokes `flaky_func` for the first `flakes`
  invocations, then delegates to `actual_func`. The counter resets after
  each success, so each batch independently flakes `flakes` times before
  succeeding.

  The `flaky_func` is a zero-arity function that defines the failure
  behavior — return an error tuple, raise, etc.

  ## Examples

      # Return an error tuple
      flakify(read_func(device), fn -> {:error, "flaky"} end, flakes: 2)

      # Raise an exception
      flakify(read_func(device), fn -> raise "boom!" end, flakes: 1)
  """
  def flakify(actual_func, flaky_func, opts \\ []) do
    fail_count = Keyword.fetch!(opts, :flakes)
    counter = :counters.new(1, [:atomics])

    fn type, starting_address, value_or_count ->
      attempt = :counters.get(counter, 1) + 1
      :counters.add(counter, 1, 1)

      if attempt <= fail_count do
        flaky_func.()
      else
        :counters.put(counter, 1, 0)
        actual_func.(type, starting_address, value_or_count)
      end
    end
  end
end
