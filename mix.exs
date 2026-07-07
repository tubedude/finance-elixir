defmodule Finance.MixProject do
  use Mix.Project

  @version "1.7.0"
  @source_url "https://github.com/tubedude/finance-elixir"

  def project do
    [
      app: :finance,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix]],
      docs: docs()
    ]
  end

  # A stand-in `Money` struct lives in test/support so the suite can exercise the
  # ex_money path without depending on ex_money (and its Decimal 2.x pin).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
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
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Cash flow": [Finance.CashFlow],
        "Time value of money": [Finance.TVM],
        "Fixed income": [Finance.Bonds],
        Metrics: [Finance.Returns, Finance.Rates, Finance.Depreciation],
        "Extension points": [
          Finance.Solver,
          Finance.Solver.Newton,
          Finance.Solver.Brent,
          Finance.DayCount
        ]
      ]
    ]
  end

  defp deps do
    [
      {:decimal, "~> 2.0 or ~> 3.0", optional: true},
      {:nimble_options, "~> 1.1"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
    ]
  end
end
