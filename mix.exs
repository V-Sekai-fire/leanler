defmodule Leanler.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/V-Sekai-fire/leanler"

  def project do
    [
      app: :leanler,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "Lean 4 functions as OTP NIFs or C nodes, generated from a mix.exs declaration.",
      package: package(),
      source_url: @source_url,
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
