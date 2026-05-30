defmodule Tunex.BudgetTest do
  use ExUnit.Case, async: true
  alias Tunex.Budget

  setup do
    test_pid = self()
    on_runaway = fn reason -> send(test_pid, {:runaway, reason}) end
    {:ok, pid} = start_supervised({Budget, [name: nil, on_runaway: on_runaway]})
    %{budget: pid}
  end

  test "accumulates chat usage as cost", %{budget: b} do
    # 1_000_000 in @ $1/M + 1_000_000 out @ $3/M = $4.00
    Budget.record(%{"prompt_tokens" => 1_000_000, "completion_tokens" => 1_000_000}, :chat, b)
    # cast is async; a sync call flushes the mailbox
    assert_in_delta Budget.spent(b), 4.0, 0.0001
  end

  test "accumulates cc usage incl cache fields", %{budget: b} do
    Budget.record(
      %{
        "input_tokens" => 1_000_000,
        "output_tokens" => 0,
        "cache_read_input_tokens" => 1_000_000,
        "cache_creation_input_tokens" => 0
      },
      :cc,
      b
    )

    # 1M input @ $1/M + 1M cache_read @ $0.3/M = $1.30
    assert_in_delta Budget.spent(b), 1.30, 0.0001
  end

  test "runaway ceiling triggers on_runaway", %{budget: b} do
    # default ceiling 500.0; 200M out @ $3/M = $600 > ceiling
    Budget.record(%{"prompt_tokens" => 0, "completion_tokens" => 200_000_000}, :chat, b)
    assert_receive {:runaway, {:runaway_budget, spent}}
    assert spent > 500.0
  end

  describe "classify_error/2" do
    test "auth errors are fatal", %{budget: b} do
      assert Budget.classify_error({:http, 401, "x"}, b) == :fatal
      assert Budget.classify_error({:http, 403, "x"}, b) == :fatal
    end

    test "5xx and network are transient", %{budget: b} do
      assert Budget.classify_error({:http, 503, "x"}, b) == :transient
      assert Budget.classify_error({:network, :timeout}, b) == :transient
    end

    test "429 becomes fatal after the streak", %{budget: b} do
      for _ <- 1..4, do: assert(Budget.classify_error({:http, 429, "x"}, b) == :transient)
      assert Budget.classify_error({:http, 429, "x"}, b) == :fatal
    end

    test "note_success resets the 429 streak", %{budget: b} do
      for _ <- 1..4, do: Budget.classify_error({:http, 429, "x"}, b)
      Budget.note_success(b)
      # streak reset; next 429 is transient again
      assert Budget.classify_error({:http, 429, "x"}, b) == :transient
    end
  end
end
