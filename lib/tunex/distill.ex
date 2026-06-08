defmodule Tunex.Distill do
  @moduledoc """
  Coarse-cut distillation of a row log for the classifier (07 §7, 08 T2.2).

  The classifier reads the log ONCE, so the old "shave the re-sent prefix"
  justification is gone; the remaining value is **accuracy** (the reference
  Elixir solution anchors a one-shot judge into "already fine") + a smaller
  single-call input.

  `distill/1` drops everything **above** the `===SOLVE_BOUNDARY===` sentinel
  (Python source / translate / round-trip / reference solution — all of which
  live above it) and keeps everything below: the Qwen solve attempts + every
  `[Validator.run]` / `[credence_fix]` / `APPLIED_RULES` fix trace.

  The sentinel is emitted unconditionally on every row immediately before solve
  (T2.1), and only post-solve rows reach the classifier, so its presence is an
  invariant. We still degrade gracefully (return the whole log) if it is absent,
  rather than crash.
  """

  @boundary "===SOLVE_BOUNDARY==="

  @spec distill(String.t()) :: String.t()
  def distill(log) when is_binary(log) do
    case String.split(log, @boundary) do
      [_only] -> log
      parts -> parts |> List.last() |> String.trim_leading()
    end
  end
end
