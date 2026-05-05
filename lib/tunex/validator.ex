defmodule Tunex.Validator do
  @moduledoc """
  Runs the validation pipeline against Elixir code in a workspace.

  Steps: compile → credence fix → propagate renames → re-compile → format → credo → credence check → test

  The credence fix step auto-fixes issues that Credence can handle
  deterministically (e.g. naming conventions, structural rewrites).
  When credence renames `is_foo` → `foo?`, the rename is propagated
  to the test file automatically. Unfixable issues are reported as
  failures and fed back to the LLM.

  Returns `{failures, final_module_code, final_test_code}` where failures
  is a list of `{stage, message}` tuples. Format is auto-applied so
  final code may differ from input.
  """

  require Logger

  def run(module_code, test_code, workspace) do
    mod_path = Path.join(workspace, "lib/solution.ex")
    test_path = Path.join(workspace, "test/solution_test.exs")

    Logger.info("[Validator.run] ── START in #{workspace} ──")

    Logger.debug(
      "[Validator.run] module code (#{String.length(module_code)} chars):\n#{module_code}"
    )

    Logger.debug("[Validator.run] test code (#{String.length(test_code)} chars):\n#{test_code}")

    clean_workspace(workspace)
    File.write!(mod_path, module_code)
    File.write!(test_path, test_code)

    failures = []

    # 1. Compile
    Logger.info("[Validator.run] step 1/6: compile")

    {output, code} =
      System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
        cd: workspace,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    compiled = code == 0
    Logger.info("[Validator.run] compile exit=#{code} compiled=#{compiled}")
    Logger.debug("[Validator.run] compile output:\n#{output}")
    failures = if compiled, do: failures, else: failures ++ [{:compile, clean_output(output)}]

    # 2. Credence fix (auto-fix what it can) + propagate renames to tests
    Logger.info("[Validator.run] step 2/6: credence fix")

    compiled =
      if compiled do
        case run_credence_fix(workspace) do
          {:fixed, true} ->
            Logger.info("[Validator.run] credence fixed code — propagating renames")
            # Credence changed the module — propagate is_ → ? renames to tests
            fixed_mod = File.read!(mod_path)
            Logger.debug("[Validator.run] module BEFORE credence fix:\n#{module_code}")
            Logger.debug("[Validator.run] module AFTER credence fix:\n#{fixed_mod}")
            updated_test = propagate_is_renames(module_code, fixed_mod, test_code)

            if updated_test != test_code do
              Logger.info("[Validator.run] test code updated with propagated renames")
              Logger.debug("[Validator.run] test BEFORE rename propagation:\n#{test_code}")
              Logger.debug("[Validator.run] test AFTER rename propagation:\n#{updated_test}")
              File.write!(test_path, updated_test)
            else
              Logger.debug("[Validator.run] no renames needed in test code")
            end

            true

          {:fixed, false} ->
            Logger.warning("[Validator.run] credence fix broke compilation — reverted")
            true

          :no_changes ->
            Logger.info("[Validator.run] credence: no changes needed")
            true

          :error ->
            Logger.warning("[Validator.run] credence fix script errored — continuing")
            true
        end
      else
        Logger.info("[Validator.run] skipping credence fix (compile failed)")
        false
      end

    # 3. Format (auto-fix, don't fail)
    Logger.info("[Validator.run] step 3/6: format")

    if compiled do
      {_fmt_output, fmt_code} =
        System.cmd(
          "mix",
          ["format", "--check-formatted", "lib/solution.ex", "test/solution_test.exs"],
          cd: workspace,
          stderr_to_stdout: true
        )

      if fmt_code != 0 do
        Logger.info("[Validator.run] code not formatted — auto-formatting")

        {fmt_fix_output, _} =
          System.cmd("mix", ["format", "lib/solution.ex", "test/solution_test.exs"],
            cd: workspace,
            stderr_to_stdout: true
          )

        Logger.debug("[Validator.run] format fix output: #{fmt_fix_output}")
      else
        Logger.debug("[Validator.run] code already formatted")
      end
    else
      Logger.info("[Validator.run] skipping format (compile failed)")
    end

    # 4. Credo
    Logger.info("[Validator.run] step 4/6: credo")

    failures =
      if compiled do
        {output, credo_code} =
          System.cmd(
            "mix",
            ["credo", "list", "--strict", "--format", "oneline", "lib/solution.ex"],
            cd: workspace,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        Logger.debug("[Validator.run] credo exit=#{credo_code} output:\n#{output}")

        issues =
          output
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "lib/solution.ex"))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if issues == [] do
          Logger.info("[Validator.run] credo: no issues")
          failures
        else
          Logger.warning("[Validator.run] credo: #{length(issues)} issue(s)")
          Enum.each(issues, &Logger.warning("[Validator.run] credo issue: #{&1}"))
          failures ++ [{:credo, Enum.join(issues, "\n")}]
        end
      else
        Logger.info("[Validator.run] skipping credo (compile failed)")
        failures
      end

    # 5. Credence check (catch anything the fix step didn't cover)
    Logger.info("[Validator.run] step 5/6: credence check")

    failures =
      if compiled do
        {output, credence_code} =
          System.cmd("mix", ["run", "run_credence.exs"],
            cd: workspace,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        Logger.info("[Validator.run] credence check exit=#{credence_code}")
        Logger.debug("[Validator.run] credence check output:\n#{output}")

        if credence_code == 0 do
          Logger.info("[Validator.run] credence check: passed")
          failures
        else
          Logger.warning("[Validator.run] credence check: FAILED")
          failures ++ [{:credence, String.trim(output)}]
        end
      else
        Logger.info("[Validator.run] skipping credence check (compile failed)")
        failures
      end

    # 6. Tests
    Logger.info("[Validator.run] step 6/6: tests")

    failures =
      if compiled do
        {output, test_code_exit} =
          System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
            cd: workspace,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        Logger.info("[Validator.run] test exit=#{test_code_exit}")
        Logger.debug("[Validator.run] test output:\n#{output}")

        if test_code_exit == 0 do
          Logger.info("[Validator.run] tests: PASSED")
          failures
        else
          Logger.warning("[Validator.run] tests: FAILED")
          failures ++ [{:test, clean_output(output)}]
        end
      else
        Logger.info("[Validator.run] skipping tests (compile failed)")
        failures
      end

    # Re-read (format/fix may have changed files)
    final_mod = if compiled, do: File.read!(mod_path), else: module_code
    final_test = if compiled, do: File.read!(test_path), else: test_code

    Logger.info(
      "[Validator.run] ── DONE — #{length(failures)} failure(s): #{inspect(Enum.map(failures, &elem(&1, 0)))} ──"
    )

    Logger.debug(
      "[Validator.run] final module (#{String.length(final_mod)} chars):\n#{final_mod}"
    )

    Logger.debug(
      "[Validator.run] final test (#{String.length(final_test)} chars):\n#{final_test}"
    )

    {failures, final_mod, final_test}
  end

  @doc """
  Apply Credence auto-fix to module code and propagate renames to test code.

  Writes the module to the workspace, compiles, runs `Credence.fix/2`,
  detects `is_foo` → `foo?` renames and applies them to test code too.

  Returns `{:ok, fixed_mod, fixed_test}` or `{:error, original_mod, original_test}`.
  """
  def apply_credence_fix(module_code, test_code, workspace) do
    mod_path = Path.join(workspace, "lib/solution.ex")

    Logger.info("[apply_credence_fix] starting in #{workspace}")

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
      Logger.warning("[apply_credence_fix] compile failed — returning original code")
      {:error, module_code, test_code}
    else
      case run_credence_fix(workspace) do
        {:fixed, true} ->
          fixed_mod = File.read!(mod_path)
          fixed_test = propagate_is_renames(module_code, fixed_mod, test_code)
          Logger.info("[apply_credence_fix] fix applied and renames propagated")
          {:ok, fixed_mod, fixed_test}

        {:fixed, false} ->
          # Fix broke compilation — revert
          File.write!(mod_path, module_code)
          Logger.warning("[apply_credence_fix] fix broke compilation — reverted")
          {:error, module_code, test_code}

        :no_changes ->
          Logger.info("[apply_credence_fix] no changes needed")
          {:ok, module_code, test_code}

        :error ->
          Logger.warning("[apply_credence_fix] credence error — returning original")
          {:error, module_code, test_code}
      end
    end
  end

  # ── Credence Fix (shared by run/3 and apply_credence_fix/3) ────────

  defp run_credence_fix(workspace) do
    mod_path = Path.join(workspace, "lib/solution.ex")
    original = File.read!(mod_path)

    Logger.debug("[run_credence_fix] running fix script in #{workspace}")

    {output, code} =
      System.cmd("mix", ["run", "run_credence_fix.exs"],
        cd: workspace,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    Logger.debug("[run_credence_fix] exit=#{code} output:\n#{output}")

    fixed? = String.contains?(output, "FIXED")

    cond do
      fixed? ->
        Logger.info("[run_credence_fix] credence reported FIXED — verifying compilation")
        # Verify the fix still compiles
        {recompile_out, recompile_code} =
          System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
            cd: workspace,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        if recompile_code == 0 do
          fixed_code = File.read!(mod_path)
          Logger.info("[run_credence_fix] fix compiles OK")
          Logger.debug("[run_credence_fix] original:\n#{original}")
          Logger.debug("[run_credence_fix] fixed:\n#{fixed_code}")
          {:fixed, true}
        else
          # Revert — the fix broke compilation
          Logger.warning("[run_credence_fix] fix broke compilation — reverting")
          Logger.debug("[run_credence_fix] recompile output:\n#{recompile_out}")
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
        Logger.warning(
          "[run_credence_fix] script error (exit #{code}): #{String.slice(String.trim(output), 0, 200)}"
        )

        :error

      true ->
        Logger.debug("[run_credence_fix] no changes needed")
        :no_changes
    end
  end

  # ── Rename Propagation ─────────────────────────────────────────────

  @doc false
  defp propagate_is_renames(original_mod, fixed_mod, test_code) do
    old_fns = extract_function_names(original_mod)
    new_fns = extract_function_names(fixed_mod)

    Logger.debug("[propagate_is_renames] old functions: #{inspect(old_fns)}")
    Logger.debug("[propagate_is_renames] new functions: #{inspect(new_fns)}")

    # Find is_ functions that were renamed to ? form
    renames =
      old_fns
      |> Enum.filter(&String.starts_with?(&1, "is_"))
      |> Enum.flat_map(fn is_name ->
        expected = String.trim_leading(is_name, "is_") <> "?"

        if expected in new_fns do
          [{is_name, expected}]
        else
          []
        end
      end)

    case renames do
      [] ->
        Logger.debug("[propagate_is_renames] no is_ → ? renames detected")
        test_code

      _ ->
        Logger.info("[propagate_is_renames] applying renames: #{inspect(renames)}")

        Enum.reduce(renames, test_code, fn {old_name, new_name}, code ->
          # Replace function calls: Module.is_foo( → Module.foo?(
          # Replace bare references: is_foo( → foo?(
          # Replace string references: "is_foo" → "foo?" (in test names)
          code
          |> String.replace(".#{old_name}(", ".#{new_name}(")
          |> String.replace(".#{old_name} ", ".#{new_name} ")
          |> String.replace("&#{old_name}/", "&#{new_name}/")
        end)
    end
  end

  defp extract_function_names(code) do
    Regex.scan(~r/def[p]?\s+(\w+[?!]?)/, code)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
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
