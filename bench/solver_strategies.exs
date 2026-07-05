# Benchmark: rate-solver strategies.
#
# The rate functions (irr/xirr/rate/ytm) find `r` where `Σ amount/(1+r)^t = 0`.
# The shipped Finance.Solver.Newton runs Newton-Raphson first and falls back to
# bracketing bisection when Newton leaves the domain or stalls. This compares
# three strategies on identical flows:
#
#   * newton + bisect fallback — the shipped approach (Newton, then a *separate*
#     bisection pass if Newton fails).
#   * pure bisection           — robust but linearly convergent.
#   * safeguarded newton       — Numerical Recipes' rtsafe: a Newton step when it
#     stays inside a maintained bracket, a bisection step otherwise. Newton's
#     speed and bisection's robustness folded into one pass.
#
# It reports both wall-clock time and the number of NPV / derivative evaluations
# each strategy needs — the evaluation count is the mechanism behind the timings.
#
# Run with:  mix run bench/solver_strategies.exs

defmodule Solvers do
  @moduledoc false

  # `pv/2` (NPV) and `dpv/2` (its derivative) are the unit of work every strategy
  # shares. They bump a process-dictionary counter when `:evals` is set, so the
  # analysis pass can tally evaluations; during timing `:evals` is unset and the
  # bump is a single cheap dictionary read, identical for all three strategies.
  defp count do
    case Process.get(:evals) do
      nil -> :ok
      n -> Process.put(:evals, n + 1)
    end
  end

  def pv(flows, rate) do
    count()
    Enum.reduce(flows, 0.0, fn {t, a}, acc -> acc + a / :math.pow(1 + rate, t) end)
  end

  def dpv(flows, rate) do
    count()
    Enum.reduce(flows, 0.0, fn {t, a}, acc -> acc + -t * a / :math.pow(1 + rate, t + 1) end)
  end

  # --- shared bracketing (identical to the shipped solver) ---
  def safe_low(flows) do
    max_t = Enum.reduce(flows, 1.0, fn {t, _a}, acc -> max(t, acc) end)
    max(:math.pow(1.0e-290, 1 / max_t), 1.0e-6) - 1.0
  end

  defp straddles?(a, b), do: (a <= 0 and b >= 0) or (a >= 0 and b <= 0)

  defp bracket(_flows, _low, _f_low, high) when high > 1.0e7, do: :diverged

  defp bracket(flows, low, f_low, high) do
    if straddles?(f_low, pv(flows, high)),
      do: {:ok, low, high},
      else: bracket(flows, low, f_low, high * 2 + 1)
  end

  # --- newton with a bisection fallback (mirrors Finance.Solver.Newton) ---
  def newton(flows, opts) do
    tol = opts[:tolerance]
    max = opts[:max_iterations]

    with :diverged <- nr(flows, opts[:guess], max, tol),
         :diverged <- bisect(flows, max, tol) do
      {:error, :did_not_converge}
    else
      {:ok, r} -> {:ok, Float.round(r, opts[:precision])}
    end
  end

  defp nr(_flows, _rate, 0, _tol), do: :diverged

  defp nr(flows, rate, iters, tol) do
    f = pv(flows, rate)
    df = dpv(flows, rate)

    cond do
      abs(f) < tol -> {:ok, rate}
      df == 0.0 -> :diverged
      true -> nr_step(flows, rate, rate - f / df, iters, tol)
    end
  end

  defp nr_step(flows, rate, next, iters, tol) do
    cond do
      next <= -1.0 -> nr(flows, (rate - 1.0) / 2.0, iters - 1, tol)
      abs(next - rate) < tol -> {:ok, next}
      true -> nr(flows, next, iters - 1, tol)
    end
  end

  # --- pure bisection ---
  def bisect_solver(flows, opts) do
    case bisect(flows, opts[:max_iterations], opts[:tolerance]) do
      {:ok, r} -> {:ok, Float.round(r, opts[:precision])}
      :diverged -> {:error, :did_not_converge}
    end
  end

  defp bisect(flows, max, tol) do
    low = safe_low(flows)

    case bracket(flows, low, pv(flows, low), 1.0) do
      {:ok, low, high} -> {:ok, bisection(flows, low, high, max, tol)}
      :diverged -> :diverged
    end
  end

  defp bisection(_flows, low, high, 0, _tol), do: (low + high) / 2

  defp bisection(flows, low, high, iters, tol) do
    mid = (low + high) / 2
    f_mid = pv(flows, mid)

    cond do
      abs(f_mid) < tol or high - low < tol -> mid
      straddles?(pv(flows, low), f_mid) -> bisection(flows, low, mid, iters - 1, tol)
      true -> bisection(flows, mid, high, iters - 1, tol)
    end
  end

  # --- safeguarded newton (rtsafe) ---
  def safe(flows, opts) do
    low = safe_low(flows)

    case bracket(flows, low, pv(flows, low), 1.0) do
      {:ok, a, b} ->
        {xl, xh} = if pv(flows, a) < 0.0, do: {a, b}, else: {b, a}

        root =
          rtsafe(flows, (a + b) / 2, xl, xh, abs(b - a), opts[:tolerance], opts[:max_iterations])

        {:ok, Float.round(root, opts[:precision])}

      :diverged ->
        {:error, :did_not_converge}
    end
  end

  defp rtsafe(flows, rts, xl, xh, dxold, tol, iters) do
    rtsafe(flows, rts, xl, xh, pv(flows, rts), dpv(flows, rts), dxold, tol, iters)
  end

  defp rtsafe(_flows, rts, _xl, _xh, _f, _df, _dxold, _tol, 0), do: rts

  defp rtsafe(flows, rts, xl, xh, f, df, dxold, tol, iters) do
    {rts2, dx} =
      if bisection_step?(rts, xl, xh, f, df, dxold) do
        d = (xh - xl) / 2.0
        {xl + d, d}
      else
        d = f / df
        {rts - d, d}
      end

    if abs(dx) < tol do
      rts2
    else
      f2 = pv(flows, rts2)
      df2 = dpv(flows, rts2)
      {xl2, xh2} = if f2 < 0.0, do: {rts2, xh}, else: {xl, rts2}
      rtsafe(flows, rts2, xl2, xh2, f2, df2, dx, tol, iters - 1)
    end
  end

  # Take a bisection step (not Newton) when the derivative is flat, a Newton step
  # would jump outside the bracket, or it isn't shrinking the interval fast enough.
  defp bisection_step?(rts, xl, xh, f, df, dxold) do
    df == 0.0 or
      ((rts - xh) * df - f) * ((rts - xl) * df - f) > 0.0 or
      abs(2.0 * f) > abs(dxold * df)
  end
end

defmodule Fixtures do
  @moduledoc false

  # A fully-amortizing loan as normalized flows: +pv received at t=0, then `n`
  # equal payments. One sign change, so a single real rate — well-conditioned.
  def loan(pv, rate, n) do
    pmt = pv * rate / (1 - :math.pow(1 + rate, -n))
    [{0.0, pv * 1.0} | for(t <- 1..n, do: {t / 1.0, -pmt})]
  end
end

opts = [guess: 0.1, tolerance: 1.0e-9, max_iterations: 100, precision: 6]

inputs = %{
  "easy — 4 flows, r≈9%" => [{0.0, -1000.0}, {1.0, 300.0}, {2.0, 400.0}, {3.0, 500.0}],
  "medium — 60-period loan, r=1%/pd" => Fixtures.loan(100_000, 0.01, 60),
  "long — 480-period loan, r=0.4%/pd" => Fixtures.loan(100_000, 0.004, 480)
}

strategies = [
  {"newton + bisect fallback", &Solvers.newton/2},
  {"pure bisection", &Solvers.bisect_solver/2},
  {"safeguarded newton", &Solvers.safe/2}
]

# --- correctness: every strategy must agree, and the newton mirror must match
# the shipped Finance.Solver.Newton exactly (so the timings below are credible) ---
IO.puts("agreement — all strategies agree, and the mirror matches the shipped solver:\n")

for {label, flows} <- inputs do
  [n, b, s] = for {_name, solve} <- strategies, do: solve.(flows, opts)
  shipped = Finance.Solver.Newton.solve(flows, opts)
  ok = n == b and b == s and n == shipped

  IO.puts(
    "  #{String.pad_trailing(label, 34)} rate=#{elem(s, 1)}  mirror==shipped=#{n == shipped}  all_agree=#{ok}"
  )
end

# --- analysis: NPV/derivative evaluations per solve ---
IO.puts("\nNPV + derivative evaluations per solve (the mechanism behind the timings):\n")
IO.puts("  #{String.pad_trailing("flow set", 34)}newton+bisect   pure bisect   safeguarded")

for {label, flows} <- inputs do
  [n, b, s] =
    for {_name, solve} <- strategies do
      Process.put(:evals, 0)
      solve.(flows, opts)
      Process.get(:evals)
    end

  Process.delete(:evals)

  row =
    [n, b, s]
    |> Enum.map(&String.pad_leading(Integer.to_string(&1), 12))
    |> Enum.join("  ")

  IO.puts("  #{String.pad_trailing(label, 32)}#{row}")
end

# --- timing ---
IO.puts("")

Benchee.run(
  Map.new(strategies, fn {name, solve} -> {name, fn flows -> solve.(flows, opts) end} end),
  inputs: inputs,
  time: 3,
  memory_time: 1,
  warmup: 1
)
