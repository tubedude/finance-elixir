defmodule Finance.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/tubedude/finance-elixir"

  def project do
    [
      app: :finance,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix]],
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp description do
    "Cash-flow analysis for Elixir: XIRR/IRR, net present value, modified IRR, " <>
      "time-value-of-money, and depreciation."
  end

  defp package do
    [
      files: ~w(lib mix.exs README.md CHANGELOG.md),
      maintainers: ["Roberto Trevisan"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Finance",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp deps do
    [
      {:decimal, "~> 3.0", optional: true},
      {:nimble_options, "~> 1.1"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
