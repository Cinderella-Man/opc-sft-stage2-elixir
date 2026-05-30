defmodule Tunex.WorkspaceTest do
  use ExUnit.Case, async: true
  alias Tunex.Workspace

  # Regression: re-injecting deps into an already-injected mix.exs must NOT
  # corrupt it (the old non-greedy `\[.*?\]` regex truncated at the first `]` —
  # the `[:dev, :test]` in the credo line — producing a mismatched delimiter and
  # blacklisting every row).
  @mix_new ~S"""
  defmodule Gc.MixProject do
    use Mix.Project

    def project do
      [app: :gc, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
    end

    def application do
      [extra_applications: [:logger]]
    end

    defp deps do
      [
        # {:dep_from_hexpm, "~> 0.3.0"}
      ]
    end
  end
  """

  test "first injection adds credence + credo and stays parseable" do
    out = Workspace.rewrite_deps(@mix_new)
    assert out =~ ~s({:credence, path:)
    assert out =~ ~s({:credo, "~> 1.7")
    assert {:ok, _} = Code.string_to_quoted(out)
  end

  test "re-injection is idempotent and stays parseable" do
    once = Workspace.rewrite_deps(@mix_new)
    twice = Workspace.rewrite_deps(once)
    assert twice == once
    assert {:ok, _} = Code.string_to_quoted(twice)
    # exactly one deps function, one credence entry
    assert length(String.split(twice, "defp deps do")) == 2
    assert length(String.split(twice, ":credence")) == 2
  end
end
