defmodule TunexTest do
  use ExUnit.Case
  doctest Tunex

  test "greets the world" do
    assert Tunex.hello() == :world
  end
end
