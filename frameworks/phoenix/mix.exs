defmodule HttparenaPhoenix.MixProject do
  use Mix.Project

  def project do
    [
      app: :httparena_phoenix,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {HttparenaPhoenix.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.27"},
      {:postgrex, "~> 0.19"}
    ]
  end
end
