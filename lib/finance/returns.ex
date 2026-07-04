defmodule Finance.Returns do
  @moduledoc """
  Performance and risk metrics for a price or return series.

  For now this covers `volatility/2`; return metrics such as CAGR, payback, and
  time-weighted return will land here as the library grows.
  """

  import Finance.Shared, only: [round_value: 2, unwrap!: 1]

  @type error :: Finance.error()

  @volatility_options_schema NimbleOptions.new!(
                               periods_per_year: [
                                 type: :pos_integer,
                                 default: 252,
                                 doc:
                                   "number of periods in a year, used to annualise (252 trading days by default)"
                               ],
                               returns: [
                                 type: {:in, [:simple, :log]},
                                 default: :simple,
                                 doc:
                                   "how to measure each period's return: `:simple` `(b - a) / a` or `:log` `ln(b / a)`"
                               ],
                               precision: [
                                 type: :non_neg_integer,
                                 default: 6,
                                 doc: "decimal places the result is rounded to"
                               ]
                             )

  @doc """
  Annualised volatility of a price series — the standard deviation of its
  period-over-period returns, scaled up to a yearly figure.

  Give it a list of prices in time order (daily closes, say). It measures the
  return between each consecutive pair, takes their sample standard deviation,
  and annualises by `√periods_per_year`. At least three prices are needed, and
  every price must be positive.

      iex> Finance.Returns.volatility([100, 102, 101, 103, 105])
      {:ok, 0.234528}

  ## Options

  #{NimbleOptions.docs(@volatility_options_schema)}
  """
  @spec volatility([number], keyword) :: {:ok, float} | {:error, error}
  def volatility(prices, opts \\ []) when is_list(prices) do
    opts = NimbleOptions.validate!(opts, @volatility_options_schema)
    returns = period_returns(prices, Keyword.fetch!(opts, :returns))

    cond do
      returns == :error ->
        {:error, :undefined}

      length(returns) < 2 ->
        {:error, :insufficient_data}

      true ->
        {:ok, round_value(annualise(returns, Keyword.fetch!(opts, :periods_per_year)), opts)}
    end
  end

  @doc "Same as `volatility/2`, but hands back the value on its own and raises `ArgumentError` if it can't be computed."
  @spec volatility!([number], keyword) :: float
  def volatility!(prices, opts \\ []), do: prices |> volatility(opts) |> unwrap!()

  # Consecutive-pair returns, or :error if a price is non-positive. Order does
  # not matter for the standard deviation, so the reversed list is fine.
  defp period_returns(prices, kind) do
    prices
    |> Enum.zip(Enum.drop(prices, 1))
    |> Enum.reduce_while([], fn {a, b}, acc ->
      if is_number(a) and is_number(b) and a > 0 and b > 0 do
        {:cont, [period_return(kind, a, b) | acc]}
      else
        {:halt, :error}
      end
    end)
  end

  defp period_return(:simple, a, b), do: (b - a) / a
  defp period_return(:log, a, b), do: :math.log(b / a)

  defp annualise(returns, periods_per_year) do
    n = length(returns)
    mean = Enum.sum(returns) / n
    sum_of_squares = Enum.reduce(returns, 0.0, fn r, acc -> acc + (r - mean) * (r - mean) end)
    :math.sqrt(sum_of_squares / (n - 1)) * :math.sqrt(periods_per_year)
  end
end
