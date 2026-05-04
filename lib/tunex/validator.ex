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

    # 2. Credence fix (auto-fix what it can) + propagate renames to tests
    compiled =
      if compiled do
        case run_credence_fix(workspace) do
          {:fixed, true} ->
            # Credence changed the module — propagate is_ → ? renames to tests
            fixed_mod = File.read!(mod_path)
            updated_test = propagate_is_renames(module_code, fixed_mod, test_code)

            if updated_test != test_code do
              File.write!(test_path, updated_test)
            end

            true

          {:fixed, false} ->
            true

          :no_changes ->
            true

          :error ->
            true
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
  Apply Credence auto-fix to module code and propagate renames to test code.

  Writes the module to the workspace, compiles, runs `Credence.fix/2`,
  detects `is_foo` → `foo?` renames and applies them to test code too.

  Returns `{:ok, fixed_mod, fixed_test}` or `{:error, original_mod, original_test}`.
  """
  def apply_credence_fix(module_code, test_code, workspace) do
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
      {:error, module_code, test_code}
    else
      case run_credence_fix(workspace) do
        {:fixed, true} ->
          fixed_mod = File.read!(mod_path)
          fixed_test = propagate_is_renames(module_code, fixed_mod, test_code)
          {:ok, fixed_mod, fixed_test}

        {:fixed, false} ->
          # Fix broke compilation — revert
          File.write!(mod_path, module_code)
          {:error, module_code, test_code}

        :no_changes ->
          {:ok, module_code, test_code}

        :error ->
          {:error, module_code, test_code}
      end
    end
  end

  # ── Credence Fix (shared by run/3 and apply_credence_fix/3) ────────

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

  # ── Rename Propagation ─────────────────────────────────────────────

  @doc false
  defp propagate_is_renames(original_mod, fixed_mod, test_code) do
    old_fns = extract_function_names(original_mod)
    new_fns = extract_function_names(fixed_mod)

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
        test_code

      _ ->
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
