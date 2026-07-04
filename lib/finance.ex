defmodule Finance do
  @moduledoc """
  Calculates the **XIRR** — the internal rate of return for a series of cash
  flows that occur at irregular intervals.

  Given cash flows `cf_i` at times `t_i` (in years from the earliest flow),
  XIRR is the rate `r` that solves:

      Σ cf_i / (1 + r)^t_i = 0

  The solver uses Newton-Raphson (fast, analytic derivative) and falls back to
  a bracketing bisection when Newton leaves the valid domain or fails to
  converge. It follows the same conventions as spreadsheet `XIRR` functions —
  an Actual/365 day count, a default `0.1` initial guess, and a 100-iteration
  cap — and has no runtime dependencies.

  ## Example

      iex> Finance.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
      {:ok, 0.1}

  Cash flows may be given as `{date, amount}` pairs (see `xirr/2`) or as two
  parallel lists of dates and amounts. Dates may be `Date` structs or
  Erlang-style `{year, month, day}` tuples.

  ## Options

  The `{date, amount}` form accepts a keyword list:

    * `:guess` — initial rate for Newton-Raphson (default `0.1`)
    * `:tolerance` — convergence threshold on the net present value (default `1.0e-9`)
    * `:max_iterations` — cap before giving up (default `100`)
    * `:precision` — decimal places the result is rounded to (default `6`)
  """

  @typedoc "A `Date` struct or an Erlang-style `{year, month, day}` tuple."
  @type date :: Date.t() | {integer, integer, integer}

  @typedoc "A dated cash flow. Positive amounts are inflows, negative are outflows."
  @type cash_flow :: {date, number}

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

  @days_in_year 365.0

  @default_options [guess: 0.1, tolerance: 1.0e-9, max_iterations: 100, precision: 6]

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
  @spec xirr([date], [number]) :: {:ok, rate} | {:error, error}
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
  @spec xirr([date], [number], [option]) :: {:ok, rate} | {:error, error}
  def xirr(dates, values, opts)
      when is_list(dates) and is_list(values) and is_list(opts) do
    zip(dates, values, opts)
  end

  @doc "Like `xirr/1`, but returns the rate directly and raises `ArgumentError` on error."
  @spec xirr!([cash_flow]) :: rate
  def xirr!(cash_flows), do: cash_flows |> xirr() |> unwrap!()

  @doc "Like `xirr/2`, but returns the rate directly and raises `ArgumentError` on error."
  @spec xirr!([cash_flow] | [date], [option] | [number]) :: rate
  def xirr!(first, second), do: first |> xirr(second) |> unwrap!()

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
    precision = @default_options |> Keyword.merge(opts) |> Keyword.fetch!(:precision)

    with {:ok, flows} <- normalize(cash_flows) do
      # `+ 0.0` collapses a floating-point negative zero to `0.0`.
      {:ok, Float.round(npv(flows, rate), precision) + 0.0}
    end
  end

  @doc "Like `xnpv/2`, but returns the value directly and raises `ArgumentError` on error."
  @spec xnpv!(rate, [cash_flow]) :: number
  def xnpv!(rate, cash_flows), do: rate |> xnpv(cash_flows) |> unwrap!()

  # --- Dispatch helpers ----------------------------------------------------

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
    opts = Keyword.merge(@default_options, opts)

    with {:ok, flows} <- normalize(cash_flows),
         :ok <- validate(flows) do
      solve(flows, opts)
    end
  end

  defp unwrap!({:ok, rate}), do: rate
  defp unwrap!({:error, reason}), do: raise(ArgumentError, "could not compute: #{reason}")

  # --- Normalization -------------------------------------------------------

  # Parse dates, re-express each flow's time as years since the earliest date,
  # and merge flows that fall on the same date.
  defp normalize([]), do: {:error, :insufficient_data}

  defp normalize(cash_flows) do
    parsed = Enum.map(cash_flows, fn {date, amount} -> {to_date(date), amount / 1} end)
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
    f = npv(flows, rate)
    derivative = dnpv(flows, rate)

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

    case bracket(flows, low, npv(flows, low), 1.0) do
      {:ok, low, high} -> {:ok, bisection(flows, low, high, max_iterations, tol)}
      :diverged -> :diverged
    end
  end

  # Expand the upper bound until the NPV changes sign, giving us a bracket.
  defp bracket(_flows, _low, _f_low, high) when high > 1.0e7, do: :diverged

  defp bracket(flows, low, f_low, high) do
    if f_low * npv(flows, high) <= 0 do
      {:ok, low, high}
    else
      bracket(flows, low, f_low, high * 2 + 1)
    end
  end

  defp bisection(_flows, low, high, 0, _tol), do: (low + high) / 2

  defp bisection(flows, low, high, iterations, tol) do
    mid = (low + high) / 2
    f_mid = npv(flows, mid)

    cond do
      abs(f_mid) < tol or high - low < tol -> mid
      npv(flows, low) * f_mid < 0 -> bisection(flows, low, mid, iterations - 1, tol)
      true -> bisection(flows, mid, high, iterations - 1, tol)
    end
  end

  # Net present value: Σ amount / (1 + rate)^t
  defp npv(flows, rate) do
    Enum.reduce(flows, 0.0, fn {t, amount}, acc ->
      acc + amount / :math.pow(1 + rate, t)
    end)
  end

  # Derivative of the NPV with respect to rate: Σ -t · amount / (1 + rate)^(t+1)
  defp dnpv(flows, rate) do
    Enum.reduce(flows, 0.0, fn {t, amount}, acc ->
      acc + -t * amount / :math.pow(1 + rate, t + 1)
    end)
  end
end
