defmodule Finance.TVM do
  @moduledoc """
  Time-value-of-money scalars: `fv/5`, `pv/5`, `pmt/5`, `nper/5`, and `rate/6`.

  Each solves the standard annuity equation for one unknown:

      pv·(1+r)^n + pmt·(1 + r·type)·((1+r)^n − 1)/r + fv = 0

  `type` is `0` for payments at the end of each period (ordinary annuity) or `1`
  for the beginning (annuity due). The sign convention follows spreadsheets:
  money you receive is positive, money you pay out is negative.
  """

  import Finance.Shared, only: [unwrap!: 1, options: 1, resolve_solver: 1]

  @type rate :: Finance.rate()
  @type option :: Finance.option()
  @type error :: Finance.error()

  @typedoc """
  A row of an amortization schedule; monetary fields follow the `pmt/5` sign
  convention and are `Decimal` when the schedule is built from `Decimal` inputs.
  """
  @type schedule_row :: %{
          period: pos_integer,
          payment: float | Decimal.t(),
          interest: float | Decimal.t(),
          principal: float | Decimal.t(),
          balance: float | Decimal.t()
        }

  @schedule_options_schema NimbleOptions.new!(
                             precision: [
                               type: :non_neg_integer,
                               default: 2,
                               doc: "decimal places each monetary column is rounded to"
                             ]
                           )

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

      iex> {:ok, value} = Finance.TVM.fv(0.05, 10, -100, -1000)
      iex> Float.round(value, 2)
      2886.68
  """
  @spec fv(number, number, number, number, 0 | 1) :: {:ok, float} | {:error, error}
  def fv(rate, nper, pmt, pv \\ 0.0, type \\ 0)
      when is_number(rate) and is_number(nper) and is_number(pmt) and is_number(pv) and
             type in [0, 1] do
    cond do
      rate == 0 -> {:ok, -(pv + pmt * nper) + 0.0}
      1 + rate <= 0 -> {:error, :undefined}
      true -> {:ok, -(pv * :math.pow(1 + rate, nper) + pmt * annuity(rate, nper, type)) + 0.0}
    end
  end

  @doc "Same as `fv/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec fv!(number, number, number, number, 0 | 1) :: float
  def fv!(rate, nper, pmt, pv \\ 0.0, type \\ 0), do: rate |> fv(nper, pmt, pv, type) |> unwrap!()

  @doc """
  Works out the present value of an investment: what a future stream is worth
  today. The stream is `pmt` paid each period for `nper` periods plus a lump sum
  `fv` at the end, all discounted back at `rate`.

  It answers the mirror image of `fv/5`'s question — "how much would I need to
  put in now to fund these future payments?". The same `type` and sign
  conventions apply.

      iex> {:ok, value} = Finance.TVM.pv(0.05, 10, -100, -1000)
      iex> Float.round(value, 2)
      1386.09
  """
  @spec pv(number, number, number, number, 0 | 1) :: {:ok, float} | {:error, error}
  def pv(rate, nper, pmt, fv \\ 0.0, type \\ 0)
      when is_number(rate) and is_number(nper) and is_number(pmt) and is_number(fv) and
             type in [0, 1] do
    cond do
      rate == 0 -> {:ok, -(fv + pmt * nper) + 0.0}
      1 + rate <= 0 -> {:error, :undefined}
      true -> {:ok, -(fv + pmt * annuity(rate, nper, type)) / :math.pow(1 + rate, nper) + 0.0}
    end
  end

  @doc "Same as `pv/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec pv!(number, number, number, number, 0 | 1) :: float
  def pv!(rate, nper, pmt, fv \\ 0.0, type \\ 0), do: rate |> pv(nper, pmt, fv, type) |> unwrap!()

  @doc """
  Works out the level payment per period needed to pay off a present value `pv`
  (and arrive at a future value `fv`) over `nper` periods at `rate`.

  This is the loan-payment question: given an amount borrowed today, what fixed
  installment clears it over the term? The same `type` and sign conventions
  apply, so a loan you take out is a positive `pv` and the payment comes back
  negative.

      iex> {:ok, payment} = Finance.TVM.pmt(0.10, 10, 1000)
      iex> Float.round(payment, 2)
      -162.75
  """
  @spec pmt(number, number, number, number, 0 | 1) :: {:ok, float} | {:error, error}
  def pmt(rate, nper, pv, fv \\ 0.0, type \\ 0)
      when is_number(rate) and is_number(nper) and is_number(pv) and is_number(fv) and
             type in [0, 1] do
    cond do
      nper == 0 -> {:error, :undefined}
      rate == 0 -> {:ok, -(pv + fv) / nper + 0.0}
      1 + rate <= 0 -> {:error, :undefined}
      true -> {:ok, -(pv * :math.pow(1 + rate, nper) + fv) / annuity(rate, nper, type) + 0.0}
    end
  end

  @doc "Same as `pmt/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec pmt!(number, number, number, number, 0 | 1) :: float
  def pmt!(rate, nper, pv, fv \\ 0.0, type \\ 0), do: rate |> pmt(nper, pv, fv, type) |> unwrap!()

  @doc """
  Works out the interest portion of the payment in period `per` — how much of
  that period's fixed payment goes to interest rather than to principal.

  `per` counts from 1 and must fall within `1..nper`. It pairs with `ppmt/6`,
  which gives the principal portion; for every period the two add up to `pmt/5`.

      iex> {:ok, interest} = Finance.TVM.ipmt(0.10 / 12, 1, 12, 1000)
      iex> Float.round(interest, 6)
      -8.333333
  """
  @spec ipmt(number, number, number, number, number, 0 | 1) :: {:ok, float} | {:error, error}
  def ipmt(rate, per, nper, pv, fv \\ 0.0, type \\ 0)
      when is_number(rate) and is_number(per) and is_number(nper) and is_number(pv) and
             is_number(fv) and type in [0, 1] do
    with {:ok, {interest, _principal}} <- split_payment(rate, per, nper, pv, fv, type) do
      {:ok, interest}
    end
  end

  @doc "Same as `ipmt/6`, but returns the value directly and raises `ArgumentError` on error."
  @spec ipmt!(number, number, number, number, number, 0 | 1) :: float
  def ipmt!(rate, per, nper, pv, fv \\ 0.0, type \\ 0) do
    rate |> ipmt(per, nper, pv, fv, type) |> unwrap!()
  end

  @doc """
  Works out the principal portion of the payment in period `per` — how much of
  that period's fixed payment actually pays down the balance.

  `per` counts from 1 and must fall within `1..nper`. It is the companion of
  `ipmt/6`; `ipmt` plus `ppmt` equals `pmt/5` for every period.

      iex> {:ok, principal} = Finance.TVM.ppmt(0.10 / 12, 1, 12, 1000)
      iex> Float.round(principal, 6)
      -79.582554
  """
  @spec ppmt(number, number, number, number, number, 0 | 1) :: {:ok, float} | {:error, error}
  def ppmt(rate, per, nper, pv, fv \\ 0.0, type \\ 0)
      when is_number(rate) and is_number(per) and is_number(nper) and is_number(pv) and
             is_number(fv) and type in [0, 1] do
    with {:ok, {_interest, principal}} <- split_payment(rate, per, nper, pv, fv, type) do
      {:ok, principal}
    end
  end

  @doc "Same as `ppmt/6`, but returns the value directly and raises `ArgumentError` on error."
  @spec ppmt!(number, number, number, number, number, 0 | 1) :: float
  def ppmt!(rate, per, nper, pv, fv \\ 0.0, type \\ 0) do
    rate |> ppmt(per, nper, pv, fv, type) |> unwrap!()
  end

  # Split period `per`'s level payment into {interest, principal}, reusing pmt/fv.
  # `per` must be a whole number within 1..nper.
  defp split_payment(rate, per, nper, pv, fv, type) do
    n = trunc(per)

    if per == n and n >= 1 and n <= nper do
      with {:ok, payment} <- pmt(rate, nper, pv, fv, type) do
        {:ok, balance} = fv(rate, n - 1, payment, pv, type)
        interest = annuity_due_adjust(balance * rate, rate, n, type)
        # `+ 0.0` collapses a floating-point negative zero to `0.0`.
        {:ok, {interest + 0.0, payment - interest + 0.0}}
      end
    else
      {:error, :undefined}
    end
  end

  # For an annuity due (type 1), the first period carries no interest and later
  # periods discount one step; an ordinary annuity (type 0) is left as-is.
  defp annuity_due_adjust(_interest, _rate, 1, 1), do: 0.0
  defp annuity_due_adjust(interest, rate, _per, 1), do: interest / (1 + rate)
  defp annuity_due_adjust(interest, _rate, _per, 0), do: interest

  @doc """
  Builds the full amortization schedule for a loan of `pv` repaid with a level
  payment over `nper` periods at `rate`.

  Returns `{:ok, rows}` where each row is a map of `period`, `payment`,
  `interest`, `principal`, and remaining `balance`. Money follows the `pmt/5`
  sign convention (a loan is a positive `pv`, its payments are negative), and the
  `balance` runs from `pv` down to exactly `0.0` — the final row absorbs any
  rounding residual so the loan pays off cleanly.

  Each monetary column is rounded to `:precision` places, which defaults to `2`
  (cents) rather than the `6` used elsewhere, since a schedule is a money table.

  The schedule is computed in integer minor units (10^`:precision`), so every
  row is exact to the requested precision and the balance ends at exactly zero.
  If `rate` or `pv` is a `Decimal`, the monetary fields come back as `Decimal`;
  otherwise they come back as floats.

      iex> {:ok, [first | _]} = Finance.TVM.amortization_schedule(0.10 / 12, 12, 1000)
      iex> {first.payment, first.interest, first.principal, first.balance}
      {-87.92, -8.33, -79.59, 920.41}
  """
  @spec amortization_schedule(
          number | Decimal.t(),
          pos_integer,
          number | Decimal.t(),
          [{:precision, non_neg_integer}]
        ) :: {:ok, [schedule_row]} | {:error, error}
  def amortization_schedule(rate, nper, pv, opts \\ [])
      when (is_number(rate) or is_struct(rate, Decimal)) and is_number(nper) and
             (is_number(pv) or is_struct(pv, Decimal)) and is_list(opts) do
    opts = NimbleOptions.validate!(opts, @schedule_options_schema)
    n = trunc(nper)

    if valid_loan?(nper, n, pv, rate) do
      {:ok, build_schedule(rate, n, pv, Keyword.fetch!(opts, :precision))}
    else
      {:error, :undefined}
    end
  end

  # A loan is a whole number of periods with a positive `pv` at a rate above -100%.
  # Outside that the level payment and the balance clamp are undefined (and `pmt`
  # can divide by zero), so the schedule is rejected rather than returned wrong.
  defp valid_loan?(nper, n, pv, rate) do
    nper == n and n >= 1 and to_float(pv) > 0.0 and to_float(rate) > -1.0
  end

  @doc "Same as `amortization_schedule/4`, but returns the rows directly and raises `ArgumentError` on error."
  @spec amortization_schedule!(
          number | Decimal.t(),
          pos_integer,
          number | Decimal.t(),
          [{:precision, non_neg_integer}]
        ) :: [schedule_row]
  def amortization_schedule!(rate, nper, pv, opts \\ []) do
    rate |> amortization_schedule(nper, pv, opts) |> unwrap!()
  end

  # Compute the schedule once in integer minor units (10^precision, e.g. cents at
  # precision 2). Money is then exact and only the interest (balance × rate) ever
  # needs rounding — everything else is integer add/subtract. The rows are
  # converted back to floats, or to `Decimal` when the inputs were `Decimal`.
  # This is exact to the requested precision and faster than working in either
  # floats or `Decimal`.
  defp build_schedule(rate, nper, pv, precision) do
    decimal? = is_struct(rate, Decimal) or is_struct(pv, Decimal)
    scale = Integer.pow(10, precision)
    rate = to_float(rate)
    pv = to_float(pv)
    {:ok, payment} = pmt(rate, nper, pv)

    convert = if decimal?, do: &units_to_decimal(&1, scale), else: &(&1 / scale)

    rate
    |> integer_schedule(nper, round(pv * scale), round(payment * scale))
    |> Enum.map(&convert_row(&1, convert))
  end

  defp convert_row({period, payment, interest, principal, balance}, convert) do
    %{
      period: period,
      payment: convert.(payment),
      interest: convert.(interest),
      principal: convert.(principal),
      balance: convert.(balance)
    }
  end

  # Running balance in integer minor units; the final row pays off whatever
  # remains, so the balance ends at exactly 0.
  defp integer_schedule(rate, nper, opening, payment) do
    {rows, _balance} =
      Enum.map_reduce(1..nper, opening, fn period, balance ->
        interest = round(-balance * rate)
        scheduled = if period == nper, do: -balance, else: payment - interest
        # Keep the balance retiring toward zero within `[0, opening]`. Once
        # `(1 + rate)^nper` is large, a cent-rounded level payment no longer tames
        # the balance: rounded a hair high it overshoots below zero, a hair low it
        # grows the balance back (negative amortization). Both are amplified period
        # over period. Clamping keeps every schedule monotonic and bounded, with a
        # final row that clears whatever remains.
        principal = clamp_to_balance(scheduled, balance)
        new_balance = balance + principal
        {{period, interest + principal, interest, principal, new_balance}, new_balance}
      end)

    rows
  end

  # Bound the principal to `[-balance, 0]`: never grow the balance (`min(_, 0)`)
  # and never pay off more than is owed (`max(_, -balance)`), so it moves toward
  # zero without overshooting. A normal amortizing payment already falls in range.
  defp clamp_to_balance(scheduled, balance), do: scheduled |> max(-balance) |> min(0)

  defp units_to_decimal(units, scale), do: Decimal.div(Decimal.new(units), scale)

  defp to_float(value) when is_number(value), do: value * 1.0
  defp to_float(value) when is_struct(value, Decimal), do: Decimal.to_float(value)

  @doc """
  Works out how many periods it takes for payments of `pmt` to pay off a present
  value `pv` (reaching future value `fv`) at `rate`.

  This is the "how long until it's paid off?" question. When the numbers don't
  describe a situation that ever resolves, it returns `{:error, :undefined}`.

      iex> {:ok, periods} = Finance.TVM.nper(0.05, -100, 1000)
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

  @doc "Same as `nper/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec nper!(number, number, number, number, 0 | 1) :: float
  def nper!(rate, pmt, pv, fv \\ 0.0, type \\ 0), do: rate |> nper(pmt, pv, fv, type) |> unwrap!()

  @doc """
  Works out the interest rate per period of an annuity described by `nper`
  payments of `pmt`, a present value `pv`, and a future value `fv`. `nper` has to
  be a whole number of periods.

  There is no closed form for the rate, so this reuses the same numerical solver
  as `Finance.CashFlow.irr/1` and takes the same options. If it can't pin down a
  rate, it returns `{:error, :did_not_converge}`.

      iex> Finance.TVM.rate(10, -100, 1000)
      {:ok, 0.0}
  """
  @spec rate(number, number, number, number, 0 | 1, [option]) :: {:ok, rate} | {:error, error}
  def rate(nper, pmt, pv, fv \\ 0.0, type \\ 0, opts \\ [])
      when is_number(nper) and is_number(pmt) and is_number(pv) and is_number(fv) and
             type in [0, 1] and is_list(opts) do
    n = trunc(nper)

    if nper == n and n > 0 do
      opts = options(opts)
      resolve_solver(opts).solve(tvm_flows(n, pmt, pv, fv, type), opts)
    else
      {:error, :undefined}
    end
  end

  @doc "Same as `rate/6`, but returns the rate directly and raises `ArgumentError` on error."
  @spec rate!(number, number, number, number, 0 | 1, [option]) :: rate
  def rate!(nper, pmt, pv, fv \\ 0.0, type \\ 0, opts \\ []) do
    nper |> rate(pmt, pv, fv, type, opts) |> unwrap!()
  end

  # The annuity factor that multiplies pmt in the moduledoc equation.
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
    |> Map.new(&{&1 * 1.0, pmt * 1.0})
    |> Map.update(0.0, pv * 1.0, &(&1 + pv))
    |> Map.update(nper * 1.0, fv * 1.0, &(&1 + fv))
    |> Map.to_list()
  end
end
