defmodule Finance.Solver.Brent do
  @moduledoc """
  A `Finance.Solver` using Brent's method (`zbrent`): bracketing with a secant
  step, inverse-quadratic interpolation, and a bisection safeguard.

  It uses **no derivative**, so each iteration costs a single net-present-value
  evaluation rather than the two (`NPV` and its derivative) the default
  `Finance.Solver.Newton` spends per Newton step. Results match the default to the
  requested `:precision`.

  Because it skips the derivative, it tends to be faster on **long-horizon flows**
  — long amortization schedules or bond ladders, where each NPV evaluation is
  itself expensive. On short series the derivative-based default is quicker, so
  it stays the default; select Brent where it pays:

      Finance.CashFlow.xirr(flows, solver: Finance.Solver.Brent)
      config :finance, solver: Finance.Solver.Brent
  """

  @behaviour Finance.Solver

  import Finance.Shared, only: [present_value: 2]

  # Machine epsilon for doubles, for the convergence tolerance.
  @eps 2.220446049250313e-16

  @impl Finance.Solver
  def solve(flows, opts) do
    case safely(fn -> zbrent(flows, opts) end) do
      # `+ 0.0` collapses a negative zero (a rate that converges to 0 from below).
      {:ok, rate} -> {:ok, Float.round(rate, Keyword.fetch!(opts, :precision)) + 0.0}
      :diverged -> {:error, :did_not_converge}
    end
  end

  # Pure-Elixir batch: chunk the work across the schedulers (see
  # `Finance.Shared.solve_batch/2`).
  @impl Finance.Solver
  def solve_many(batch, opts), do: Finance.Shared.solve_batch(batch, &solve(&1, opts))

  # An arithmetic overflow at extreme rates on long-dated flows is treated as a
  # failure to converge rather than crashing the solve.
  defp safely(fun) do
    fun.()
  rescue
    ArithmeticError -> :diverged
  end

  defp zbrent(flows, opts) do
    tol = Keyword.fetch!(opts, :tolerance)
    max_iterations = Keyword.fetch!(opts, :max_iterations)

    case Finance.Shared.bracket(flows) do
      {:ok, a, b} ->
        fa = present_value(flows, a)
        fb = present_value(flows, b)
        {:ok, brent(flows, {a, b, b, fa, fb, fb, 0.0, 0.0}, tol, max_iterations)}

      :diverged ->
        :diverged
    end
  end

  # The state is `{a, b, c, fa, fb, fc, d, e}`: three points and their NPVs, plus
  # the last two step sizes. `b` is the running best estimate.
  defp brent(_flows, {_a, b, _c, _fa, _fb, _fc, _d, _e}, _tol, 0), do: b

  defp brent(flows, {a, b, c, fa, fb, fc, d, e}, tol, iters) do
    # Keep c on the far side of the root from b, and make b the closer estimate.
    {a, c, fa, fc, d, e} =
      if same_sign?(fb, fc), do: {a, a, fa, fa, b - a, b - a}, else: {a, c, fa, fc, d, e}

    {a, b, c, fa, fb, fc} =
      if abs(fc) < abs(fb), do: {b, c, b, fb, fc, fb}, else: {a, b, c, fa, fb, fc}

    tol1 = 2.0 * @eps * abs(b) + 0.5 * tol
    xm = 0.5 * (c - b)

    if abs(xm) <= tol1 or fb == 0.0 do
      b
    else
      {d, e} = step({a, b, c, fa, fb, fc}, d, e, xm, tol1)
      next = if abs(d) > tol1, do: b + d, else: b + brent_sign(tol1, xm)
      brent(flows, {b, next, c, fb, present_value(flows, next), fc, d, e}, tol, iters - 1)
    end
  end

  # Interpolate — secant when only two points are known, inverse-quadratic with
  # three — if the step stays in bounds and makes progress; otherwise bisect.
  # Returns `{d, e}`.
  defp step({a, b, c, fa, fb, fc}, d, e, xm, tol1) do
    if abs(e) >= tol1 and abs(fa) > abs(fb) do
      s = fb / fa

      {p, q} =
        if a == c do
          {2.0 * xm * s, 1.0 - s}
        else
          q = fa / fc
          r = fb / fc
          {s * (2.0 * xm * q * (q - r) - (b - a) * (r - 1.0)), (q - 1.0) * (r - 1.0) * (s - 1.0)}
        end

      q = if p > 0.0, do: -q, else: q
      p = abs(p)

      if 2.0 * p < min(3.0 * xm * q - abs(tol1 * q), abs(e * q)),
        do: {p / q, d},
        else: {xm, xm}
    else
      {xm, xm}
    end
  end

  defp same_sign?(x, y), do: (x > 0.0 and y > 0.0) or (x < 0.0 and y < 0.0)

  defp brent_sign(a, b), do: if(b >= 0.0, do: abs(a), else: -abs(a))
end
