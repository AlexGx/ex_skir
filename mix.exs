defmodule Skir.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_skir,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.14", optional: true},
      {:jason, "~> 1.4", optional: true},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
