defmodule Finance.Mixfile do
  use Mix.Project

  def project do
    [app: :finance,
     version: "0.0.4",
     elixir: "~> 1.3",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     description: "A library to calculate Xirr through the bisection method using parallel processes.",
     test_coverage: [tool: ExCoveralls],
     preferred_cli_env: ["coveralls": :test, "coveralls.detail": :test, "coveralls.post": :test, "coveralls.html": :test],
     package: package(),
     description: description(),
     deps: deps()]
  end

  def application do
    [applications: [:logger, :tzdata]]
  end

  defp description do
    """
    A library to calculate Xirr through the bisection method using parallel processes.
    """
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README*"],
      maintainers: ["Roberto Trevisan"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/tubedude/finance-elixir"}
    ]
  end

  defp deps do
    [
      {:timex, "~> 3.1"},
      {:earmark, "~> 1.2", only: :dev},
      {:ex_doc, "~> 0.16", only: :dev},
      {:excoveralls, "~> 0.7", only: :test},
      {:credo, "~> 0.8", only: :dev}
    ]
  end
end
