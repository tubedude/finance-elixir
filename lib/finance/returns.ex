defmodule Finance.Returns do
  @moduledoc """
  Performance and risk metrics.

  Risk is covered by `volatility/2` (the annualised standard deviation of a price
  series' returns). The return metrics are `cagr/4` (compound annual growth
  rate), `payback_period/2` and `discounted_payback_period/3` (time to recover an
  outlay), `profitability_index/3` (present value of inflows per unit invested),
  and `twr/2` (time-weighted return).

  The cash-flow functions follow the same convention as `Finance.CashFlow.npv/2`:
  the initial outlay sits at index 0 (undiscounted) and later flows fall at
  periods 1, 2, …. Amounts and prices accept the same types as `Finance.CashFlow`
  — plain numbers, `Decimal`, or `ex_money` `%Money{}` values.
  """

  import Finance.Shared,
    only: [round_value: 2, unwrap!: 1, present_value: 2, discount_factor: 2, to_amount: 1]

  @type error :: Finance.error()

  @precision_options_schema NimbleOptions.new!(
                              precision: [
                                type: {:in, 0..15},
                                default: 6,
                                doc: "decimal places the result is rounded to (0..15)"
                              ]
                            )

  @twr_options_schema NimbleOptions.new!(
                        periods_per_year: [
                          type: :pos_integer,
                          doc: "if given, annualise the result over this many periods a year"
                        ],
                        precision: [
                          type: {:in, 0..15},
                          default: 6,
                          doc: "decimal places the result is rounded to (0..15)"
                        ]
                      )

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
                                 type: {:in, 0..15},
                                 default: 6,
                                 doc: "decimal places the result is rounded to (0..15)"
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

    case period_returns(Enum.map(prices, &to_amount/1), Keyword.fetch!(opts, :returns)) do
      :error ->
        {:error, :undefined}

      returns when length(returns) < 2 ->
        {:error, :insufficient_data}

      returns ->
        {:ok, round_value(annualise(returns, Keyword.fetch!(opts, :periods_per_year)), opts)}
    end
  end

  @doc "Same as `volatility/2`, but returns the value directly and raises `ArgumentError` on error."
  @spec volatility!([number], keyword) :: float
  def volatility!(prices, opts \\ []), do: prices |> volatility(opts) |> unwrap!()

  @doc """
  Compound annual growth rate — the constant yearly rate that grows `begin_value`
  into `end_value` over `years`.

      (end_value / begin_value)^(1/years) − 1

  Returns `{:error, :undefined}` when `begin_value` or `years` isn't positive, or
  the two values have opposite signs (no real rate).

      iex> Finance.Returns.cagr(1000, 2000, 10)
      {:ok, 0.071773}
  """
  @spec cagr(number, number, number, keyword) :: {:ok, float} | {:error, error}
  def cagr(begin_value, end_value, years, opts \\ [])
      when is_number(begin_value) and is_number(end_value) and is_number(years) and is_list(opts) do
    opts = NimbleOptions.validate!(opts, @precision_options_schema)

    cond do
      begin_value <= 0 -> {:error, :undefined}
      years <= 0 -> {:error, :undefined}
      end_value / begin_value < 0 -> {:error, :undefined}
      true -> {:ok, round_value(:math.pow(end_value / begin_value, 1 / years) - 1, opts)}
    end
  end

  @doc "Same as `cagr/4`, but returns the value directly and raises `ArgumentError` on error."
  @spec cagr!(number, number, number, keyword) :: float
  def cagr!(begin_value, end_value, years, opts \\ []) do
    begin_value |> cagr(end_value, years, opts) |> unwrap!()
  end

  @doc """
  Payback period — how many periods of cash flow it takes to recover the initial
  outlay, interpolating within the recovering period. The first amount is the
  outlay (negative), the rest are inflows.

  Returns `{:error, :undefined}` if the flows never recover, or there's no outlay
  to recover, and `{:error, :insufficient_data}` for an empty list.

      iex> Finance.Returns.payback_period([-1000, 400, 400, 400])
      {:ok, 2.5}
  """
  @spec payback_period([number], keyword) :: {:ok, float} | {:error, error}
  def payback_period(cash_flows, opts \\ []) when is_list(cash_flows) and is_list(opts) do
    opts = NimbleOptions.validate!(opts, @precision_options_schema)
    recovery_result(Enum.map(cash_flows, &to_amount/1), opts)
  end

  @doc "Same as `payback_period/2`, but returns the value directly and raises `ArgumentError` on error."
  @spec payback_period!([number], keyword) :: float
  def payback_period!(cash_flows, opts \\ []), do: cash_flows |> payback_period(opts) |> unwrap!()

  @doc """
  Discounted payback period — like `payback_period/2`, but recovers the outlay
  from cash flows discounted at `rate` (so it accounts for the time value of
  money and, for a non-negative rate, is at least as long as the plain payback).

      iex> Finance.Returns.discounted_payback_period([-1000, 600, 600, 600], 0.1)
      {:ok, 1.916667}
  """
  @spec discounted_payback_period([number], number, keyword) :: {:ok, float} | {:error, error}
  def discounted_payback_period(cash_flows, rate, opts \\ [])
      when is_list(cash_flows) and is_number(rate) and is_list(opts) do
    opts = NimbleOptions.validate!(opts, @precision_options_schema)

    if 1 + rate <= 0,
      do: {:error, :undefined},
      else: recovery_result(discount_flows(Enum.map(cash_flows, &to_amount/1), rate), opts)
  end

  @doc "Same as `discounted_payback_period/3`, but returns the value directly and raises `ArgumentError` on error."
  @spec discounted_payback_period!([number], number, keyword) :: float
  def discounted_payback_period!(cash_flows, rate, opts \\ []) do
    cash_flows |> discounted_payback_period(rate, opts) |> unwrap!()
  end

  @doc """
  Profitability index — the present value of a project's future inflows per unit
  of initial investment, discounted at `rate`. A value above 1 means the project
  adds value. Equivalent to `1 + NPV / initial investment`.

  The first amount is the initial outlay (negative); returns `{:error, :undefined}`
  if it isn't, and `{:error, :insufficient_data}` for an empty list.

      iex> Finance.Returns.profitability_index([-1000, 600, 600], 0.1)
      {:ok, 1.041322}
  """
  @spec profitability_index([number], number, keyword) :: {:ok, float} | {:error, error}
  def profitability_index(cash_flows, rate, opts \\ [])
      when is_list(cash_flows) and is_number(rate) and is_list(opts) do
    opts = NimbleOptions.validate!(opts, @precision_options_schema)
    profitability(Enum.map(cash_flows, &to_amount/1), rate, opts)
  end

  @doc "Same as `profitability_index/3`, but returns the value directly and raises `ArgumentError` on error."
  @spec profitability_index!([number], number, keyword) :: float
  def profitability_index!(cash_flows, rate, opts \\ []) do
    cash_flows |> profitability_index(rate, opts) |> unwrap!()
  end

  @doc """
  Time-weighted return — the return of a series of period returns linked
  geometrically, `∏(1 + rᵢ) − 1`. Immune to the timing of cash flows, which is
  what makes it the standard way to measure manager or fund performance.

  By default it's the cumulative return over the periods given. Pass
  `:periods_per_year` to annualise it.

      iex> Finance.Returns.twr([0.10, -0.05, 0.08])
      {:ok, 0.1286}

      iex> Finance.Returns.twr([0.02, 0.02], periods_per_year: 4)
      {:ok, 0.082432}
  """
  @spec twr([number], keyword) :: {:ok, float} | {:error, error}
  def twr(returns, opts \\ []) when is_list(returns) and is_list(opts) do
    opts = NimbleOptions.validate!(opts, @twr_options_schema)

    cond do
      returns == [] -> {:error, :insufficient_data}
      not Enum.all?(returns, &valid_return?/1) -> {:error, :undefined}
      true -> {:ok, round_value(time_weighted(returns, opts), opts)}
    end
  end

  # A period return below -100% has no meaning and would push `1 + cumulative`
  # negative, so annualisation's `:math.pow` would leave its real domain.
  defp valid_return?(r), do: is_number(r) and r >= -1

  @doc "Same as `twr/2`, but returns the value directly and raises `ArgumentError` on error."
  @spec twr!([number], keyword) :: float
  def twr!(period_returns, opts \\ []), do: period_returns |> twr(opts) |> unwrap!()

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

  # --- payback / discounted payback ---------------------------------------

  defp recovery_result(flows, opts) do
    case cumulative_recovery(flows) do
      :empty ->
        {:error, :insufficient_data}

      :never ->
        {:error, :undefined}

      {:recovered, whole, shortfall, recovering_flow} ->
        {:ok, round_value(whole + shortfall / recovering_flow, opts)}
    end
  end

  # Find the first period where the running cumulative crosses from negative to
  # non-negative, returning the whole periods before it, the shortfall still to
  # recover, and the flow that recovers it. `:never` if it never crosses (or
  # there's no initial outlay), `:empty` for no flows.
  defp cumulative_recovery([]), do: :empty

  defp cumulative_recovery(flows) do
    flows
    |> Enum.with_index()
    |> Enum.reduce_while(0.0, fn {flow, i}, cumulative ->
      next = cumulative + flow

      if i > 0 and cumulative < 0 and next >= 0 do
        {:halt, {:recovered, i - 1, -cumulative, flow}}
      else
        {:cont, next}
      end
    end)
    |> then(fn
      {:recovered, _, _, _} = recovered -> recovered
      _cumulative -> :never
    end)
  end

  defp discount_flows(flows, rate) do
    flows
    |> Enum.with_index()
    |> Enum.map(fn {flow, i} -> flow * discount_factor(rate, i) end)
  end

  # --- profitability index ------------------------------------------------

  defp profitability(_cash_flows, rate, _opts) when 1 + rate <= 0, do: {:error, :undefined}
  defp profitability([], _rate, _opts), do: {:error, :insufficient_data}

  defp profitability([initial | _], _rate, _opts) when is_number(initial) and initial >= 0,
    do: {:error, :undefined}

  defp profitability([initial | _] = cash_flows, rate, opts) do
    # PI = 1 + NPV / -initial_outlay. Discount at full precision and round once,
    # so the ratio isn't skewed by a pre-rounded NPV.
    flows = cash_flows |> Enum.with_index() |> Enum.map(fn {cf, i} -> {i * 1.0, cf * 1.0} end)
    {:ok, round_value(1 + present_value(flows, rate) / -initial, opts)}
  end

  # --- time-weighted return -----------------------------------------------

  defp time_weighted(returns, opts) do
    cumulative = Enum.reduce(returns, 1.0, fn r, acc -> acc * (1 + r) end) - 1

    case Keyword.get(opts, :periods_per_year) do
      nil -> cumulative
      periods_per_year -> :math.pow(1 + cumulative, periods_per_year / length(returns)) - 1
    end
  end
end
