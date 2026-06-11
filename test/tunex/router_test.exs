defmodule Tunex.Evolve.RouterTest do
  use ExUnit.Case, async: false

  alias Tunex.Evolve.Router
  alias Tunex.Classify.Spec

  setup do
    # Isolate var/run to a temp dir so the router's outcome-dir moves don't
    # touch the real run dir.
    prev = Application.get_env(:tunex, :run_dir)
    tmp = Path.join(System.tmp_dir!(), "tunex_router_#{System.unique_integer([:positive])}")
    Application.put_env(:tunex, :run_dir, tmp)
    Tunex.RowLog.ensure_ready()
    on_exit(fn ->
      if prev, do: Application.put_env(:tunex, :run_dir, prev), else: Application.delete_env(:tunex, :run_dir)
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  defp write_log(idx, body) do
    path = Path.join([Tunex.Config.run_path("logs"), "#{idx}.log"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp moved?(dir, idx), do: File.exists?(Path.join(Tunex.Config.run_path(dir), "#{idx}.log"))

  test "NO_ACTION moves the log to no_action/", %{tmp: _tmp} do
    write_log(1, "no rules fired\n")
    classify = fn _log, _outcome, _opts -> {:ok, %Spec{decision: :no_action}} end

    assert %{outcome: :no_action} = Router.run(1, :solved, "/nonexistent_clone", classify: classify)
    assert moved?("no_action", 1)
  end

  test "SWITCH_PROPOSAL records + moves to switch_proposals/" do
    write_log(2, "log\n")

    spec = %Spec{
      decision: :switch_proposal,
      before: "defmodule B do\nend",
      proposed_switch: %{"name" => "nfc_strings", "summary" => "all NFC", :raw => "..."},
      rationale: "rare-text"
    }

    classify = fn _l, _o, _opts -> {:ok, spec} end

    assert %{outcome: :switch_proposal} = Router.run(2, :failed, "/x", classify: classify)
    assert moved?("switch_proposals", 2)
    # the proposal record file exists too
    assert File.exists?(Path.join(Tunex.Config.run_path("switch_proposals"), "2.json"))
  end

  test "classifier error moves to classifier_errors/" do
    write_log(3, "log\n")
    classify = fn _l, _o, _opts -> {:error, {:classifier_errors, :missing_after, "raw"}} end

    assert %{outcome: :classifier_error} = Router.run(3, :solved, "/x", classify: classify)
    assert moved?("classifier_errors", 3)
  end

  test "POTENTIAL_NEW_RULE that is COVERED no longer skips — builds anyway (docs/10 A)" do
    write_log(4, "log\n")
    spec = %Spec{decision: :potential_new_rule, phase: :pattern, proposed_name: "no_foo", before: "defmodule B do\nend", after: "defmodule A do\nend"}
    classify = fn _l, _o, _opts -> {:ok, spec} end
    novelty = fn _before, _clone -> :covered end
    # :covered is now a non-blocking note — the row proceeds to equiv (here
    # DIVERGES), it does NOT skip to duplicate/.
    equiv = fn _spec -> {:diverges, "x"} end

    assert %{outcome: :behaviour_diverged} =
             Router.run(4, :solved, "/x", classify: classify, novelty: novelty, equiv: equiv)

    refute moved?("duplicate", 4)
    assert moved?("behaviour_diverged", 4)
  end

  test "POTENTIAL_NEW_RULE NOVEL but equiv DIVERGES moves to behaviour_diverged/" do
    write_log(5, "log\n")
    spec = %Spec{decision: :potential_new_rule, phase: :pattern, proposed_name: "no_foo", before: "defmodule B do\nend", after: "defmodule A do\nend"}
    classify = fn _l, _o, _opts -> {:ok, spec} end
    novelty = fn _b, _c -> :novel end
    equiv = fn _spec -> {:diverges, "int vs string"} end

    assert %{outcome: :behaviour_diverged} =
             Router.run(5, :solved, "/x", classify: classify, novelty: novelty, equiv: equiv)

    assert moved?("behaviour_diverged", 5)
  end

  # ── docs/10 Fix 1: transient timeout don't-consume / too_slow / fatal ───────

  test "a transient classify timeout (under the per-row limit) → :transient_abort, moves to transient/, no Ledger" do
    write_log(10, "log\n")
    classify = fn _l, _o, _opts -> {:error, {:classifier_errors, {:llm_error, {:network, :timeout}}, ""}} end

    assert %{outcome: :transient_abort} =
             Router.run(10, :solved, "/x", classify: classify, transient_attempts: fn _ -> 1 end)

    assert moved?("transient", 10)
    refute moved?("classifier_errors", 10)
    # don't-consume must NOT poison the ledger with network spam
    refute File.exists?(Tunex.Config.run_path("decisions.md"))
  end

  test "a transient classify timeout AT the per-row limit → :too_slow, moves to too_slow/ (consumed)" do
    write_log(11, "log\n")
    classify = fn _l, _o, _opts -> {:error, {:classifier_errors, {:llm_error, {:network, :timeout}}, ""}} end

    limit = Tunex.Config.transient_row_limit()

    assert %{outcome: :too_slow} =
             Router.run(11, :solved, "/x", classify: classify, transient_attempts: fn _ -> limit end)

    assert moved?("too_slow", 11)
    refute moved?("transient", 11)
  end

  test "a fatal classify error (401) → injected shutdown, :fatal_abort" do
    write_log(12, "log\n")
    classify = fn _l, _o, _opts -> {:error, {:classifier_errors, {:llm_error, {:http, 401, "no"}}, ""}} end
    me = self()
    shutdown = fn reason -> send(me, {:shutdown, reason}) end

    assert %{outcome: :fatal_abort} =
             Router.run(12, :solved, "/x", classify: classify, shutdown: shutdown)

    assert_received {:shutdown, {:fatal_api, {:llm_error, {:http, 401, "no"}}}}
  end

  test "a genuine malformed-spec classifier error still → classifier_errors/ (:other)" do
    write_log(13, "log\n")
    classify = fn _l, _o, _opts -> {:error, {:classifier_errors, :missing_after, "raw"}} end

    assert %{outcome: :classifier_error} = Router.run(13, :solved, "/x", classify: classify)
    assert moved?("classifier_errors", 13)
  end
end
