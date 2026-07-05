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

  # ----- Brent's method (derivative-free: secant + inverse quadratic + bisection) -----
  # Uses only `pv/2` — no derivative. A port of Numerical Recipes' `zbrent`.
  def brent_solver(flows, opts) do
    low = safe_low(flows)

    case bracket(flows, low, pv(flows, low), 1.0) do
      {:ok, a, b} ->
        root = zbrent(flows, a, b, opts[:tolerance], opts[:max_iterations])
        {:ok, Float.round(root, opts[:precision])}

      :diverged ->
        {:error, :did_not_converge}
    end
  end

  @eps 2.220446049250313e-16

  defp zbrent(flows, a, b, tol, max_iter) do
    brent(flows, a, b, b, pv(flows, a), pv(flows, b), pv(flows, b), 0.0, 0.0, tol, max_iter)
  end

  defp brent(_flows, _a, b, _c, _fa, _fb, _fc, _d, _e, _tol, 0), do: b

  defp brent(flows, a, b, c, fa, fb, fc, d, e, tol, iters) do
    # keep c on the far side of the root from b, and make b the closer estimate
    {a, c, fa, fc, d, e} =
      if same_sign?(fb, fc), do: {a, a, fa, fa, b - a, b - a}, else: {a, c, fa, fc, d, e}

    {a, b, c, fa, fb, fc} =
      if abs(fc) < abs(fb), do: {b, c, b, fb, fc, fb}, else: {a, b, c, fa, fb, fc}

    tol1 = 2.0 * @eps * abs(b) + 0.5 * tol
    xm = 0.5 * (c - b)

    if abs(xm) <= tol1 or fb == 0.0 do
      b
    else
      {d, e} = brent_step(a, b, c, fa, fb, fc, d, e, xm, tol1)
      next = if abs(d) > tol1, do: b + d, else: b + brent_sign(tol1, xm)
      brent(flows, b, next, c, fb, pv(flows, next), fc, d, e, tol, iters - 1)
    end
  end

  # Interpolate (secant when only two points, inverse-quadratic with three) if the
  # step stays in bounds and makes progress; otherwise bisect. Returns `{d, e}`.
  defp brent_step(a, b, c, fa, fb, fc, d, e, xm, tol1) do
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

  # ----- Safeguarded secant (rtsafe with the derivative replaced by a secant slope) -----
  # Same bracket and step-acceptance as `safe/2`, but the slope is estimated from
  # the last two points instead of `dpv/2` — one NPV eval per step, no derivative.
  def secant_solver(flows, opts) do
    low = safe_low(flows)

    case bracket(flows, low, pv(flows, low), 1.0) do
      {:ok, a, b} ->
        {xlo, xhi} = if pv(flows, a) < 0.0, do: {a, b}, else: {b, a}
        # Seed the two secant points from the guess and the upper bound — both
        # moderate-NPV points, never the astronomically steep bracket floor.
        guess = opts[:guess]
        x0 = if guess > a and guess < b, do: guess, else: (a + 3.0 * b) / 4.0

        root =
          ssecant(flows, x0, b, pv(flows, x0), pv(flows, b), xlo, xhi, abs(b - a),
            opts[:tolerance], opts[:max_iterations])

        {:ok, Float.round(root, opts[:precision])}

      :diverged ->
        {:error, :did_not_converge}
    end
  end

  # `x`/`f` is the current estimate, `xp`/`fp` the previous point (for the slope).
  # Converge on bracket width — not step size — because a finite-difference slope
  # is unreliable near the steep bracket floor and would trip step-size termination.
  defp ssecant(_flows, x, _xp, _f, _fp, _xlo, _xhi, _dxold, _tol, 0), do: x

  defp ssecant(flows, x, xp, f, fp, xlo, xhi, dxold, tol, iters) do
    if abs(xhi - xlo) < tol or f == 0.0 do
      x
    else
      df = if x == xp, do: 0.0, else: (f - fp) / (x - xp)
      candidate = if df == 0.0, do: x, else: x - f / df

      secant_ok? =
        df != 0.0 and candidate >= min(xlo, xhi) and candidate <= max(xlo, xhi) and
          abs(2.0 * f) <= abs(dxold * df)

      {next, dx} =
        if secant_ok? do
          {candidate, f / df}
        else
          d = (xhi - xlo) / 2.0
          {xlo + d, d}
        end

      fnext = pv(flows, next)
      {xlo2, xhi2} = if fnext < 0.0, do: {next, xhi}, else: {xlo, next}
      ssecant(flows, next, x, fnext, f, xlo2, xhi2, dx, tol, iters - 1)
    end
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
  {"newton + bisect fallback", "newton+bis", &Solvers.newton/2},
  {"pure bisection", "bisection", &Solvers.bisect_solver/2},
  {"safeguarded newton", "rtsafe", &Solvers.safe/2},
  {"safeguarded secant", "secant", &Solvers.secant_solver/2},
  {"brent", "brent", &Solvers.brent_solver/2}
]

# --- correctness: every strategy must agree with the shipped Finance.Solver.Newton
# (so the timings below are credible) ---
IO.puts("agreement — every strategy must find the same rate:\n")

for {label, flows} <- inputs do
  results = for {_name, _short, solve} <- strategies, do: solve.(flows, opts)
  shipped = Finance.Solver.Newton.solve(flows, opts)
  agree = Enum.all?(results, &(&1 == shipped))
  IO.puts("  #{String.pad_trailing(label, 34)} rate=#{elem(shipped, 1)}  all_agree=#{agree}")
end

# --- analysis: NPV/derivative evaluations per solve ---
IO.puts("\nNPV(+derivative) evaluations per solve (the mechanism behind the timings):\n")

header =
  strategies |> Enum.map(fn {_name, short, _} -> String.pad_leading(short, 12) end) |> Enum.join()

IO.puts("  #{String.pad_trailing("flow set", 30)}#{header}")

for {label, flows} <- inputs do
  counts =
    for {_name, _short, solve} <- strategies do
      Process.put(:evals, 0)
      solve.(flows, opts)
      Process.get(:evals)
    end

  Process.delete(:evals)

  row = counts |> Enum.map(&String.pad_leading(Integer.to_string(&1), 12)) |> Enum.join()
  IO.puts("  #{String.pad_trailing(label, 30)}#{row}")
end

# --- timing ---
IO.puts("")

Benchee.run(
  Map.new(strategies, fn {name, _short, solve} -> {name, fn flows -> solve.(flows, opts) end} end),
  inputs: inputs,
  time: 3,
  memory_time: 1,
  warmup: 1
)
