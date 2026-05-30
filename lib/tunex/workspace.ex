defmodule Tunex.Workspace do
  @moduledoc """
  A single Mix project workspace for code validation, wired to the local
  credence clone as a **path dependency**.

  v2 runs a single stream (one GPU, one clone), so there is no workspace pool.
  The workspace compiles + validates against the local checkout at
  `Tunex.Config.credence_clone()`; the loop calls `recompile_credence/1` after
  an accepted rule so validation always sees the last-committed ruleset.
  """

  require Logger

  alias Tunex.Config

  # Credence check script (used by Validator step 5). Plain stdout, captured
  # into the row log.
  @credence_script ~S"""
  code = File.read!("lib/solution.ex")
  result = Credence.analyze(code)

  if result.valid do
    IO.puts("OK")
  else
    IO.puts("ISSUES: #{length(result.issues)} credence issue(s) found")
    for issue <- result.issues do
      line = if issue.meta[:line], do: "line #{issue.meta[:line]}", else: "unknown line"
      IO.puts("#{issue.rule}: #{issue.message} (#{line})")
    end
    System.halt(1)
  end
  """

  # Credence fix script. Emits FIXED / NO_CHANGES, then the full
  # `applied_rules` list (the before/after fix trace the rule-gen agent reads)
  # and any remaining unfixable issues. `applied_rules` entries are
  # `{module, count | :reverted}` with full module names.
  @credence_fix_script ~S"""
  code = File.read!("lib/solution.ex")
  result = Credence.fix(code)

  if result.code != code do
    File.write!("lib/solution.ex", result.code)
    IO.puts("FIXED")
  else
    IO.puts("NO_CHANGES")
  end

  IO.puts("APPLIED_RULES: #{inspect(result.applied_rules)}")

  if result.issues != [] do
    IO.puts("REMAINING_ISSUES: #{length(result.issues)} unfixable issue(s)")
    for issue <- result.issues do
      line = if issue.meta[:line], do: "line #{issue.meta[:line]}", else: "unknown line"
      IO.puts("#{issue.rule}: #{issue.message} (#{line})")
    end
  end
  """

  @credo_config """
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
  """

  @doc "Default single-workspace path (`var/run/workspace`)."
  def default_path, do: Config.run_path("workspace")

  @doc """
  Ensure the workspace exists and is wired to the credence path dep. Idempotent.
  On first creation it runs `deps.get` + `deps.compile` (dev + test).
  """
  def setup(path \\ default_path()) do
    if File.exists?(Path.join(path, "mix.exs")) do
      inject_deps(path)
      write_credo_config(path)
      write_scripts(path)
      ensure_deps(path)
    else
      Logger.info("[Workspace] creating workspace: #{path}/")
      # `mix new` prompts (and `System.cmd` has no stdin → hangs) if the target
      # dir already exists. `mix tunex.reset` pre-creates it, so clear any
      # non-project dir first.
      File.rm_rf!(path)
      File.mkdir_p!(Path.dirname(path))
      {output, code} = System.cmd("mix", ["new", path], stderr_to_stdout: true)
      if code != 0, do: raise("mix new failed: #{output}")

      inject_deps(path)
      write_credo_config(path)
      write_scripts(path)
      clean_defaults(path)
      bootstrap_deps(path)
      Logger.info("[Workspace] ✓ #{path} ready")
    end

    path
  end

  @doc "Remove generated solution + test files between rows."
  def clean_workspace(path \\ default_path()) do
    for f <- Path.wildcard(Path.join(path, "lib/*.ex")), do: File.rm(f)
    for f <- Path.wildcard(Path.join(path, "test/*_test.exs")), do: File.rm(f)
    :ok
  end

  @doc """
  Force-recompile the credence path dep in the workspace (dev + test) so a
  newly-committed rule takes effect. Called after an accepted rule and at boot.
  """
  def recompile_credence(path \\ default_path()) do
    Logger.info("[Workspace] recompiling credence path dep in #{path}")

    for env <- ~w(dev test) do
      System.cmd("mix", ["deps.compile", "credence", "--force"],
        cd: path,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", env}]
      )
    end

    Logger.info("[Workspace] ✓ credence recompiled")
    :ok
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp deps_block do
    clone = Config.credence_clone()

    ~s"""
    defp deps do
        [
          {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
          {:credence, path: "#{clone}", only: [:dev, :test], runtime: false}
        ]
    """
  end

  defp inject_deps(path) do
    mix_exs = Path.join(path, "mix.exs")
    content = File.read!(mix_exs)
    fixed = Regex.replace(~r/defp deps do\n\s+\[.*?\]/s, content, deps_block())
    File.write!(mix_exs, fixed)
  end

  defp write_credo_config(path) do
    File.write!(Path.join(path, ".credo.exs"), @credo_config)
  end

  defp write_scripts(path) do
    File.write!(Path.join(path, "run_credence.exs"), @credence_script)
    File.write!(Path.join(path, "run_credence_fix.exs"), @credence_fix_script)
  end

  defp clean_defaults(path) do
    for f <- Path.wildcard(Path.join(path, "lib/*.ex")), do: File.rm(f)
    for f <- Path.wildcard(Path.join(path, "test/*_test.exs")), do: File.rm(f)
  end

  defp bootstrap_deps(path) do
    System.cmd("mix", ["deps.get"], cd: path, stderr_to_stdout: true)

    for env <- ~w(dev test) do
      System.cmd("mix", ["deps.compile"], cd: path, stderr_to_stdout: true, env: [{"MIX_ENV", env}])
      # Compile the (empty) workspace app once so `workspace.app` exists; the
      # credence-fix step runs `mix run --no-compile` (to tolerate a broken
      # solution.ex) and needs the app file present.
      System.cmd("mix", ["compile"], cd: path, stderr_to_stdout: true, env: [{"MIX_ENV", env}])
    end
  end

  # Path deps don't populate `deps/`; the built dep lives under `_build`.
  defp ensure_deps(path) do
    built? = File.exists?(Path.join(path, "_build/test/lib/credence/ebin"))
    unless built?, do: bootstrap_deps(path)
  end
end
