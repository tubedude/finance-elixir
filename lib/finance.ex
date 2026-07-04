defmodule Finance do
  @options_schema NimbleOptions.new!(
                    guess: [
                      type: :float,
                      default: 0.1,
                      doc: "initial rate for the Newton-Raphson solver"
                    ],
                    tolerance: [
                      type: :float,
                      default: 1.0e-9,
                      doc: "convergence threshold on the net present value"
                    ],
                    max_iterations: [
                      type: :pos_integer,
                      default: 100,
                      doc: "cap on solver iterations before giving up"
                    ],
                    precision: [
                      type: :non_neg_integer,
                      default: 6,
                      doc: "decimal places the result is rounded to"
                    ]
                  )

  @moduledoc """
  Financial calculations for cash-flow analysis: internal rate of return, net
  present value, modified IRR, and the usual time-value-of-money and
  depreciation helpers.

  The functions fall into four families, grouped by the question they answer:

    * **Rate of return** — when you have a stream of cash flows and want to know
      the rate they imply. `xirr/2` and `irr/1` find that rate; `mirr/3`
      answers a variation of the same question. `xirr/2` works with
      `{date, amount}` flows at arbitrary dates and discounts on an Actual/365
      basis, matching the spreadsheet `XIRR`; `irr/1` is its counterpart for
      amounts spread over equally spaced periods `0, 1, 2, …`.
    * **Present and future value** — when you know a rate and want to value a
      stream of flows against it. `xnpv/2` handles dated flows, `npv/2` handles
      periodic ones.
    * **Time value of money** — `fv/5`, `pv/5`, `pmt/5`, `nper/5`, and `rate/6`
      each take a standard annuity and solve it for one unknown, the way a
      financial calculator does.
    * **Depreciation** — `sln/3`, `syd/4`, `ddb/5`, and `db/5` write an asset
      down from its cost to its salvage value over its useful life, either
      evenly or on an accelerated schedule.
    * **Volatility** — `volatility/2` annualises the standard deviation of a
      price series' returns.

  The centerpiece is XIRR, which finds the rate `r` that brings the net present
  value of a set of dated flows to zero:

      Σ cf_i / (1 + r)^t_i = 0

  where `t_i` is the number of years between a flow and the earliest one in the
  series. There is no closed form for this, so the solver looks for the root
  numerically: it runs Newton-Raphson, using the analytic derivative of the NPV,
  and falls back to a bracketing bisection when a Newton step wanders outside the
  valid domain or fails to converge. Throughout, it follows the conventions a
  spreadsheet `XIRR` uses — Actual/365 day counting, a `0.1` starting guess, and
  a cap of 100 iterations.

  ## Example

      iex> Finance.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
      {:ok, 0.1}

  You can pass dated flows as `{date, amount}` pairs or as two parallel lists of
  dates and amounts, whichever reads better at the call site. Dates may be `Date`
  structs or Erlang-style `{year, month, day}` tuples. Amounts may be any number
  — integer minor units such as cents, or floats — or a `Decimal` when you have
  that optional dependency installed. Whatever you feed in, the result comes back
  as a float.

  ## Options

  The rate-finding and value functions take an optional keyword list to tune the
  solver and the rounding. Options are validated with `nimble_options`: passing
  an unknown key or a bad value raises, since that is a mistake in your code,
  whereas problems with the data itself come back as `{:error, reason}` for you
  to handle.

  #{NimbleOptions.docs(@options_schema)}
  """

  @typedoc "A date, given either as a `Date` struct or as an Erlang-style `{year, month, day}` tuple."
  @type date :: Date.t() | {integer, integer, integer}

  @typedoc "A cash-flow amount. This can be any number, or a `Decimal` when you have that optional dependency installed."
  @type amount :: number | Decimal.t()

  @typedoc "A cash flow on a given date. Money coming in is positive, money going out is negative."
  @type cash_flow :: {date, amount}

  @typedoc "An annual rate of return expressed as a fraction, so `0.1` means 10%."
  @type rate :: float

  @type option ::
          {:guess, number}
          | {:tolerance, number}
          | {:max_iterations, pos_integer}
          | {:precision, non_neg_integer}

  @type error ::
          :mismatched_lengths
          | :insufficient_data
          | :single_signed_flow
          | :invalid_date
          | :did_not_converge
          | :undefined

  @days_in_year 365.0

  # === XIRR — internal rate of return for dated flows ======================

  @doc """
  Finds the XIRR of a list of `{date, amount}` cash flows — the annual rate of
  return that the flows imply, given when each one lands.

  Reach for this when your cash flows happen on irregular dates rather than at
  neat intervals. See `xirr/2` if you want to pass options or use the two-list
  form.

      iex> Finance.xirr([{~D[2015-06-01], 1_000_000}, {~D[2015-10-01], -2_200_000}, {~D[2015-11-01], -800_000}])
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

      iex> Finance.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}], guess: 0.5)
      {:ok, 0.1}

      iex> Finance.xirr([~D[2019-01-01], ~D[2020-01-01]], [-1000, 1100])
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

      iex> Finance.xirr([~D[2019-01-01], ~D[2020-01-01]], [-1000, 1100], precision: 2)
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

      iex> Finance.xnpv(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1000}])
      {:ok, -90.909091}

      iex> Finance.xnpv(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
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

      iex> Finance.irr([-1000, 1100])
      {:ok, 0.1}

      iex> Finance.irr([-1000, 500, 500, 300])
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
      solve(flows, opts)
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

      iex> Finance.npv(0.1, [-1000, 1100])
      {:ok, 0.0}

      iex> Finance.npv(0.1, [-1000, 600, 600])
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

      iex> Finance.mirr([-120_000, 39_000, 30_000, 21_000, 37_000, 46_000], 0.10, 0.12)
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

  # === TVM — time-value-of-money scalars ===================================
  #
  # These solve the standard annuity equation for one unknown:
  #
  #     pv·(1+r)^n + pmt·(1 + r·type)·((1+r)^n − 1)/r + fv = 0
  #
  # `type` is 0 for payments at the end of each period (ordinary annuity) or 1
  # for the beginning (annuity due). Sign convention follows spreadsheets: money
  # you receive is positive, money you pay out is negative.

  @doc """
  Works out the future value of an investment: what it grows to after `nper`
  periods, starting from a present value of `pv`, with a fixed payment of `pmt`
  each period, all compounding at `rate`.

  Use this to answer "if I put this much in now and add this much every period,
  what will I have at the end?". As with the rest of the time-value-of-money
  functions, `type` chooses when each payment happens — `0` for the end of the
  period (an ordinary annuity) or `1` for the beginning (an annuity due) — and
  the sign convention follows spreadsheets, so money you receive is positive and
  money you pay out is negative.

      iex> {:ok, value} = Finance.fv(0.05, 10, -100, -1000)
      iex> Float.round(value, 2)
      2886.68
  """
  @spec fv(number, number, number, number, 0 | 1) :: {:ok, float} | {:error, error}
  def fv(rate, nper, pmt, pv \\ 0.0, type \\ 0)
      when is_number(rate) and is_number(nper) and is_number(pmt) and is_number(pv) and
             type in [0, 1] do
    value =
      if rate == 0,
        do: -(pv + pmt * nper),
        else: -(pv * :math.pow(1 + rate, nper) + pmt * annuity(rate, nper, type))

    {:ok, value * 1.0}
  end

  @doc "Same as `fv/5`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec fv!(number, number, number, number, 0 | 1) :: float
  def fv!(rate, nper, pmt, pv \\ 0.0, type \\ 0), do: rate |> fv(nper, pmt, pv, type) |> unwrap!()

  @doc """
  Works out the present value of an investment: what a future stream is worth
  today. The stream is `pmt` paid each period for `nper` periods plus a lump sum
  `fv` at the end, all discounted back at `rate`.

  It answers the mirror image of `fv/5`'s question — "how much would I need to
  put in now to fund these future payments?". The same `type` and sign
  conventions apply.

      iex> {:ok, value} = Finance.pv(0.05, 10, -100, -1000)
      iex> Float.round(value, 2)
      1386.09
  """
  @spec pv(number, number, number, number, 0 | 1) :: {:ok, float} | {:error, error}
  def pv(rate, nper, pmt, fv \\ 0.0, type \\ 0)
      when is_number(rate) and is_number(nper) and is_number(pmt) and is_number(fv) and
             type in [0, 1] do
    value =
      if rate == 0,
        do: -(fv + pmt * nper),
        else: -(fv + pmt * annuity(rate, nper, type)) / :math.pow(1 + rate, nper)

    {:ok, value * 1.0}
  end

  @doc "Same as `pv/5`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec pv!(number, number, number, number, 0 | 1) :: float
  def pv!(rate, nper, pmt, fv \\ 0.0, type \\ 0), do: rate |> pv(nper, pmt, fv, type) |> unwrap!()

  @doc """
  Works out the level payment per period needed to pay off a present value `pv`
  (and arrive at a future value `fv`) over `nper` periods at `rate`.

  This is the loan-payment question: given an amount borrowed today, what fixed
  installment clears it over the term? The same `type` and sign conventions
  apply, so a loan you take out is a positive `pv` and the payment comes back
  negative.

      iex> {:ok, payment} = Finance.pmt(0.10, 10, 1000)
      iex> Float.round(payment, 2)
      -162.75
  """
  @spec pmt(number, number, number, number, 0 | 1) :: {:ok, float} | {:error, error}
  def pmt(rate, nper, pv, fv \\ 0.0, type \\ 0)
      when is_number(rate) and is_number(nper) and is_number(pv) and is_number(fv) and
             type in [0, 1] do
    cond do
      nper == 0 -> {:error, :undefined}
      rate == 0 -> {:ok, -(pv + fv) / nper * 1.0}
      true -> {:ok, -(pv * :math.pow(1 + rate, nper) + fv) / annuity(rate, nper, type) * 1.0}
    end
  end

  @doc "Same as `pmt/5`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec pmt!(number, number, number, number, 0 | 1) :: float
  def pmt!(rate, nper, pv, fv \\ 0.0, type \\ 0), do: rate |> pmt(nper, pv, fv, type) |> unwrap!()

  @doc """
  Works out how many periods it takes for payments of `pmt` to pay off a present
  value `pv` (reaching future value `fv`) at `rate`.

  This is the "how long until it's paid off?" question. When the numbers don't
  describe a situation that ever resolves, it returns `{:error, :undefined}`.

      iex> {:ok, periods} = Finance.nper(0.05, -100, 1000)
      iex> Float.round(periods, 2)
      14.21
  """
  @spec nper(number, number, number, number, 0 | 1) :: {:ok, float} | {:error, error}
  def nper(rate, pmt, pv, fv \\ 0.0, type \\ 0)
      when is_number(rate) and is_number(pmt) and is_number(pv) and is_number(fv) and
             type in [0, 1] do
    nper_periods(rate, pmt, pv, fv, type)
  end

  defp nper_periods(rate, pmt, pv, fv, type) do
    cond do
      rate == 0 and pmt == 0 -> {:error, :undefined}
      rate == 0 -> {:ok, -(pv + fv) / pmt * 1.0}
      1 + rate <= 0 -> {:error, :undefined}
      true -> nper_with_rate(rate, pmt, pv, fv, type)
    end
  end

  @doc "Same as `nper/5`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec nper!(number, number, number, number, 0 | 1) :: float
  def nper!(rate, pmt, pv, fv \\ 0.0, type \\ 0), do: rate |> nper(pmt, pv, fv, type) |> unwrap!()

  @doc """
  Works out the interest rate per period of an annuity described by `nper`
  payments of `pmt`, a present value `pv`, and a future value `fv`. `nper` has to
  be a whole number of periods.

  There is no closed form for the rate, so this reuses the same numerical solver
  as `irr/1` and takes the same options as `xirr/2`. If it can't pin down a rate,
  it returns `{:error, :did_not_converge}`.

      iex> Finance.rate(10, -100, 1000)
      {:ok, 0.0}
  """
  @spec rate(number, number, number, number, 0 | 1, [option]) :: {:ok, rate} | {:error, error}
  def rate(nper, pmt, pv, fv \\ 0.0, type \\ 0, opts \\ [])
      when is_number(nper) and is_number(pmt) and is_number(pv) and is_number(fv) and
             type in [0, 1] and is_list(opts) do
    n = trunc(nper)

    if nper == n and n > 0 do
      solve(tvm_flows(n, pmt, pv, fv, type), options(opts))
    else
      {:error, :undefined}
    end
  end

  @doc "Same as `rate/6`, but hands back the rate on its own and raises `ArgumentError` if the calculation fails."
  @spec rate!(number, number, number, number, 0 | 1, [option]) :: rate
  def rate!(nper, pmt, pv, fv \\ 0.0, type \\ 0, opts \\ []) do
    nper |> rate(pmt, pv, fv, type, opts) |> unwrap!()
  end

  # (1 + r·type) · ((1+r)^n − 1) / r — the annuity factor that multiplies pmt.
  defp annuity(rate, nper, type) do
    (1 + rate * type) * (:math.pow(1 + rate, nper) - 1) / rate
  end

  defp nper_with_rate(rate, pmt, pv, fv, type) do
    k = pmt * (1 + rate * type) / rate
    denom = pv + k

    cond do
      denom == 0 -> {:error, :undefined}
      (k - fv) / denom <= 0 -> {:error, :undefined}
      true -> {:ok, :math.log((k - fv) / denom) / :math.log(1 + rate)}
    end
  end

  # Represent a TVM problem as a cash-flow series so `rate` can reuse the solver:
  # `pv` at period 0, `pmt` each period, `fv` at the last period.
  defp tvm_flows(nper, pmt, pv, fv, type) do
    payment_periods = if type == 1, do: 0..(nper - 1), else: 1..nper

    payment_periods
    |> Enum.reduce(%{}, fn i, acc -> Map.update(acc, i * 1.0, pmt * 1.0, &(&1 + pmt)) end)
    |> Map.update(0.0, pv * 1.0, &(&1 + pv))
    |> Map.update(nper * 1.0, fv * 1.0, &(&1 + fv))
    |> Map.to_list()
  end

  # === Depreciation ========================================================
  #
  # An asset of `cost` is written down to `salvage` over `life` periods. `sln`
  # spreads the loss evenly; `syd`, `ddb`, and `db` are accelerated methods that
  # depreciate more early on and return the amount for a single `period` (1-based).

  @doc """
  Computes straight-line depreciation: the equal amount an asset is written down
  by each period as it declines from its `cost` to its `salvage` value over
  `life` periods.

  This is the plainest of the depreciation methods — it spreads the loss in
  value evenly, so every period sees the same write-down.

      iex> Finance.sln(10_000, 1_000, 5)
      {:ok, 1800.0}
  """
  @spec sln(number, number, number) :: {:ok, float} | {:error, error}
  def sln(cost, salvage, life)
      when is_number(cost) and is_number(salvage) and is_number(life) do
    if life == 0 do
      {:error, :undefined}
    else
      {:ok, (cost - salvage) / life * 1.0}
    end
  end

  @doc "Same as `sln/3`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec sln!(number, number, number) :: float
  def sln!(cost, salvage, life), do: cost |> sln(salvage, life) |> unwrap!()

  @doc """
  Computes sum-of-years'-digits depreciation for a single `period` (counting from
  1).

  This is an accelerated method: it charges more depreciation in the early
  periods and less later on, which suits assets that lose most of their value up
  front. It returns the write-down for the one `period` you ask about rather than
  the whole schedule.

      iex> Finance.syd(10_000, 1_000, 5, 1)
      {:ok, 3000.0}

      iex> Finance.syd(10_000, 1_000, 5, 5)
      {:ok, 600.0}
  """
  @spec syd(number, number, number, number) :: {:ok, float} | {:error, error}
  def syd(cost, salvage, life, period)
      when is_number(cost) and is_number(salvage) and is_number(life) and is_number(period) do
    if life <= 0 or period < 1 or period > life do
      {:error, :undefined}
    else
      {:ok, (cost - salvage) * (life - period + 1) * 2 / (life * (life + 1)) * 1.0}
    end
  end

  @doc "Same as `syd/4`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec syd!(number, number, number, number) :: float
  def syd!(cost, salvage, life, period), do: cost |> syd(salvage, life, period) |> unwrap!()

  @doc """
  Computes double-declining-balance depreciation for a single `period`.

  This is another accelerated method: each period it takes a fixed fraction of
  the remaining book value, so the write-down shrinks as the asset ages. The
  `factor` sets how aggressive that fraction is, defaulting to `2` for the usual
  double-declining rate. The depreciation is capped so it never drives the book
  value below `salvage`.

      iex> Finance.ddb(10_000, 1_000, 5, 1)
      {:ok, 4000.0}

      iex> Finance.ddb(10_000, 1_000, 5, 2)
      {:ok, 2400.0}
  """
  @spec ddb(number, number, number, number, number) :: {:ok, float} | {:error, error}
  def ddb(cost, salvage, life, period, factor \\ 2)
      when is_number(cost) and is_number(salvage) and is_number(life) and is_number(period) and
             is_number(factor) do
    n = trunc(period)

    if ddb_valid?(life, factor, period, n) do
      {:ok, declining_balance(cost, salvage, factor / life, n)}
    else
      {:error, :undefined}
    end
  end

  defp ddb_valid?(life, factor, period, n) do
    life > 0 and factor > 0 and period == n and n >= 1 and n <= life
  end

  @doc "Same as `ddb/5`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec ddb!(number, number, number, number, number) :: float
  def ddb!(cost, salvage, life, period, factor \\ 2) do
    cost |> ddb(salvage, life, period, factor) |> unwrap!()
  end

  @doc """
  Computes fixed-declining-balance depreciation for a single `period`.

  Like `ddb/5`, this applies a constant rate to the declining book value, but the
  rate is derived directly from `cost`, `salvage`, and `life` (and rounded to
  three decimal places, matching what spreadsheets do). Use `month` to say how
  many months the asset was in service during its first year; it defaults to a
  full `12`, and a shorter first year spills the remaining depreciation into an
  extra final period.

      iex> Finance.db(10_000, 1_000, 5, 1)
      {:ok, 3690.0}

      iex> Finance.db(10_000, 1_000, 5, 2)
      {:ok, 2328.39}
  """
  @spec db(number, number, number, number, number) :: {:ok, float} | {:error, error}
  def db(cost, salvage, life, period, month \\ 12)
      when is_number(cost) and is_number(salvage) and is_number(life) and is_number(period) and
             is_number(month) do
    n = trunc(period)

    if db_valid?(cost, salvage, life, month, period, n) do
      {:ok, fixed_declining(cost, salvage, life, n, month)}
    else
      {:error, :undefined}
    end
  end

  @doc "Same as `db/5`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
  @spec db!(number, number, number, number, number) :: float
  def db!(cost, salvage, life, period, month \\ 12) do
    cost |> db(salvage, life, period, month) |> unwrap!()
  end

  defp db_valid?(cost, salvage, life, month, period, n) do
    cost > 0 and salvage >= 0 and life > 0 and month >= 1 and month <= 12 and
      period == n and n >= 1 and n <= life + 1
  end

  # Walk periods 1..period, carrying accumulated depreciation, and return the
  # amount for the final period. Depreciation stops at the salvage floor.
  defp declining_balance(cost, salvage, rate, period) do
    Enum.reduce(1..period, {0.0, 0.0}, fn _p, {accumulated, _dep} ->
      book = cost - accumulated
      dep = max(min(book * rate, book - salvage), 0.0)
      {accumulated + dep, dep}
    end)
    |> elem(1)
  end

  defp fixed_declining(cost, salvage, life, period, month) do
    rate = Float.round(1 - :math.pow(salvage / cost, 1 / life), 3)

    Enum.reduce(1..period, {0.0, 0.0}, fn p, {accumulated, _dep} ->
      dep = db_period(cost, accumulated, rate, life, month, p)
      {accumulated + dep, dep}
    end)
    |> elem(1)
  end

  defp db_period(cost, _accumulated, rate, _life, month, 1), do: cost * rate * month / 12

  defp db_period(cost, accumulated, rate, life, month, period) do
    if period <= life do
      (cost - accumulated) * rate
    else
      # The partial last period when the first year was shorter than 12 months.
      (cost - accumulated) * rate * (12 - month) / 12
    end
  end

  # === Volatility ==========================================================

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

      iex> Finance.volatility([100, 102, 101, 103, 105])
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

  # === Dispatch & shared helpers ===========================================

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
      solve(flows, opts)
    end
  end

  # Validate options against the schema, applying defaults. Raises
  # `NimbleOptions.ValidationError` on an unknown key or bad value.
  defp options(opts), do: NimbleOptions.validate!(opts, @options_schema)

  # `+ 0.0` collapses a floating-point negative zero to `0.0`.
  defp round_value(value, opts) do
    Float.round(value, Keyword.fetch!(opts, :precision)) + 0.0
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: raise(ArgumentError, "could not compute: #{reason}")

  # --- Normalization -------------------------------------------------------

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

  # Coerce a cash-flow amount to a float. Accepts plain numbers and, when the
  # optional Decimal dependency is present, `%Decimal{}` values. Shared by every
  # normalizer so the whole function family accepts the same inputs.
  defp to_amount(%Decimal{} = amount), do: Decimal.to_float(amount)
  defp to_amount(amount) when is_number(amount), do: amount / 1

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

  # --- Solver --------------------------------------------------------------

  defp solve(flows, opts) do
    guess = Keyword.fetch!(opts, :guess)
    tolerance = Keyword.fetch!(opts, :tolerance)
    max_iterations = Keyword.fetch!(opts, :max_iterations)

    result =
      case newton(flows, guess, max_iterations, tolerance) do
        {:ok, rate} -> {:ok, rate}
        :diverged -> bisect(flows, max_iterations, tolerance)
      end

    case result do
      {:ok, rate} -> {:ok, Float.round(rate, Keyword.fetch!(opts, :precision))}
      :diverged -> {:error, :did_not_converge}
    end
  rescue
    ArithmeticError -> {:error, :did_not_converge}
  end

  defp newton(_flows, _rate, 0, _tol), do: :diverged

  defp newton(flows, rate, iterations, tol) do
    f = present_value(flows, rate)
    derivative = present_value_derivative(flows, rate)

    cond do
      abs(f) < tol -> {:ok, rate}
      derivative == 0.0 -> :diverged
      true -> newton_step(flows, rate, rate - f / derivative, iterations, tol)
    end
  end

  defp newton_step(flows, rate, next, iterations, tol) do
    cond do
      # A Newton step outside the (-1, ∞) domain: halve the distance to -1.
      next <= -1.0 -> newton(flows, (rate - 1.0) / 2.0, iterations - 1, tol)
      abs(next - rate) < tol -> {:ok, next}
      true -> newton(flows, next, iterations - 1, tol)
    end
  end

  defp bisect(flows, max_iterations, tol) do
    low = -0.999999

    case bracket(flows, low, present_value(flows, low), 1.0) do
      {:ok, low, high} -> {:ok, bisection(flows, low, high, max_iterations, tol)}
      :diverged -> :diverged
    end
  end

  # Expand the upper bound until the NPV changes sign, giving us a bracket.
  defp bracket(_flows, _low, _f_low, high) when high > 1.0e7, do: :diverged

  defp bracket(flows, low, f_low, high) do
    if f_low * present_value(flows, high) <= 0 do
      {:ok, low, high}
    else
      bracket(flows, low, f_low, high * 2 + 1)
    end
  end

  defp bisection(_flows, low, high, 0, _tol), do: (low + high) / 2

  defp bisection(flows, low, high, iterations, tol) do
    mid = (low + high) / 2
    f_mid = present_value(flows, mid)

    cond do
      abs(f_mid) < tol or high - low < tol -> mid
      present_value(flows, low) * f_mid < 0 -> bisection(flows, low, mid, iterations - 1, tol)
      true -> bisection(flows, mid, high, iterations - 1, tol)
    end
  end

  # Net present value: Σ amount / (1 + rate)^t
  defp present_value(flows, rate) do
    Enum.reduce(flows, 0.0, fn {t, amount}, acc ->
      acc + amount / :math.pow(1 + rate, t)
    end)
  end

  # Derivative of the NPV with respect to rate: Σ -t · amount / (1 + rate)^(t+1)
  defp present_value_derivative(flows, rate) do
    Enum.reduce(flows, 0.0, fn {t, amount}, acc ->
      acc + -t * amount / :math.pow(1 + rate, t + 1)
    end)
  end
end
