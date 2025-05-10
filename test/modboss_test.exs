defmodule ModBossTest do
  use ExUnit.Case
  doctest ModBoss

  test "greets the world" do
    assert ModBoss.hello() == :world
  end
end
