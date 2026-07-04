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
