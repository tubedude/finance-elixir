defmodule Finance.Newthon do

  def solve(f, a, b) do
    solve(f, a, b, 0.001, 1000)
  end

  def solve(_, a, b, tol, _) when (b - a) < tol do
    {:ok, (a + b) / 2}
  end

  def solve(_, _, _, _, iters) when iters == 0 do
    {:error, "Could not converge"}
  end

  def solve(f, a, b, tol, iters) do
    m = (a + b) / 2
    cond do
      f.(a) * f.(m) < 0 ->
        solve(f, a, m, tol, iters-1)
      true ->
        solve(f, m, b, tol, iters-1)
    end
  end
end
