defmodule AmmoniaDesk.MixProject do
  use Mix.Project

  def project do
    [
      app: :ammonia_desk,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AmmoniaDesk.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_live_view, "~> 0.20"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:jason, "~> 1.4"},
      {:plug_cowboy, "~> 2.6"},
      {:req, "~> 0.4"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd cd native && zig build-exe solver.zig -lc"]
    ]
  end
end
