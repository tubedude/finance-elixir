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
  Cash-flow analysis: internal rate of return, net present value, and modified IRR.

  Functions come in two flavours:

    * **Dated** — `xirr/2` and `xnpv/2` take `{date, amount}` flows at arbitrary
      dates and discount on an Actual/365 basis, matching the spreadsheet
      `XIRR`/`XNPV` convention.
    * **Periodic** — `irr/1`, `npv/2`, and `mirr/3` take a bare list of amounts
      at equally spaced periods `0, 1, 2, …`.
    * **Time-value-of-money** — `fv/5`, `pv/5`, `pmt/5`, `nper/5`, and `rate/6`
      each solve the annuity equation for one unknown.
    * **Depreciation** — `sln/3`, `syd/4`, `ddb/5`, and `db/5` write an asset
      down from cost to salvage over its life.

  The flagship is XIRR, the rate `r` that zeroes the net present value of dated
  flows:

      Σ cf_i / (1 + r)^t_i = 0

  where `t_i` is the number of years from the earliest flow. The solver uses
  Newton-Raphson (fast, analytic derivative) with a bracketing bisection
  fallback when Newton leaves the valid domain or fails to converge; it follows
  the spreadsheet `XIRR` conventions (Actual/365, a `0.1` initial guess, a
  100-iteration cap).

  ## Example

      iex> Finance.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
      {:ok, 0.1}

  Dated flows may be `{date, amount}` pairs or two parallel lists; dates may be
  `Date` structs or Erlang-style `{year, month, day}` tuples. Amounts may be any
  number (integer minor units such as cents, or floats) or a `Decimal` when that
  optional dependency is installed — results are always floats. Options are
  validated with `nimble_options`; `Decimal` support is optional.

  ## Options

  The rate-finding and value functions accept a keyword list. Invalid options
  raise (they are a caller error), while data problems return `{:error, reason}`.

  #{NimbleOptions.docs(@options_schema)}
  """

  @typedoc "A `Date` struct or an Erlang-style `{year, month, day}` tuple."
  @type date :: Date.t() | {integer, integer, integer}

  @typedoc "A cash-flow amount: any number, or a `Decimal` if that optional dependency is installed."
  @type amount :: number | Decimal.t()

  @typedoc "A dated cash flow. Positive amounts are inflows, negative are outflows."
  @type cash_flow :: {date, amount}

  @typedoc "An annual rate of return, e.g. `0.1` for 10%."
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
  Calculates the XIRR for a list of `{date, amount}` cash flows.

  See `xirr/2` for options and the two-list form.

      iex> Finance.xirr([{~D[2015-06-01], 1_000_000}, {~D[2015-10-01], -2_200_000}, {~D[2015-11-01], -800_000}])
      {:ok, 21.118359}
  """
  @spec xirr([cash_flow]) :: {:ok, rate} | {:error, error}
  def xirr(cash_flows) when is_list(cash_flows), do: xirr(cash_flows, [])

  @doc """
  Calculates the XIRR, either from `{date, amount}` pairs plus options, or from
  two parallel lists of dates and amounts.

  Returns `{:ok, rate}` or `{:error, reason}`. Flows on the same date are
  combined; the series must contain at least one positive and one negative
  amount, otherwise no rate exists.

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
  Calculates the XIRR from two parallel lists of dates and amounts, with options.

      iex> Finance.xirr([~D[2019-01-01], ~D[2020-01-01]], [-1000, 1100], precision: 2)
      {:ok, 0.1}
  """
  @spec xirr([date], [amount], [option]) :: {:ok, rate} | {:error, error}
  def xirr(dates, values, opts)
      when is_list(dates) and is_list(values) and is_list(opts) do
    zip(dates, values, opts)
  end

  @doc "Like `xirr/1`, but returns the rate directly and raises `ArgumentError` on error."
  @spec xirr!([cash_flow]) :: rate
  def xirr!(cash_flows), do: cash_flows |> xirr() |> unwrap!()

  @doc "Like `xirr/2`, but returns the rate directly and raises `ArgumentError` on error."
  @spec xirr!([cash_flow] | [date], [option] | [amount]) :: rate
  def xirr!(first, second), do: first |> xirr(second) |> unwrap!()

  # === XNPV — net present value of dated flows =============================

  @doc """
  Calculates the **XNPV** — the net present value of dated cash flows discounted
  at `rate`.

      Σ cf_i / (1 + rate)^t_i

  Times `t_i` are years from the earliest flow (Actual/365), the same
  convention `xirr/2` uses — so `xnpv(r, flows)` is `~0` at `r = xirr(flows)`,
  which makes it a natural way to verify an XIRR result. Unlike `xirr/2`, the
  flows need not change sign; NPV is defined for any series.

  Returns `{:ok, value}` or `{:error, reason}`. Flows on the same date are
  combined. Accepts the same `:precision` option as `xirr/2` (default `6`).

      iex> Finance.xnpv(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1000}])
      {:ok, -90.909091}

      iex> Finance.xnpv(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
      {:ok, 0.0}
  """
  @spec xnpv(rate, [cash_flow]) :: {:ok, number} | {:error, error}
  def xnpv(rate, cash_flows) when is_number(rate) and is_list(cash_flows) do
    xnpv(rate, cash_flows, [])
  end

  @doc "Like `xnpv/2`, but accepts a `:precision` option. See `xnpv/2`."
  @spec xnpv(rate, [cash_flow], [option]) :: {:ok, number} | {:error, error}
  def xnpv(rate, cash_flows, opts)
      when is_number(rate) and is_list(cash_flows) and is_list(opts) do
    opts = options(opts)

    with {:ok, flows} <- normalize(cash_flows) do
      {:ok, round_value(present_value(flows, rate), opts)}
    end
  end

  @doc "Like `xnpv/2`, but returns the value directly and raises `ArgumentError` on error."
  @spec xnpv!(rate, [cash_flow]) :: number
  def xnpv!(rate, cash_flows), do: rate |> xnpv(cash_flows) |> unwrap!()

  # === IRR — internal rate of return for periodic flows ====================

  @doc """
  Calculates the **IRR** — the internal rate of return for amounts at equally
  spaced periods `0, 1, 2, …`. The periodic counterpart of `xirr/2`.

  The result is the per-period rate. The series must contain at least one
  positive and one negative amount.

      iex> Finance.irr([-1000, 1100])
      {:ok, 0.1}

      iex> Finance.irr([-1000, 500, 500, 300])
      {:ok, 0.156579}
  """
  @spec irr([amount]) :: {:ok, rate} | {:error, error}
  def irr(amounts) when is_list(amounts), do: irr(amounts, [])

  @doc "Like `irr/1`, but accepts the same options as `xirr/2`."
  @spec irr([amount], [option]) :: {:ok, rate} | {:error, error}
  def irr(amounts, opts) when is_list(amounts) and is_list(opts) do
    opts = options(opts)
    flows = periodic_flows(amounts)

    with :ok <- validate(flows) do
      solve(flows, opts)
    end
  end

  @doc "Like `irr/1`, but returns the rate directly and raises `ArgumentError` on error."
  @spec irr!([amount], [option]) :: rate
  def irr!(amounts, opts \\ []), do: amounts |> irr(opts) |> unwrap!()

  # === NPV — net present value of periodic flows ===========================

  @doc """
  Calculates the periodic **NPV** — the net present value of `amounts` at
  equally spaced periods `0, 1, 2, …` discounted at `rate`.

      Σ amount_i / (1 + rate)^i    (i starting at 0)

  > #### Convention {: .info}
  > The first amount sits at period 0 (undiscounted), so `npv(irr(a), a)` is
  > `~0`. This differs from spreadsheet `NPV`, which places the first amount at
  > period 1; to match a spreadsheet, discount the first amount yourself or pass
  > it with a leading `0`.

      iex> Finance.npv(0.1, [-1000, 1100])
      {:ok, 0.0}

      iex> Finance.npv(0.1, [-1000, 600, 600])
      {:ok, 41.322314}
  """
  @spec npv(rate, [amount]) :: {:ok, number} | {:error, error}
  def npv(rate, amounts) when is_number(rate) and is_list(amounts) do
    npv(rate, amounts, [])
  end

  @doc "Like `npv/2`, but accepts a `:precision` option. See `npv/2`."
  @spec npv(rate, [amount], [option]) :: {:ok, number} | {:error, error}
  def npv(_rate, [], _opts), do: {:error, :insufficient_data}

  def npv(rate, amounts, opts)
      when is_number(rate) and is_list(amounts) and is_list(opts) do
    opts = options(opts)
    {:ok, round_value(present_value(periodic_flows(amounts), rate), opts)}
  end

  @doc "Like `npv/2`, but returns the value directly and raises `ArgumentError` on error."
  @spec npv!(rate, [amount]) :: number
  def npv!(rate, amounts), do: rate |> npv(amounts) |> unwrap!()

  # === MIRR — modified internal rate of return =============================

  @doc """
  Calculates the **MIRR** — the modified internal rate of return for periodic
  `amounts`, where positive flows are reinvested at `reinvest_rate` and negative
  flows are financed at `finance_rate`.

  Unlike `irr/1`, MIRR is a closed-form calculation with a single answer, so it
  sidesteps the multiple-root and convergence problems IRR can hit. The series
  must contain at least one positive and one negative amount.

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

  @doc "Like `mirr/3`, but returns the rate directly and raises `ArgumentError` on error."
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
  Future value of an investment with present value `pv` and fixed payment `pmt`
  per period, after `nper` periods at interest `rate`.

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

  @doc "Like `fv/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec fv!(number, number, number, number, 0 | 1) :: float
  def fv!(rate, nper, pmt, pv \\ 0.0, type \\ 0), do: rate |> fv(nper, pmt, pv, type) |> unwrap!()

  @doc """
  Present value of an investment that pays `pmt` per period for `nper` periods
  and a lump sum `fv` at the end, discounted at `rate`.

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

  @doc "Like `pv/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec pv!(number, number, number, number, 0 | 1) :: float
  def pv!(rate, nper, pmt, fv \\ 0.0, type \\ 0), do: rate |> pv(nper, pmt, fv, type) |> unwrap!()

  @doc """
  Payment per period that pays off present value `pv` (and reaches future value
  `fv`) over `nper` periods at `rate`.

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

  @doc "Like `pmt/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec pmt!(number, number, number, number, 0 | 1) :: float
  def pmt!(rate, nper, pv, fv \\ 0.0, type \\ 0), do: rate |> pmt(nper, pv, fv, type) |> unwrap!()

  @doc """
  Number of periods needed for payments of `pmt` to pay off present value `pv`
  (reaching future value `fv`) at `rate`.

  Returns `{:error, :undefined}` when no such number of periods exists.

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

  @doc "Like `nper/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec nper!(number, number, number, number, 0 | 1) :: float
  def nper!(rate, pmt, pv, fv \\ 0.0, type \\ 0), do: rate |> nper(pmt, pv, fv, type) |> unwrap!()

  @doc """
  Interest rate per period of an annuity: `nper` payments of `pmt`, a present
  value `pv`, and a future value `fv`. `nper` must be a whole number of periods.

  Solved iteratively (reusing the `irr` solver), so it accepts the same options
  as `xirr/2` and returns `{:error, :did_not_converge}` if no rate is found.

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

  @doc "Like `rate/6`, but returns the rate directly and raises `ArgumentError` on error."
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
  Straight-line depreciation: the equal per-period write-down of an asset from
  `cost` to `salvage` over `life` periods.

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

  @doc "Like `sln/3`, but returns the value directly and raises `ArgumentError` on error."
  @spec sln!(number, number, number) :: float
  def sln!(cost, salvage, life), do: cost |> sln(salvage, life) |> unwrap!()

  @doc """
  Sum-of-years'-digits depreciation for `period` (1-based), an accelerated method.

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

  @doc "Like `syd/4`, but returns the value directly and raises `ArgumentError` on error."
  @spec syd!(number, number, number, number) :: float
  def syd!(cost, salvage, life, period), do: cost |> syd(salvage, life, period) |> unwrap!()

  @doc """
  Double-declining-balance depreciation for `period`. `factor` is the decline
  rate multiplier (default `2` for double-declining). Depreciation never takes
  the book value below `salvage`.

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

    if life > 0 and factor > 0 and period == n and n >= 1 and n <= life do
      {:ok, declining_balance(cost, salvage, factor / life, n)}
    else
      {:error, :undefined}
    end
  end

  @doc "Like `ddb/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec ddb!(number, number, number, number, number) :: float
  def ddb!(cost, salvage, life, period, factor \\ 2) do
    cost |> ddb(salvage, life, period, factor) |> unwrap!()
  end

  @doc """
  Fixed-declining-balance depreciation for `period`, using a rate derived from
  `cost`, `salvage`, and `life` (rounded to three places, as spreadsheets do).
  `month` is the number of months in the first year (default `12`).

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

  @doc "Like `db/5`, but returns the value directly and raises `ArgumentError` on error."
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
