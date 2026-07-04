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

      iex> {:ok, value} = Finance.TVM.pv(0.05, 10, -100, -1000)
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
      rate == 0 -> {:ok, -(pv + fv) / nper * 1.0}
      true -> {:ok, -(pv * :math.pow(1 + rate, nper) + fv) / annuity(rate, nper, type) * 1.0}
    end
  end

  @doc "Same as `pmt/5`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
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

  @doc "Same as `ipmt/6`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
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

  @doc "Same as `ppmt/6`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
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

  If `rate` or `pv` is a `Decimal`, the whole schedule is computed in `Decimal`
  and every monetary field comes back as a `Decimal` — exact to the cent, which
  matters when the rounding compounds over hundreds of periods.

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
    n = trunc(nper)

    if nper == n and n >= 1 do
      opts = NimbleOptions.validate!(opts, @schedule_options_schema)
      {:ok, build_schedule(rate, n, pv, Keyword.fetch!(opts, :precision))}
    else
      {:error, :undefined}
    end
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

  defp build_schedule(rate, nper, pv, precision) do
    if is_struct(rate, Decimal) or is_struct(pv, Decimal) do
      build_decimal_schedule(to_decimal(rate), nper, to_decimal(pv), precision)
    else
      build_float_schedule(rate, nper, pv, precision)
    end
  end

  defp build_float_schedule(rate, nper, pv, precision) do
    {:ok, payment} = pmt(rate, nper, pv)
    payment = float_round(payment, precision)

    schedule(1..nper, pv, fn period, balance ->
      interest = float_round(-balance * rate, precision)
      principal = float_principal(period, nper, balance, payment, interest, precision)
      new_balance = float_round(balance + principal, precision)

      row_payment =
        if period == nper, do: float_round(interest + principal, precision), else: payment

      {row_payment, interest, principal, new_balance}
    end)
  end

  defp float_principal(nper, nper, balance, _payment, _interest, precision),
    do: float_round(-balance, precision)

  defp float_principal(_period, _nper, _payment, payment, interest, precision),
    do: float_round(payment - interest, precision)

  # `+ 0.0` collapses a floating-point negative zero to `0.0`.
  defp float_round(value, precision), do: Float.round(value, precision) + 0.0

  defp build_decimal_schedule(rate, nper, pv, precision) do
    payment = rate |> decimal_pmt(nper, pv) |> decimal_round(precision)

    schedule(1..nper, pv, fn period, balance ->
      interest = Decimal.mult(balance, rate) |> Decimal.mult(-1) |> decimal_round(precision)
      principal = decimal_principal(period, nper, balance, payment, interest, precision)
      new_balance = Decimal.add(balance, principal) |> decimal_round(precision)

      row_payment =
        if period == nper,
          do: Decimal.add(interest, principal) |> decimal_round(precision),
          else: payment

      {row_payment, interest, principal, new_balance}
    end)
  end

  defp decimal_principal(nper, nper, balance, _payment, _interest, precision),
    do: balance |> Decimal.mult(-1) |> decimal_round(precision)

  defp decimal_principal(_period, _nper, _balance, payment, interest, precision),
    do: Decimal.sub(payment, interest) |> decimal_round(precision)

  # `pmt` for a plain loan (fv 0, ordinary annuity), in Decimal.
  defp decimal_pmt(rate, nper, pv) do
    if Decimal.equal?(rate, 0) do
      Decimal.div(Decimal.mult(pv, -1), Decimal.new(nper))
    else
      growth = dec_pow(Decimal.add(1, rate), nper)
      numerator = pv |> Decimal.mult(growth) |> Decimal.mult(rate) |> Decimal.mult(-1)
      Decimal.div(numerator, Decimal.sub(growth, 1))
    end
  end

  # (base)^n for a whole number n >= 1, by repeated multiplication (Decimal has no pow).
  defp dec_pow(base, n) when n >= 1 do
    Enum.reduce(1..n, Decimal.new(1), fn _, acc -> Decimal.mult(acc, base) end)
  end

  defp decimal_round(value, precision), do: Decimal.round(value, precision)

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  # Walk the periods carrying a running balance; `fun` returns the four monetary
  # fields for the row. Shared by the float and Decimal builders.
  defp schedule(periods, opening_balance, fun) do
    {rows, _balance} =
      Enum.map_reduce(periods, opening_balance, fn period, balance ->
        {payment, interest, principal, new_balance} = fun.(period, balance)

        row = %{
          period: period,
          payment: payment,
          interest: interest,
          principal: principal,
          balance: new_balance
        }

        {row, new_balance}
      end)

    rows
  end

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

  @doc "Same as `nper/5`, but hands back the value on its own and raises `ArgumentError` if the calculation fails."
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
end
