defmodule Tunex.OrchestratorTest do
  use ExUnit.Case, async: true

  alias Tunex.Orchestrator

  # The full GenServer boots Preflight + the dataset, so only the pure breaker
  # decision is unit-tested here (docs/10 Fix 1). The don't-consume / move
  # wiring is covered in RouterTest.
  describe "breaker_step/3 — consecutive-:transient_abort circuit breaker" do
    test "transient_abort increments until the limit, then halts" do
      assert {:cont, 1} = Orchestrator.breaker_step(0, 5, :transient_abort)
      assert {:cont, 4} = Orchestrator.breaker_step(3, 5, :transient_abort)
      assert :halt = Orchestrator.breaker_step(4, 5, :transient_abort)
    end

    test "any real outcome resets the streak to 0" do
      assert {:cont, 0} = Orchestrator.breaker_step(4, 5, :committed)
      assert {:cont, 0} = Orchestrator.breaker_step(4, 5, :too_slow)
      assert {:cont, 0} = Orchestrator.breaker_step(4, 5, :duplicate)
    end

    test "a blacklisted row leaves the streak unchanged (no Mimo signal)" do
      assert {:cont, 3} = Orchestrator.breaker_step(3, 5, :blacklist)
    end
  end
end
