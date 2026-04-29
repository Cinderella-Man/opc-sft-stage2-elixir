#!/usr/bin/env elixir

# Revalidate existing JSONL output against the latest Credence rules.
#
# Reads every entry from the output file, runs the full validation pipeline
# (compile → format → credo → credence → test), and reports which entries
# now fail. Use after updating Credence rules to find entries that need
# regeneration.
#
# Modes:
#   --report     (default) Print failures and aggregate stats
#   --delete     Print failures AND remove them from the JSONL file
#
# Usage:
#   elixir revalidate.exs elixir_sft_educational_instruct.jsonl
#   elixir revalidate.exs elixir_sft_educational_instruct.jsonl --delete

Mix.install([
  {:jason, "~> 1.4"}
])

defmodule Revalidator do
  @workspace "revalidation_workspace"

  @credence_script """
  code = File.read!("lib/solution.ex")
  result = Credence.analyze(code)

  if result.valid do
    IO.puts("OK")
  else
    IO.puts("ISSUES: \#{length(result.issues)} credence issue(s) found")
    for issue <- result.issues do
      line = if issue.meta[:line], do: "line \#{issue.meta[:line]}", else: "unknown line"
      IO.puts("  [\#{issue.severity}] \#{issue.rule}: \#{issue.message} (\#{line})")
    end
    System.halt(1)
  end
  """

  defp log(indent, msg), do: IO.puts(String.duplicate("  ", indent) <> msg)

  # ── Workspace Setup ────────────────────────────────────────────────

  def setup_workspace do
    if File.exists?(Path.join(@workspace, "mix.exs")) do
      log(0, "Workspace #{@workspace}/ exists, checking deps...")
      ensure_credence_in_mix_exs()
      ensure_credence_script()
      ensure_deps()
    else
      log(0, "Creating Mix project: #{@workspace}/")
      {output, code} = System.cmd("mix", ["new", @workspace], stderr_to_stdout: true)
      if code != 0, do: raise("mix new failed: #{output}")

      mix_exs = Path.join(@workspace, "mix.exs")
      mix_content = File.read!(mix_exs)
      fixed = Regex.replace(
        ~r/defp deps do\n\s+\[.*?\]/s,
        mix_content,
        "defp deps do\n      [\n        {:credo, \"~> 1.7\", only: [:dev, :test], runtime: false},\n        {:credence, github: \"Cinderella-Man/credence\", only: [:dev, :test], runtime: false}\n      ]"
      )
      File.write!(mix_exs, fixed)

      File.write!(Path.join(@workspace, ".credo.exs"), """
      %{
        configs: [
          %{
            name: "default",
            checks: %{
              enabled: [
                {Credo.Check.Readability.ModuleDoc, false},
                {Credo.Check.Design.TagTODO, false}
              ]
            }
          }
        ]
      }
      """)

      ensure_credence_script()

      for f <- Path.wildcard(Path.join(@workspace, "lib/*.ex")), do: File.rm(f)
      for f <- Path.wildcard(Path.join(@workspace, "test/*_test.exs")), do: File.rm(f)

      ensure_deps()
      log(0, "✓ Workspace ready")
    end
  end

  defp ensure_credence_in_mix_exs do
    mix_exs = Path.join(@workspace, "mix.exs")
    content = File.read!(mix_exs)

    unless String.contains?(content, "credence") do
      fixed = String.replace(
        content,
        "{:credo, \"~> 1.7\", only: [:dev, :test], runtime: false}",
        "{:credo, \"~> 1.7\", only: [:dev, :test], runtime: false},\n        {:credence, github: \"Cinderella-Man/credence\", only: [:dev, :test], runtime: false}"
      )
      File.write!(mix_exs, fixed)
    end
  end

  defp ensure_credence_script do
    path = Path.join(@workspace, "run_credence.exs")
    unless File.exists?(path), do: File.write!(path, @credence_script)
  end

  defp ensure_deps do
    unless File.exists?(Path.join(@workspace, "deps/credence")) do
      log(1, "Fetching deps...")
      System.cmd("mix", ["deps.get"], cd: @workspace, stderr_to_stdout: true)
      System.cmd("mix", ["deps.compile"], cd: @workspace, stderr_to_stdout: true)
      log(1, "✓ Deps ready")
    else
      log(1, "✓ Deps already installed")
    end
  end

  # ── Force update credence ──────────────────────────────────────────

  def update_credence do
    log(0, "Updating credence to latest...")
    System.cmd("mix", ["deps.update", "credence"], cd: @workspace, stderr_to_stdout: true)
    System.cmd("mix", ["deps.compile", "credence", "--force"], cd: @workspace, stderr_to_stdout: true)
    log(0, "✓ Credence updated")
  end

  # ── Validation ─────────────────────────────────────────────────────

  def validate(module_code, test_code) do
    mod_path = Path.join(@workspace, "lib/solution.ex")
    test_path = Path.join(@workspace, "test/solution_test.exs")

    for f <- Path.wildcard(Path.join(@workspace, "lib/*.ex")), do: File.rm(f)
    for f <- Path.wildcard(Path.join(@workspace, "test/*_test.exs")), do: File.rm(f)

    File.write!(mod_path, module_code)
    File.write!(test_path, test_code)

    failures = []

    # Compile
    {output, code} = System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
      cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
    compiled = code == 0
    failures = if compiled, do: failures, else: failures ++ [{:compile, clean(output)}]

    # Format
    failures = if compiled do
      {_, code} = System.cmd("mix", ["format", "--check-formatted", "lib/solution.ex", "test/solution_test.exs"],
        cd: @workspace, stderr_to_stdout: true)
      if code == 0, do: failures, else: failures ++ [{:format, "not formatted"}]
    else
      failures
    end

    # Credo
    failures = if compiled do
      {output, _} = System.cmd("mix", ["credo", "list", "--strict", "--format", "oneline", "lib/solution.ex"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      issues = output |> String.split("\n") |> Enum.filter(&String.contains?(&1, "lib/solution.ex")) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      if issues == [], do: failures, else: failures ++ [{:credo, Enum.join(issues, "\n")}]
    else
      failures
    end

    # Credence
    failures = if compiled do
      {output, code} = System.cmd("mix", ["run", "--no-start", "run_credence.exs"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0, do: failures, else: failures ++ [{:credence, String.trim(output)}]
    else
      failures
    end

    # Tests
    failures = if compiled do
      {output, code} = System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0, do: failures, else: failures ++ [{:test, clean(output)}]
    else
      failures
    end

    failures
  end

  defp clean(output) do
    output
    |> String.replace(~r/Compiling \d+ file.*\n/, "")
    |> String.replace(~r/Generated .* app\n/, "")
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.trim()
  end

  defp format_failure_summary(failures) do
    failures
    |> Enum.map(fn {stage, msg} ->
      case stage do
        :credence ->
          rules =
            Regex.scan(~r/\[(?:warning|info|high)\] ([a-z_]+):/, msg)
            |> Enum.map(fn [_, rule] -> rule end)
            |> Enum.uniq()

          if rules != [] do
            "credence: #{Enum.join(rules, ", ")}"
          else
            "credence"
          end

        other ->
          to_string(other)
      end
    end)
    |> Enum.join(", ")
    |> then(&"(#{&1})")
  end

  # ── Main ───────────────────────────────────────────────────────────

  def run(jsonl_path, delete?) do
    unless File.exists?(jsonl_path) do
      IO.puts("Error: #{jsonl_path} not found")
      System.halt(1)
    end

    log(0, "Step 1: Set up revalidation workspace")
    setup_workspace()
    update_credence()

    log(0, "\nStep 2: Load entries from #{jsonl_path}")
    entries =
      jsonl_path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line ->
        case Jason.decode(line) do
          {:ok, entry} -> entry
          _ -> nil
        end
      end)
      |> Stream.reject(&is_nil/1)
      |> Enum.to_list()

    log(1, "#{length(entries)} entries loaded")

    log(0, "\nStep 3: Revalidate each entry")
    results =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, num} ->
        idx = entry["index"]
        ep = entry["entry_point"] || entry["original_entry_point"] || "?"

        module_code = entry["elixir_code"]
        test_code = entry["elixir_test"]

        unless module_code && test_code do
          IO.puts("  [#{num}/#{length(entries)}] idx=#{idx} #{ep} — SKIP (missing code/test)")
          {entry, :skip, []}
        else
          failures = validate(module_code, test_code)

          if failures == [] do
            IO.puts("  [#{num}/#{length(entries)}] idx=#{idx} #{ep} — ✓ PASS")
            {entry, :pass, []}
          else
            detail = format_failure_summary(failures)
            IO.puts("  [#{num}/#{length(entries)}] idx=#{idx} #{ep} — ✗ FAIL #{detail}")

            {entry, :fail, failures}
          end
        end
      end)

    # ── Report ─────────────────────────────────────────────────────

    passed = Enum.count(results, fn {_, status, _} -> status == :pass end)
    failed = Enum.count(results, fn {_, status, _} -> status == :fail end)
    skipped = Enum.count(results, fn {_, status, _} -> status == :skip end)

    # Count failures by stage
    stage_counts =
      results
      |> Enum.flat_map(fn {_, _, failures} -> Enum.map(failures, &elem(&1, 0)) end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, count} -> -count end)

    # Count failures by credence rule (most useful for us)
    credence_rule_counts =
      results
      |> Enum.flat_map(fn {_, _, failures} ->
        failures
        |> Enum.filter(fn {stage, _} -> stage == :credence end)
        |> Enum.flat_map(fn {_, msg} ->
          Regex.scan(~r/\[(?:warning|info|high)\] ([a-z_]+):/, msg)
          |> Enum.map(fn [_, rule] -> rule end)
        end)
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, count} -> -count end)

    IO.puts("\n" <> String.duplicate("═", 60))
    IO.puts("  REVALIDATION REPORT")
    IO.puts(String.duplicate("═", 60))
    IO.puts("  ✓ Passed:   #{passed}")
    IO.puts("  ✗ Failed:   #{failed}")
    IO.puts("  ⏭ Skipped:  #{skipped}")
    IO.puts("  Total:      #{length(entries)}")

    if stage_counts != [] do
      IO.puts("\n  Failures by stage:")
      Enum.each(stage_counts, fn {stage, count} ->
        IO.puts("    #{stage}: #{count}")
      end)
    end

    if credence_rule_counts != [] do
      IO.puts("\n  Credence failures by rule:")
      Enum.each(credence_rule_counts, fn {rule, count} ->
        IO.puts("    #{rule}: #{count}")
      end)
    end

    # List failed indices
    failed_indices =
      results
      |> Enum.filter(fn {_, status, _} -> status == :fail end)
      |> Enum.map(fn {entry, _, _} -> entry["index"] end)
      |> Enum.sort()

    if failed_indices != [] do
      IO.puts("\n  Failed indices: #{Enum.join(failed_indices, ", ")}")
    end

    IO.puts(String.duplicate("═", 60))

    # ── Delete mode ──────────────────────────────────────────────

    if delete? and failed > 0 do
      IO.puts("\n  --delete flag set: removing #{failed} failing entries from #{jsonl_path}")

      failed_index_set = MapSet.new(failed_indices)

      kept =
        results
        |> Enum.reject(fn {_, status, _} -> status == :fail end)
        |> Enum.map(fn {entry, _, _} -> Jason.encode!(entry) end)

      # Write to temp file then rename (atomic-ish)
      tmp_path = jsonl_path <> ".tmp"
      File.write!(tmp_path, Enum.join(kept, "\n") <> "\n")
      File.rename!(tmp_path, jsonl_path)

      IO.puts("  ✓ Wrote #{length(kept)} entries back to #{jsonl_path}")
      IO.puts("  Deleted indices: #{Enum.join(failed_indices, ", ")}")
      IO.puts("  Run the converter again to regenerate these.")
    end
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

args = System.argv()
delete? = "--delete" in args
args = Enum.reject(args, &(&1 == "--delete"))

jsonl_path =
  case args do
    [path] -> path
    [] -> "elixir_sft_educational_instruct.jsonl"
    _ ->
      IO.puts("Usage: elixir revalidate.exs [file.jsonl] [--delete]")
      System.halt(1)
  end

mode = if delete?, do: "REPORT + DELETE", else: "REPORT ONLY"

IO.puts("""
╔═══════════════════════════════════════════════════════╗
║  Credence Revalidator                                  ║
║  compile → format → credo → credence → test            ║
╚═══════════════════════════════════════════════════════╝
  File:   #{jsonl_path}
  Mode:   #{mode}
""")

Revalidator.run(jsonl_path, delete?)
