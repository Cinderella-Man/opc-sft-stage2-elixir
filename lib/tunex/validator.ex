defmodule Tunex.Validator do
  @moduledoc """
  Runs the 5-step validation pipeline against Elixir code in a workspace.

  Steps: compile → format → credo → credence → test

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
    {output, code} = System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
      cd: workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
    compiled = code == 0
    failures = if compiled, do: failures, else: failures ++ [{:compile, clean_output(output)}]

    # 2. Format (auto-fix, don't fail)
    if compiled do
      {_, code} = System.cmd("mix", ["format", "--check-formatted", "lib/solution.ex", "test/solution_test.exs"],
        cd: workspace, stderr_to_stdout: true)
      if code != 0 do
        System.cmd("mix", ["format", "lib/solution.ex", "test/solution_test.exs"],
          cd: workspace, stderr_to_stdout: true)
      end
    end

    # 3. Credo
    failures = if compiled do
      {output, _} = System.cmd("mix", ["credo", "list", "--strict", "--format", "oneline", "lib/solution.ex"],
        cd: workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      issues = output
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "lib/solution.ex"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

      if issues == [], do: failures, else: failures ++ [{:credo, Enum.join(issues, "\n")}]
    else
      failures
    end

    # 4. Credence
    failures = if compiled do
      {output, code} = System.cmd("mix", ["run", "--no-start", "run_credence.exs"],
        cd: workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0, do: failures, else: failures ++ [{:credence, String.trim(output)}]
    else
      failures
    end

    # 5. Tests
    failures = if compiled do
      {output, code} = System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
        cd: workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0, do: failures, else: failures ++ [{:test, clean_output(output)}]
    else
      failures
    end

    # Re-read (format may have changed files)
    final_mod = if compiled, do: File.read!(mod_path), else: module_code
    final_test = if compiled, do: File.read!(test_path), else: test_code

    {failures, final_mod, final_test}
  end

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
