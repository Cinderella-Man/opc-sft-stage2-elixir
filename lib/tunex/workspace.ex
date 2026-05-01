defmodule Tunex.Workspace do
  @moduledoc """
  Manages Mix project workspaces for code validation.

  Handles creating Mix projects, injecting deps (credo + credence),
  writing the credence runner script, and managing a pool of workspaces
  for parallel workers.
  """

  @credence_script ~S"""
  code = File.read!("lib/solution.ex")
  result = Credence.analyze(code)

  if result.valid do
    IO.puts("OK")
  else
    IO.puts("ISSUES: #{length(result.issues)} credence issue(s) found")
    for issue <- result.issues do
      line = if issue.meta[:line], do: "line #{issue.meta[:line]}", else: "unknown line"
      IO.puts("  [#{issue.severity}] #{issue.rule}: #{issue.message} (#{line})")
    end
    System.halt(1)
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

  @deps_block ~S"""
  defp deps do
        [
          {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
          {:credence, github: "Cinderella-Man/credence", only: [:dev, :test], runtime: false}
        ]
  """

  # ── Single Workspace ──────────────────────────────────────────────

  def setup(path) do
    if File.exists?(Path.join(path, "mix.exs")) do
      ensure_credence_dep(path)
      ensure_credence_script(path)
      ensure_deps(path)
    else
      IO.puts("Creating workspace: #{path}/")
      {output, code} = System.cmd("mix", ["new", path], stderr_to_stdout: true)
      if code != 0, do: raise("mix new failed: #{output}")

      inject_deps(path)
      write_credo_config(path)
      ensure_credence_script(path)
      clean_defaults(path)
      ensure_deps(path)
      IO.puts("  ✓ Workspace #{path} ready")
    end
  end

  def update_credence(path) do
    IO.puts("Updating credence to latest in #{path}...")
    System.cmd("mix", ["deps.update", "credence"], cd: path, stderr_to_stdout: true)
    System.cmd("mix", ["deps.compile", "credence", "--force"], cd: path, stderr_to_stdout: true)
    IO.puts("  ✓ Credence updated")
  end

  # ── Pool Management ───────────────────────────────────────────────

  def setup_pool(base_path, count) do
    Enum.each(0..(count - 1), fn id -> setup(pool_path(base_path, id)) end)
    Agent.start_link(fn -> Enum.to_list(0..(count - 1)) end, name: :workspace_pool)
  end

  def pool_path(base_path, id), do: "#{base_path}_#{id}"

  def checkout do
    Agent.get_and_update(:workspace_pool, fn
      [id | rest] -> {id, rest}
      [] -> {:wait, []}
    end)
  end

  def checkin(id) do
    Agent.update(:workspace_pool, fn ids -> [id | ids] end)
  end

  # ── Internal ───────────────────────────────────────────────────────

  defp inject_deps(path) do
    mix_exs = Path.join(path, "mix.exs")
    content = File.read!(mix_exs)
    fixed = Regex.replace(~r/defp deps do\n\s+\[.*?\]/s, content, @deps_block)
    File.write!(mix_exs, fixed)
  end

  defp ensure_credence_dep(path) do
    mix_exs = Path.join(path, "mix.exs")
    content = File.read!(mix_exs)

    unless String.contains?(content, "credence") do
      fixed = String.replace(content,
        ~s({:credo, "~> 1.7", only: [:dev, :test], runtime: false}),
        ~s({:credo, "~> 1.7", only: [:dev, :test], runtime: false},\n        {:credence, github: "Cinderella-Man/credence", only: [:dev, :test], runtime: false}))
      File.write!(mix_exs, fixed)
    end
  end

  defp write_credo_config(path) do
    File.write!(Path.join(path, ".credo.exs"), @credo_config)
  end

  defp ensure_credence_script(path) do
    script = Path.join(path, "run_credence.exs")
    unless File.exists?(script), do: File.write!(script, @credence_script)
  end

  defp clean_defaults(path) do
    for f <- Path.wildcard(Path.join(path, "lib/*.ex")), do: File.rm(f)
    for f <- Path.wildcard(Path.join(path, "test/*_test.exs")), do: File.rm(f)
  end

  defp ensure_deps(path) do
    unless File.exists?(Path.join(path, "deps/credence")) do
      System.cmd("mix", ["deps.get"], cd: path, stderr_to_stdout: true)
      System.cmd("mix", ["deps.compile"], cd: path, stderr_to_stdout: true)
    end
  end
end
