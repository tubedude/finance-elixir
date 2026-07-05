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
  genuine root rather than a stalled non-root, and a long-dated flow whose raw
  Newton step would overflow simply takes a bisection step instead.
  """

  @behaviour Finance.Solver

  import Finance.Shared, only: [present_value: 2]

  @impl Finance.Solver
  def solve(flows, opts) do
    guess = Keyword.fetch!(opts, :guess)
    tolerance = Keyword.fetch!(opts, :tolerance)
    max_iterations = Keyword.fetch!(opts, :max_iterations)

    case safely(fn -> rtsafe(flows, guess, tolerance, max_iterations) end) do
      # `+ 0.0` collapses a negative zero (a rate that converges to 0 from below).
      {:ok, rate} -> {:ok, Float.round(rate, Keyword.fetch!(opts, :precision)) + 0.0}
      :diverged -> {:error, :did_not_converge}
    end
  end

  @impl Finance.Solver
  def solve_many(batch, opts) do
    # Pure-Elixir batch: solve each series in parallel across the schedulers.
    # A native backend would override this with a single batched call.
    batch
    |> Task.async_stream(&solve(&1, opts), ordered: true, timeout: :infinity)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # Arithmetic overflow at extreme rates on long-dated flows is treated as a
  # failure to converge rather than crashing the solve.
  defp safely(fun) do
    fun.()
  rescue
    ArithmeticError -> :diverged
  end

  # Bracket a sign change, then run the safeguarded iteration from `guess` (when it
  # falls inside the bracket) or the midpoint.
  defp rtsafe(flows, guess, tol, max_iterations) do
    low = safe_low(flows)

    case bracket(flows, low, present_value(flows, low), 1.0) do
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

  # A Newton step when it's usable, a bisection step otherwise. Returns
  # `{next_x, step}`.
  defp move(x, xlo, xhi, f, df, dxold) do
    if newton_usable?(x, xlo, xhi, f, df, dxold) do
      dx = f / df
      {x - dx, dx}
    else
      dx = (xhi - xlo) / 2.0
      {xlo + dx, dx}
    end
  end

  # Prefer Newton when the derivative isn't flat, the step lands inside the
  # bracket, and it shrinks the interval by at least half. Comparing the Newton
  # point against the bracket — rather than the classic
  # `((x-xhi)·df - f)·((x-xlo)·df - f)` product — avoids an overflow in the steep
  # zone near the bracket's floor. `df != 0.0` short-circuits before `x - f / df`.
  defp newton_usable?(x, xlo, xhi, f, df, dxold) do
    df != 0.0 and inside?(x - f / df, xlo, xhi) and abs(2.0 * f) <= abs(dxold * df)
  end

  defp inside?(point, xlo, xhi), do: point >= min(xlo, xhi) and point <= max(xlo, xhi)

  # The bracket's floor. As `rate` nears -1, `(1 + rate)^t` underflows to zero
  # (then divides by zero) for large `t`, so raise the floor just enough that the
  # longest-dated flow's discount factor stays finite. For short-dated flows this
  # is the familiar `-0.999999`; for a 30-year monthly schedule it sits higher.
  defp safe_low(flows) do
    max_t = Enum.reduce(flows, 1.0, fn {t, _amount}, acc -> max(t, acc) end)
    max(:math.pow(1.0e-290, 1 / max_t), 1.0e-6) - 1.0
  end

  # Expand the upper bound until the NPV changes sign, giving us a bracket.
  defp bracket(_flows, _low, _f_low, high) when high > 1.0e7, do: :diverged

  defp bracket(flows, low, f_low, high) do
    if straddles_zero?(f_low, present_value(flows, high)) do
      {:ok, low, high}
    else
      bracket(flows, low, f_low, high * 2 + 1)
    end
  end

  # Whether `a` and `b` sit on opposite sides of zero (a root lies between them).
  # Comparing signs rather than the product `a * b` avoids overflow when the NPV
  # is astronomically large near the bracket's floor for long-dated flows.
  defp straddles_zero?(a, b), do: (a <= 0 and b >= 0) or (a >= 0 and b <= 0)

  # Derivative of the NPV with respect to rate: Σ -t · amount / (1 + rate)^(t+1).
  # Uses a negative exponent for the same reason as `present_value/2`: the factor
  # underflows to 0 at high rates instead of overflowing the denominator (which
  # `:math.pow` would raise on) for long-dated flows.
  defp present_value_derivative(flows, rate) do
    Enum.reduce(flows, 0.0, fn {t, amount}, acc ->
      acc + -t * amount * :math.pow(1 + rate, -(t + 1))
    end)
  end
end
