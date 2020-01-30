defmodule Poolgirl.Mixfile do
  use Mix.Project

  def project do
    [app: :poolgirl,
     version: "1.5.2",
     elixir: "~> 1.5",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger]]
  end

  defp deps do
    [
      {:poolboy, "~> 1.5"}
    ]
  end
end
