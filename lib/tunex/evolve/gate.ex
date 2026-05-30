defmodule Tunex.Evolve.Gate do
  @moduledoc """
  The trust boundary. Runs only on a **dirty** clone tree (the agent edited
  files). Stages everything (`git add -A`) and enforces a hard 5-part contract
  on the staged diff, **cheap-first / fail-fast** (plan #6):

    (b) diff touches `lib/`      — a rule/infra file changed
    (c) diff touches `test/`     — a regression test added/modified
    (e) scope                    — diff touches ONLY `lib/` and `test/`
        pure-deletion guard      — reject if every `lib/` change is a deletion
    (d) mutation                 — revert `lib/` to HEAD, run the changed test
                                   file(s), assert RED (incl. compile-error =
                                   RED), then restore
    (a) full `mix test` green    — last; the slow one

  Renames / supersession-with-replacement (delete+add) pass: the *add* side
  touches `lib/` + `test/` and the mutation check runs on the new test.
  **Standalone pure deletion is rejected + escalated** — removing a rule is a
  human-only decision.

  Returns `{:ok, summary}` (caller commits) or `{:reject, reason}` (Gate has
  already discarded the working tree via `reset --hard HEAD` + `clean -fd`).
  """

  require Logger

  alias Tunex.Config

  @doc "Run the contract against the (already-dirty) clone. `clone` defaults to config."
  def check(clone \\ Config.credence_clone()) do
    git(clone, ["add", "-A"])
    entries = staged_entries(clone)
    Logger.info("[Gate] staged entries: #{inspect(Enum.map(entries, &{&1.status, &1.paths}))}")

    with :ok <- check_touches(entries, "lib/", :no_lib_change),
         :ok <- check_touches(entries, "test/", :no_test_change),
         :ok <- check_scope(entries),
         :ok <- check_not_pure_deletion(entries),
         :ok <- check_mutation(clone, entries),
         :ok <- check_full_suite(clone) do
      {:ok, summarize(entries)}
    else
      {:reject, reason} ->
        Logger.warning("[Gate] REJECT: #{inspect(reason)} — discarding")
        discard(clone)
        {:reject, reason}
    end
  end

  @doc "Discard all working-tree + staged changes in the clone."
  def discard(clone \\ Config.credence_clone()) do
    git(clone, ["reset", "--hard", "HEAD"])
    git(clone, ["clean", "-fd"])
    :ok
  end

  # ── (b)/(c) touches ─────────────────────────────────────────────────

  defp check_touches(entries, prefix, reason) do
    if Enum.any?(entries, fn e -> Enum.any?(e.paths, &under?(&1, prefix)) end),
      do: :ok,
      else: {:reject, reason}
  end

  # ── (e) scope: only lib/ and test/ ──────────────────────────────────

  defp check_scope(entries) do
    offending =
      entries
      |> Enum.flat_map(& &1.paths)
      |> Enum.reject(&(under?(&1, "lib/") or under?(&1, "test/")))

    if offending == [], do: :ok, else: {:reject, {:scope, offending}}
  end

  # ── pure-deletion guard ─────────────────────────────────────────────

  defp check_not_pure_deletion(entries) do
    lib_entries = Enum.filter(entries, fn e -> Enum.any?(e.paths, &under?(&1, "lib/")) end)

    if lib_entries != [] and Enum.all?(lib_entries, &(&1.status == "D")) do
      {:reject, {:pure_deletion, Enum.flat_map(lib_entries, & &1.paths)}}
    else
      :ok
    end
  end

  # ── (d) mutation check ──────────────────────────────────────────────

  defp check_mutation(clone, entries) do
    lib_files = added_or_modified(entries, "lib/")
    test_files = added_or_modified(entries, "test/")

    cond do
      test_files == [] ->
        {:reject, :no_changed_test_to_mutate}

      true ->
        snapshot = snapshot_lib(clone, lib_files)
        revert_lib_to_head(clone, snapshot)
        exit_code = run_tests(clone, test_files)
        restore_lib(snapshot)
        git(clone, ["add", "-A"])

        if exit_code != 0 do
          Logger.info("[Gate] mutation OK — changed test(s) RED without the rule (exit #{exit_code})")
          :ok
        else
          {:reject, {:mutation_no_effect, test_files}}
        end
    end
  end

  defp snapshot_lib(clone, lib_files) do
    Enum.map(lib_files, fn rel ->
      abs = Path.join(clone, rel)
      content = if File.exists?(abs), do: File.read!(abs), else: nil
      in_head? = tracked_in_head?(clone, rel)
      %{rel: rel, abs: abs, content: content, in_head?: in_head?}
    end)
  end

  defp revert_lib_to_head(clone, snapshot) do
    Enum.each(snapshot, fn f ->
      if f.in_head? do
        git(clone, ["checkout", "HEAD", "--", f.rel])
      else
        File.rm(f.abs)
      end
    end)
  end

  defp restore_lib(snapshot) do
    Enum.each(snapshot, fn f ->
      if f.content, do: File.write!(f.abs, f.content)
    end)
  end

  # ── (a) full suite ──────────────────────────────────────────────────

  defp check_full_suite(clone) do
    if run_tests(clone, []) == 0 do
      Logger.info("[Gate] full suite GREEN")
      :ok
    else
      {:reject, :full_suite_red}
    end
  end

  # ── Git / test helpers ──────────────────────────────────────────────

  defp run_tests(clone, files) do
    {out, code} =
      System.cmd("mix", ["test" | files],
        cd: clone,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    Logger.debug("[Gate] mix test #{inspect(files)} exit=#{code}\n#{String.slice(out, 0, 2000)}")
    code
  end

  defp tracked_in_head?(clone, rel) do
    {_out, code} = git(clone, ["cat-file", "-e", "HEAD:" <> rel])
    code == 0
  end

  defp staged_entries(clone) do
    {out, _} = git(clone, ["diff", "--cached", "--name-status", "-z"])
    parse_name_status_z(out)
  end

  # `-z` output: records are NUL-separated; a rename/copy record is
  # status\0old\0new, others are status\0path.
  defp parse_name_status_z(out) do
    out
    |> String.split("\0", trim: true)
    |> consume([])
    |> Enum.reverse()
  end

  defp consume([], acc), do: acc

  defp consume([status | rest], acc) do
    letter = String.first(status)

    if letter in ["R", "C"] do
      [old, new | rest2] = rest
      consume(rest2, [%{status: letter, paths: [old, new]} | acc])
    else
      [path | rest2] = rest
      consume(rest2, [%{status: letter, paths: [path]} | acc])
    end
  end

  # Added/modified/renamed-new files under prefix that exist on disk (the
  # agent's version), as repo-relative paths.
  defp added_or_modified(entries, prefix) do
    Enum.flat_map(entries, fn e ->
      case e.status do
        s when s in ["A", "M"] -> Enum.filter(e.paths, &under?(&1, prefix))
        s when s in ["R", "C"] -> e.paths |> Enum.take(-1) |> Enum.filter(&under?(&1, prefix))
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp summarize(entries) do
    removes =
      Enum.flat_map(entries, fn
        %{status: "D", paths: [p]} -> if under?(p, "lib/"), do: [p], else: []
        %{status: "R", paths: [old, _new]} -> if under?(old, "lib/"), do: [old], else: []
        _ -> []
      end)

    %{entries: entries, removes: removes}
  end

  defp under?(path, prefix), do: String.starts_with?(path, prefix)

  defp git(clone, args) do
    System.cmd("git", args, cd: clone, stderr_to_stdout: true)
  end
end
