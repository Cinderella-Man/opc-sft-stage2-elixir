defmodule Tunex.Validator do
  @moduledoc """
  Runs the validation pipeline against Elixir code in a workspace.

  Steps: compile → credence fix → re-compile → format → credo → credence check → test

  The credence fix step auto-fixes issues that Credence can handle
  deterministically (e.g. naming conventions, structural rewrites).
  Unfixable issues are reported as failures and fed back to the LLM.

  Returns `{failures, final_module_code, final_test_code}` where failures
  is a list of `{stage, message}` tuples. Format is auto-applied so
  final code may differ from input.
  """

  def run(module_code, test_code, workspace) do
    mod_path = Path.join(workspace, "lib/solution.ex")
    test_path = Path.join(workspace, "test/solution_test.exs")

    clean_workspace(workspace)
    File.write!(mod_path, module_code)
    File.write!(test_path, test_code)

    failures = []

    # 1. Compile
    {output, code} =
      System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
        cd: workspace,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    compiled = code == 0
    failures = if compiled, do: failures, else: failures ++ [{:compile, clean_output(output)}]

    # 2. Credence fix (auto-fix what it can)
    compiled =
      if compiled do
        case run_credence_fix(workspace) do
          {:fixed, true} -> true
          {:fixed, false} -> true
          :no_changes -> true
          :error -> true
        end
      else
        false
      end

    # 3. Format (auto-fix, don't fail)
    if compiled do
      {_, code} =
        System.cmd(
          "mix",
          ["format", "--check-formatted", "lib/solution.ex", "test/solution_test.exs"],
          cd: workspace,
          stderr_to_stdout: true
        )

      if code != 0 do
        System.cmd("mix", ["format", "lib/solution.ex", "test/solution_test.exs"],
          cd: workspace,
          stderr_to_stdout: true
        )
      end
    end

    # 4. Credo
    failures =
      if compiled do
        {output, _} =
          System.cmd(
            "mix",
            ["credo", "list", "--strict", "--format", "oneline", "lib/solution.ex"],
            cd: workspace,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        issues =
          output
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "lib/solution.ex"))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if issues == [], do: failures, else: failures ++ [{:credo, Enum.join(issues, "\n")}]
      else
        failures
      end

    # 5. Credence check (catch anything the fix step didn't cover)
    failures =
      if compiled do
        {output, code} =
          System.cmd("mix", ["run", "run_credence.exs"],
            cd: workspace,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        if code == 0, do: failures, else: failures ++ [{:credence, String.trim(output)}]
      else
        failures
      end

    # 6. Tests
    failures =
      if compiled do
        {output, code} =
          System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
            cd: workspace,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        if code == 0, do: failures, else: failures ++ [{:test, clean_output(output)}]
      else
        failures
      end

    # Re-read (format/fix may have changed files)
    final_mod = if compiled, do: File.read!(mod_path), else: module_code
    final_test = if compiled, do: File.read!(test_path), else: test_code

    {failures, final_mod, final_test}
  end

  @doc """
  Apply Credence auto-fix to module code without running the full pipeline.

  Writes the code to the workspace, compiles, runs `Credence.fix/2` via
  the workspace script, and reads back the result. Returns the (potentially
  fixed) code string regardless of whether remaining unfixable issues exist —
  those are left for `run/3` to catch.

  Returns `{:ok, fixed_code}` if the code compiled and fix ran successfully,
  or `{:error, original_code}` if compilation or the fix script failed.
  """
  def apply_credence_fix(module_code, workspace) do
    mod_path = Path.join(workspace, "lib/solution.ex")

    # Clean lib and write
    for f <- Path.wildcard(Path.join(workspace, "lib/*.ex")), do: File.rm(f)
    File.write!(mod_path, module_code)

    # Must compile before credence can analyze the AST
    {_, code} =
      System.cmd("mix", ["compile", "--force"],
        cd: workspace,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    if code != 0 do
      {:error, module_code}
    else
      case run_credence_fix(workspace) do
        {:fixed, true} ->
          {:ok, File.read!(mod_path)}

        {:fixed, false} ->
          # Fix broke compilation — revert
          File.write!(mod_path, module_code)
          {:error, module_code}

        :no_changes ->
          {:ok, module_code}

        :error ->
          {:error, module_code}
      end
    end
  end

  # ── Credence Fix (shared by run/3 and apply_credence_fix/2) ────────

  defp run_credence_fix(workspace) do
    mod_path = Path.join(workspace, "lib/solution.ex")
    original = File.read!(mod_path)

    {output, code} =
      System.cmd("mix", ["run", "run_credence_fix.exs"],
        cd: workspace,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    fixed? = String.contains?(output, "FIXED")

    cond do
      fixed? ->
        # Verify the fix still compiles
        {_, recompile_code} =
          System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
            cd: workspace,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        if recompile_code == 0 do
          {:fixed, true}
        else
          # Revert — the fix broke compilation
          File.write!(mod_path, original)

          System.cmd("mix", ["compile", "--force"],
            cd: workspace,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

          {:fixed, false}
        end

      code != 0 ->
        # Script crashed or credence not available
        IO.puts(
          "    [credence fix] script error (exit #{code}): #{String.slice(String.trim(output), 0, 200)}"
        )

        :error

      true ->
        :no_changes
    end
  end

  # ── Internal ───────────────────────────────────────────────────────

  defp clean_workspace(workspace) do
    for f <- Path.wildcard(Path.join(workspace, "lib/*.ex")), do: File.rm(f)
    for f <- Path.wildcard(Path.join(workspace, "test/*_test.exs")), do: File.rm(f)
  end

  defp clean_output(output) do
    output
    |> String.replace(~r/Compiling \d+ file.*\n/, "")
    |> String.replace(~r/Generated .* app\n/, "")
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.trim()
  end
end
