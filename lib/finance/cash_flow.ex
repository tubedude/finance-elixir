defmodule Finance.CashFlow do
  @moduledoc """
  Discounting a series of cash flows: net present value (`npv/2`, `xnpv/2`) and
  internal rate of return (`irr/1`, `xirr/2`, `mirr/3`).

  The **dated** functions (`xirr`, `xnpv`) take `{date, amount}` flows at
  arbitrary dates and discount on an Actual/365 basis, matching the spreadsheet
  `XIRR`/`XNPV`. The **periodic** functions (`irr`, `npv`) take a plain list of
  amounts at equally spaced periods `0, 1, 2, …`.

  `xirr`/`irr` find the rate `r` that brings the net present value to zero,
  `Σ cf_i / (1 + r)^t_i = 0`, using `Finance.Solver` (Newton-Raphson with a
  bisection fallback by default).

  ## Options

  The rate-finding and value functions take an optional keyword list. Options are
  validated with `nimble_options`: an unknown key or bad value raises, while
  problems with the data come back as `{:error, reason}`.

  #{Finance.Shared.options_docs()}
  """

  import Finance.Shared,
    only: [
      to_amount: 1,
      round_value: 2,
      unwrap!: 1,
      options: 1,
      resolve_solver: 1,
      present_value: 2
    ]

  @type date :: Finance.date()
  @type amount :: Finance.amount()
  @type cash_flow :: Finance.cash_flow()
  @type rate :: Finance.rate()
  @type option :: Finance.option()
  @type error :: Finance.error()

  @days_in_year 365.0

  # === XIRR — internal rate of return for dated flows ======================

  @doc """
  Finds the XIRR of a list of `{date, amount}` cash flows — the annual rate of
  return that the flows imply, given when each one lands.

  Reach for this when your cash flows happen on irregular dates rather than at
  neat intervals. See `xirr/2` if you want to pass options or use the two-list
  form.

      iex> Finance.CashFlow.xirr([{~D[2015-06-01], 1_000_000}, {~D[2015-10-01], -2_200_000}, {~D[2015-11-01], -800_000}])
      {:ok, 21.118359}
  """
  @spec xirr([cash_flow]) :: {:ok, rate} | {:error, error}
  def xirr(cash_flows) when is_list(cash_flows), do: xirr(cash_flows, [])

  @doc """
  Finds the XIRR, accepting either `{date, amount}` pairs together with options,
  or two parallel lists — one of dates, one of amounts.

  The result is `{:ok, rate}` on success or `{:error, reason}` when the data
  can't yield a rate. Flows that fall on the same date are added together first.
  The series has to include at least one positive amount and one negative one,
  because without money flowing both in and out there is no return to solve for.

      iex> Finance.CashFlow.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}], guess: 0.5)
      {:ok, 0.1}

      iex> Finance.CashFlow.xirr([~D[2019-01-01], ~D[2020-01-01]], [-1000, 1100])
      {:ok, 0.1}
  """
  @spec xirr([cash_flow], [option]) :: {:ok, rate} | {:error, error}
  @spec xirr([date], [amount]) :: {:ok, rate} | {:error, error}
  def xirr(first, second) when is_list(first) and is_list(second) do
    if options?(second) do
      compute(first, second)
    else
      zip(first, second, [])
    end
  end

  @doc """
  Finds the XIRR from two parallel lists — dates and amounts — while also taking
  options for the solver.

      iex> Finance.CashFlow.xirr([~D[2019-01-01], ~D[2020-01-01]], [-1000, 1100], precision: 2)
      {:ok, 0.1}
  """
  @spec xirr([date], [amount], [option]) :: {:ok, rate} | {:error, error}
  def xirr(dates, values, opts)
      when is_list(dates) and is_list(values) and is_list(opts) do
    zip(dates, values, opts)
  end

  @doc "Same as `xirr/1`, but hands back the rate on its own and raises `ArgumentError` if the calculation fails."
  @spec xirr!([cash_flow]) :: rate
  def xirr!(cash_flows), do: cash_flows |> xirr() |> unwrap!()

  @doc "Same as `xirr/2`, but hands back the rate on its own and raises `ArgumentError` if the calculation fails."
  @spec xirr!([cash_flow] | [date], [option] | [amount]) :: rate
  def xirr!(first, second), do: first |> xirr(second) |> unwrap!()

  # === XNPV — net present value of dated flows =============================

  @doc """
  Computes the **XNPV** — the net present value of a set of dated cash flows,
  discounted back at `rate`.

      Σ cf_i / (1 + rate)^t_i

  Each time `t_i` is measured in years from the earliest flow on an Actual/365
  basis, the same day-count convention `xirr/2` uses. That shared convention is
  what ties the two together: `xnpv(r, flows)` comes out to roughly zero when
  `r` is `xirr(flows)`, so this is a handy way to check an XIRR result. And
  because a net present value is defined for any series, the flows here don't
  have to change sign the way `xirr/2` requires.

  The result is `{:ok, value}` or `{:error, reason}`. Flows on the same date are
  added together first, and you can pass the same `:precision` option as
  `xirr/2` (it defaults to `6`).

      iex> Finance.CashFlow.xnpv(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1000}])
      {:ok, -90.909091}

      iex> Finance.CashFlow.xnpv(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
      {:ok, 0.0}
  """
  @spec xnpv(rate, [cash_flow]) :: {:ok, number} | {:error, error}
  def xnpv(rate, cash_flows) when is_number(rate) and is_list(cash_flows) do
    xnpv(rate, cash_flows, [])
  end

  @doc "Same as `xnpv/2`, and additionally takes a `:precision` option. See `xnpv/2`."
  @spec xnpv(rate, [cash_flow], [option]) :: {:ok, number} | {:error, error}
  def xnpv(rate, cash_flows, opts)
      when is_number(rate) and is_list(cash_flows) and is_list(opts) do
    opts = options(opts)

    with {:ok, flows} <- normalize(cash_flows) do
      {:ok, round_value(present_value(flows, rate), opts)}
    end
  end

  @doc "Same as `xnpv/2`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec xnpv!(rate, [cash_flow]) :: number
  def xnpv!(rate, cash_flows), do: rate |> xnpv(cash_flows) |> unwrap!()

  # === IRR — internal rate of return for periodic flows ====================

  @doc """
  Computes the **IRR** — the internal rate of return for a list of amounts that
  occur at equally spaced periods `0, 1, 2, …`. Think of it as `xirr/2` for the
  common case where your flows land at regular intervals and you don't need to
  track exact dates.

  What comes back is the rate per period. As with `xirr/2`, the series has to
  contain at least one positive amount and one negative one.

      iex> Finance.CashFlow.irr([-1000, 1100])
      {:ok, 0.1}

      iex> Finance.CashFlow.irr([-1000, 500, 500, 300])
      {:ok, 0.156579}
  """
  @spec irr([amount]) :: {:ok, rate} | {:error, error}
  def irr(amounts) when is_list(amounts), do: irr(amounts, [])

  @doc "Same as `irr/1`, and additionally takes the same options as `xirr/2`."
  @spec irr([amount], [option]) :: {:ok, rate} | {:error, error}
  def irr(amounts, opts) when is_list(amounts) and is_list(opts) do
    opts = options(opts)
    flows = periodic_flows(amounts)

    with :ok <- validate(flows) do
      resolve_solver(opts).solve(flows, opts)
    end
  end

  @doc "Same as `irr/1`, but hands back the rate on its own and raises `ArgumentError` if the calculation fails."
  @spec irr!([amount], [option]) :: rate
  def irr!(amounts, opts \\ []), do: amounts |> irr(opts) |> unwrap!()

  # === NPV — net present value of periodic flows ===========================

  @doc """
  Computes the periodic **NPV** — the net present value of `amounts` occurring at
  equally spaced periods `0, 1, 2, …`, discounted at `rate`.

      Σ amount_i / (1 + rate)^i    (i starting at 0)

  > #### Convention {: .info}
  > The first amount sits at period 0 and so is left undiscounted. That is what
  > lets `npv/2` and `irr/1` line up: `npv(irr(a), a)` comes out to roughly
  > zero. It also means the result differs from a spreadsheet `NPV`, which
  > places the first amount at period 1. If you want to match a spreadsheet,
  > discount the first amount yourself or prepend a leading `0` to the list.

      iex> Finance.CashFlow.npv(0.1, [-1000, 1100])
      {:ok, 0.0}

      iex> Finance.CashFlow.npv(0.1, [-1000, 600, 600])
      {:ok, 41.322314}
  """
  @spec npv(rate, [amount]) :: {:ok, number} | {:error, error}
  def npv(rate, amounts) when is_number(rate) and is_list(amounts) do
    npv(rate, amounts, [])
  end

  @doc "Same as `npv/2`, and additionally takes a `:precision` option. See `npv/2`."
  @spec npv(rate, [amount], [option]) :: {:ok, number} | {:error, error}
  def npv(_rate, [], _opts), do: {:error, :insufficient_data}

  def npv(rate, amounts, opts)
      when is_number(rate) and is_list(amounts) and is_list(opts) do
    opts = options(opts)
    {:ok, round_value(present_value(periodic_flows(amounts), rate), opts)}
  end

  @doc "Same as `npv/2`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec npv!(rate, [amount]) :: number
  def npv!(rate, amounts), do: rate |> npv(amounts) |> unwrap!()

  # === MIRR — modified internal rate of return =============================

  @doc """
  Computes the **MIRR** — the modified internal rate of return for periodic
  `amounts`. It refines the idea behind IRR by letting you set two separate
  rates: positive flows are assumed to be reinvested at `reinvest_rate`, and
  negative flows are assumed to be financed at `finance_rate`.

  Because those assumptions are spelled out, MIRR has a closed form and a single
  answer, which sidesteps the multiple-root and convergence trouble that IRR can
  run into. As with `irr/1`, the series has to contain at least one positive
  amount and one negative one.

      iex> Finance.CashFlow.mirr([-120_000, 39_000, 30_000, 21_000, 37_000, 46_000], 0.10, 0.12)
      {:ok, 0.126094}
  """
  @spec mirr([amount], number, number, [option]) :: {:ok, rate} | {:error, error}
  def mirr(amounts, finance_rate, reinvest_rate, opts \\ [])
      when is_list(amounts) and is_number(finance_rate) and is_number(reinvest_rate) and
             is_list(opts) do
    opts = options(opts)
    values = Enum.map(amounts, &to_amount/1)
    n = length(values)

    cond do
      n < 2 -> {:error, :insufficient_data}
      not signed_both_ways?(values) -> {:error, :single_signed_flow}
      true -> {:ok, round_value(modified_irr(values, finance_rate, reinvest_rate, n), opts)}
    end
  end

  @doc "Same as `mirr/3`, but hands back the rate on its own and raises `ArgumentError` if the calculation fails."
  @spec mirr!([amount], number, number, [option]) :: rate
  def mirr!(amounts, finance_rate, reinvest_rate, opts \\ []) do
    amounts |> mirr(finance_rate, reinvest_rate, opts) |> unwrap!()
  end

  defp modified_irr(values, finance_rate, reinvest_rate, n) do
    periods = n - 1

    future_of_inflows =
      values
      |> Enum.with_index()
      |> Enum.reduce(0.0, fn {value, i}, acc ->
        if value > 0, do: acc + value * :math.pow(1 + reinvest_rate, periods - i), else: acc
      end)

    present_of_outflows =
      values
      |> Enum.with_index()
      |> Enum.reduce(0.0, fn {value, i}, acc ->
        if value < 0, do: acc + value / :math.pow(1 + finance_rate, i), else: acc
      end)

    :math.pow(future_of_inflows / -present_of_outflows, 1 / periods) - 1
  end

  # === Dispatch & normalization ============================================

  # An empty list or a proper keyword list is treated as options. A list of
  # `{date, amount}` pairs is not a keyword list (its keys are dates, not
  # atoms), and a list of numeric amounts is not either — so the two input
  # shapes are never confused.
  defp options?([]), do: true
  defp options?(list), do: Keyword.keyword?(list)

  defp zip(dates, values, opts) when length(dates) == length(values) do
    dates |> Enum.zip(values) |> compute(opts)
  end

  defp zip(_dates, _values, _opts), do: {:error, :mismatched_lengths}

  defp compute(cash_flows, opts) do
    opts = options(opts)

    with {:ok, flows} <- normalize(cash_flows),
         :ok <- validate(flows) do
      resolve_solver(opts).solve(flows, opts)
    end
  end

  # Parse dates, re-express each flow's time as years since the earliest date,
  # and merge flows that fall on the same date.
  defp normalize([]), do: {:error, :insufficient_data}

  defp normalize(cash_flows) do
    parsed = Enum.map(cash_flows, fn {date, amount} -> {to_date(date), to_amount(amount)} end)
    min_date = parsed |> Enum.map(&elem(&1, 0)) |> Enum.min(Date)

    flows =
      parsed
      |> Enum.reduce(%{}, fn {date, amount}, acc ->
        period = Date.diff(date, min_date) / @days_in_year
        Map.update(acc, period, amount, &(&1 + amount))
      end)
      |> Map.to_list()

    {:ok, flows}
  rescue
    _ in [ArgumentError, FunctionClauseError] -> {:error, :invalid_date}
  end

  # Build position-indexed flows (period 0, 1, 2, …) for the periodic functions.
  defp periodic_flows(amounts) do
    amounts
    |> Enum.with_index()
    |> Enum.map(fn {amount, index} -> {index / 1, to_amount(amount)} end)
  end

  defp to_date(%Date{} = date), do: date
  defp to_date({y, m, d}), do: Date.from_erl!({y, m, d})

  defp validate(flows) do
    amounts = Enum.map(flows, &elem(&1, 1))

    cond do
      length(flows) < 2 -> {:error, :insufficient_data}
      not signed_both_ways?(amounts) -> {:error, :single_signed_flow}
      true -> :ok
    end
  end

  defp signed_both_ways?(amounts) do
    Enum.any?(amounts, &(&1 > 0)) and Enum.any?(amounts, &(&1 < 0))
  end
end
