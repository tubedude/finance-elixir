defmodule Finance.Solver.Newton do
  @moduledoc """
  The default `Finance.Solver`: Newton-Raphson using the analytic derivative of
  the net present value, with a bracketing bisection fallback when a Newton step
  wanders outside the `(-1, ∞)` domain or fails to converge.
  """

  @behaviour Finance.Solver

  import Finance.Shared, only: [present_value: 2]

  @impl Finance.Solver
  def solve(flows, opts) do
    guess = Keyword.fetch!(opts, :guess)
    tolerance = Keyword.fetch!(opts, :tolerance)
    max_iterations = Keyword.fetch!(opts, :max_iterations)

    # Each stage returns `{:ok, rate}` or `:diverged`. `safely/1` turns an
    # arithmetic overflow — which can happen at extreme rates on long-dated
    # flows — into `:diverged`, so a Newton failure still falls through to
    # bisection rather than aborting the whole solve. Any `{:ok, rate}` drops
    # to `else` to be rounded.
    with :diverged <- safely(fn -> newton(flows, guess, max_iterations, tolerance) end),
         :diverged <- safely(fn -> bisect(flows, max_iterations, tolerance) end) do
      {:error, :did_not_converge}
    else
      {:ok, rate} -> {:ok, Float.round(rate, Keyword.fetch!(opts, :precision))}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    ArithmeticError -> :diverged
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
    low = safe_low(flows)

    case bracket(flows, low, present_value(flows, low), 1.0) do
      {:ok, low, high} -> {:ok, bisection(flows, low, high, max_iterations, tol)}
      :diverged -> :diverged
    end
  end

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

  defp bisection(_flows, low, high, 0, _tol), do: (low + high) / 2

  defp bisection(flows, low, high, iterations, tol) do
    mid = (low + high) / 2
    f_mid = present_value(flows, mid)

    cond do
      abs(f_mid) < tol or high - low < tol ->
        mid

      straddles_zero?(present_value(flows, low), f_mid) ->
        bisection(flows, low, mid, iterations - 1, tol)

      true ->
        bisection(flows, mid, high, iterations - 1, tol)
    end
  end

  # Whether `a` and `b` sit on opposite sides of zero (a root lies between them).
  # Comparing signs rather than the product `a * b` avoids overflow when the NPV
  # is astronomically large near the bracket's floor for long-dated flows.
  defp straddles_zero?(a, b), do: (a <= 0 and b >= 0) or (a >= 0 and b <= 0)

  # Derivative of the NPV with respect to rate: Σ -t · amount / (1 + rate)^(t+1)
  defp present_value_derivative(flows, rate) do
    Enum.reduce(flows, 0.0, fn {t, amount}, acc ->
      acc + -t * amount / :math.pow(1 + rate, t + 1)
    end)
  end
end
