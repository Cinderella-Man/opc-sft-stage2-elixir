defmodule Tunex.Evolve.Corpus do
  @moduledoc """
  Deterministic (token-free) reader for Credence's real-world over-firing corpus
  (see `../credence/docs/09-corpus-over-firing-tests.md`).

  The corpus over-firing layer runs inside the clone's default `mix test` as a
  per-finding **snapshot ratchet**: `test/corpus/accepted_findings.txt` pins every
  accepted finding as `"<path>:<line>  <rule>"`, and the test goes RED when the
  live finding set drifts — a **NEW** line (a rule started firing on idiomatic
  real code = an over-fire) or a **GONE** line (a rule narrowed / was removed).

  The Gate already runs that full suite for free, so when it rejects we use this
  module to classify *why* deterministically — no model call:

    * `classify_failure/1` — is the full-suite failure **corpus-only**, and if so
      is it a NEW-finding over-fire (a bad rule → drop) or a GONE-finding
      narrowing (a legit fix → accept + re-pin the snapshot)?

  This never mutates committed state: `delta/1` regenerates the snapshot via
  `mix credence.corpus --update-snapshot`, reads it, then restores the original.
  """

  require Logger

  alias Tunex.{Config, RowLog}

  @snapshot "test/corpus/accepted_findings.txt"

  @doc """
  Classify a *failing* full suite. Returns `nil` when the failure is NOT
  corpus-only (some ordinary test is red — a genuinely broken rule), otherwise
  `%{kind: :over_fire | :narrowing | :unknown, new: [line], gone: [line]}`.
  """
  def classify_failure(clone \\ Config.credence_clone()) do
    if non_corpus_green?(clone) do
      %{new: new, gone: gone} = delta(clone)

      kind =
        cond do
          new != [] -> :over_fire
          gone != [] -> :narrowing
          true -> :unknown
        end

      %{kind: kind, new: new, gone: gone}
    else
      nil
    end
  end

  @doc """
  Snapshot delta: regenerate the accepted-findings snapshot from the clone's
  CURRENT rules and diff it against the on-disk (committed) snapshot, then
  restore the original file. `new` = findings the rules now emit but weren't
  pinned (over-fire); `gone` = pinned findings the rules no longer emit
  (narrowing). Pure-ish: leaves the snapshot file exactly as it found it.
  """
  def delta(clone \\ Config.credence_clone()) do
    path = Path.join(clone, @snapshot)
    before = File.read!(path)

    {_out, _code} =
      System.cmd("mix", ["credence.corpus", "--update-snapshot"],
        cd: clone,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    live = File.read!(path)
    File.write!(path, before)

    diff(findings(before), findings(live))
  end

  @doc "Pure diff of two finding-line lists into `%{new: ..., gone: ...}`."
  def diff(before_lines, live_lines) do
    %{new: live_lines -- before_lines, gone: before_lines -- live_lines}
  end

  @doc "Parse a snapshot file body into its finding lines (drop blanks + `#` comments)."
  def findings(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @doc """
  For a corpus over-fire/narrowing Gate reject, write the agent's `<index>.patch`
  + a maintainer-facing `<index>.corpus.md` (drop-or-accept instructions) into
  `escalated/`, and return a COMPACT reason (the big patch/finding bodies stripped
  from the term so the ledger + outcome stay small). Non-corpus rejects pass
  through unchanged.
  """
  def persist_reject(index, {:corpus, kind, %{new: new, gone: gone, patch: patch}}) do
    dir = RowLog.outcome_path("escalated")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{index}.patch"), patch)
    File.write!(Path.join(dir, "#{index}.corpus.md"), report(index, kind, new, gone))
    {:corpus, kind, %{new: length(new), gone: length(gone)}}
  end

  def persist_reject(_index, reason), do: reason

  defp report(index, kind, new, gone) do
    """
    # Corpus over-firing reject — row #{index}

    Kind: **#{kind}** (#{length(new)} NEW, #{length(gone)} GONE)

    The rule the agent produced changed Credence's findings on the real-world
    over-firing corpus, so the full `mix test` went red and the Gate rejected it.
    The agent's full diff is preserved alongside this file as `#{index}.patch`.

    ## NEW — rule now fires on idiomatic real code (likely an OVER-FIRE → DROP)
    #{bullet(new)}

    ## GONE — rule no longer fires here (a NARROWING → ACCEPT means re-pinning)
    #{bullet(gone)}

    ## To DROP
    Do nothing — the tree was already reset to HEAD.

    ## To ACCEPT + whitelist
        cd #{Config.credence_clone()}
        git apply #{Path.expand(Path.join(RowLog.outcome_path("escalated"), "#{index}.patch"))}
        mix credence.corpus --update-snapshot   # re-pin the accepted findings
        mix test                                # confirm green
    """
  end

  defp bullet([]), do: "_(none)_"
  defp bullet(lines), do: Enum.map_join(lines, "\n", &"- `#{&1}`")

  # Everything except the :corpus layer is green ⇒ the full-suite failure is
  # corpus-only (a snapshot drift), not an ordinary broken-rule test.
  defp non_corpus_green?(clone) do
    {_out, code} =
      System.cmd("mix", ["test", "--exclude", "corpus"],
        cd: clone,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    code == 0
  end
end
