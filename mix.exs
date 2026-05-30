defmodule Tunex.MixProject do
  use Mix.Project

  def project do
    [
      app: :tunex,
      version: "0.2.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # The main app is a supervised OTP application. It does NOT depend on
  # credence — it shells into the local credence clone via the workspace.
  def application do
    [
      extra_applications: [:logger],
      mod: {Tunex.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:explorer, "~> 0.10"},
      {:jason, "~> 1.4"}
    ]
  end
end
