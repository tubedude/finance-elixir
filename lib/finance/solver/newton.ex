defmodule Finance.Solver.Newton do
  @moduledoc """
  The default `Finance.Solver`: a safeguarded Newton-Raphson (the classic
  `rtsafe`).

  It brackets the root first, then each iteration takes a Newton step when that
  step lands inside the bracket and is shrinking the interval fast enough, and a
  bisection step otherwise. This keeps Newton's quadratic speed on well-behaved
  flows while retaining bisection's guaranteed convergence — in one pass, rather
  than running Newton to exhaustion and then bisecting separately.

  Because the maintained bracket always encloses a sign change, the result is a
  genuine root rather than a stalled non-root, and a Newton step that would leave
  the bracket simply becomes a bisection step instead.

  Bracketing scans the interior of the rate domain rather than only its extremes,
  so it finds a root even when the NPV crosses zero an even number of times (a
  series with more than one IRR). When several roots exist it brackets the one
  nearest `:guess`, matching what a guess-driven spreadsheet `XIRR` returns.
  """

  @behaviour Finance.Solver

  import Finance.Shared, only: [present_value: 2, round_value: 2, safely: 1]

  @impl Finance.Solver
  def solve(flows, opts) do
    guess = Keyword.fetch!(opts, :guess)
    tolerance = Keyword.fetch!(opts, :tolerance)
    max_iterations = Keyword.fetch!(opts, :max_iterations)

    case safely(fn -> rtsafe(flows, guess, tolerance, max_iterations) end) do
      {:ok, rate} -> {:ok, round_value(rate, opts)}
      :diverged -> {:error, :did_not_converge}
    end
  end

  # Pure-Elixir batch: chunk the work across the schedulers (see
  # `Finance.Shared.solve_batch/2`). A native backend overrides this with one call.
  @impl Finance.Solver
  def solve_many(batch, opts), do: Finance.Shared.solve_batch(batch, &solve(&1, opts))

  defp rtsafe(flows, guess, tol, max_iterations) do
    case Finance.Shared.bracket(flows, guess) do
      {:ok, a, b} ->
        bracket = orient(flows, a, b)
        x = if guess > a and guess < b, do: guess, else: (a + b) / 2
        f = present_value(flows, x)
        df = present_value_derivative(flows, x)
        {:ok, search(flows, x, bracket, f, df, abs(b - a), tol, max_iterations)}

      :diverged ->
        :diverged
    end
  end

  # Orient the bracket so the net present value is negative at `xlo` and positive
  # at `xhi` — the invariant the step selection and re-bracketing below rely on.
  defp orient(flows, a, b) do
    if present_value(flows, a) < 0.0, do: {a, b}, else: {b, a}
  end

  defp search(_flows, x, _bracket, _f, _df, _dxold, _tol, 0), do: x

  defp search(flows, x, {xlo, xhi}, f, df, dxold, tol, iters) do
    {next, dx} = move(x, xlo, xhi, f, df, dxold)

    if abs(dx) < tol do
      next
    else
      f_next = present_value(flows, next)
      df_next = present_value_derivative(flows, next)
      bracket = if f_next < 0.0, do: {next, xhi}, else: {xlo, next}
      search(flows, next, bracket, f_next, df_next, dx, tol, iters - 1)
    end
  end

  # Returns `{next_x, step}`.
  defp move(x, xlo, xhi, f, df, dxold) do
    if newton_usable?(x, xlo, xhi, f, df, dxold) do
      dx = f / df
      {x - dx, dx}
    else
      dx = (xhi - xlo) / 2.0
      {xlo + dx, dx}
    end
  end

  # Prefer Newton when the derivative isn't flat, the step shrinks the interval by
  # at least half, and it lands inside the bracket. Comparing the Newton point
  # against the bracket — rather than the classic
  # `((x-xhi)·df - f)·((x-xlo)·df - f)` product — avoids an overflow in the steep
  # zone near the bracket's floor. The magnitude test runs before `x - f / df`, so
  # the division is provably bounded (`|f/df| ≤ |dxold|/2`) when it is computed.
  defp newton_usable?(x, xlo, xhi, f, df, dxold) do
    df != 0.0 and abs(2.0 * f) <= abs(dxold * df) and inside?(x - f / df, xlo, xhi)
  end

  defp inside?(point, xlo, xhi), do: point >= min(xlo, xhi) and point <= max(xlo, xhi)

  # Derivative of the NPV with respect to rate: Σ -t · amount / (1 + rate)^(t+1).
  # Uses a negative exponent for the same reason as `present_value/2`: the factor
  # underflows to 0 at high rates instead of overflowing the denominator (which
  # `:math.pow` would raise on) for long-dated flows.
  defp present_value_derivative(flows, rate) do
    Enum.reduce(flows, 0.0, fn {t, amount}, acc ->
      acc - t * amount * :math.pow(1 + rate, -(t + 1))
    end)
  end
end
