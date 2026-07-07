defmodule Finance.Bonds do
  @moduledoc """
  Fixed income: pricing a bond, solving for its yield, and the standard risk
  metrics (Macaulay and modified duration, convexity).

  A bond pays a coupon of `coupon_rate` a year — split across `freq` payments
  (semiannual by default) — and returns its `face` value at maturity, `years`
  from now. Rates are quoted per year; `ytm` is the yield to maturity.

  > #### Settlement {: .info}
  > These functions assume settlement falls on a coupon date, so the price is
  > "clean" (no accrued interest) and the number of coupon periods is whole.
  > Arbitrary settlement dates and day-count conventions are a later feature.

  The risk metrics — `duration/4`, `modified_duration/4`, `convexity/4` — don't
  depend on the face value (it cancels out), so they leave it off and lead with
  `coupon_rate`, unlike `price/5` and `ytm/5` which lead with `face`.
  """

  import Finance.Shared,
    only: [
      present_value: 2,
      discount_factor: 2,
      round_value: 2,
      options: 2,
      resolve_solver: 1,
      unwrap!: 1
    ]

  @type error :: Finance.error()
  @type option :: Finance.option()

  @doc """
  Prices a bond: the present value of its coupons and face value, discounted at
  the yield `ytm`.

  When the coupon rate equals the yield, the bond prices at par.

      iex> Finance.Bonds.price(100, 0.05, 0.05, 10)
      {:ok, 100.0}

      iex> Finance.Bonds.price(1000, 0.08, 0.10, 10)
      {:ok, 875.377897}
  """
  @spec price(number, number, number, number, pos_integer, [option]) ::
          {:ok, float} | {:error, error}
  def price(face, coupon_rate, ytm, years, freq \\ 2, opts \\ [])
      when is_number(face) and is_number(coupon_rate) and is_number(ytm) and is_number(years) and
             is_integer(freq) and is_list(opts) do
    with {:ok, n} <- coupon_periods(years, freq),
         :ok <- check_yield(ytm, freq) do
      value = present_value(bond_flows(face, coupon_rate, n, freq), ytm / freq)
      {:ok, round_value(value, options(opts, :value))}
    end
  end

  @doc "Same as `price/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec price!(number, number, number, number, pos_integer, [option]) :: float
  def price!(face, coupon_rate, ytm, years, freq \\ 2, opts \\ []) do
    face |> price(coupon_rate, ytm, years, freq, opts) |> unwrap!()
  end

  @doc """
  Solves for a bond's yield to maturity — the annual yield that discounts its
  coupons and face value back to `price`. The inverse of `price/5`.

  There is no closed form, so this reuses the same solver as
  `Finance.CashFlow.irr/1` and takes the same options; it returns
  `{:error, :did_not_converge}` if no yield can be found.

      iex> Finance.Bonds.ytm(1000, 0.08, 875.377897, 10)
      {:ok, 0.1}
  """
  @spec ytm(number, number, number, number, pos_integer, [option]) ::
          {:ok, float} | {:error, error}
  def ytm(face, coupon_rate, price, years, freq \\ 2, opts \\ [])
      when is_number(face) and is_number(coupon_rate) and is_number(price) and is_number(years) and
             is_integer(freq) and is_list(opts) do
    with {:ok, n} <- coupon_periods(years, freq) do
      opts = options(opts, :rate)
      flows = [{0.0, -price * 1.0} | bond_flows(face, coupon_rate, n, freq)]

      # Solve the per-period rate at high precision, then round the annualized
      # yield once. Rounding `periodic` first would let `freq` amplify that
      # rounding error into the last reported digit.
      solver_opts = Keyword.update!(opts, :precision, &max(&1, 12))

      with {:ok, periodic} <- resolve_solver(opts).solve(flows, solver_opts) do
        {:ok, round_value(periodic * freq, opts)}
      end
    end
  end

  @doc "Same as `ytm/5`, but returns the yield directly and raises `ArgumentError` on error."
  @spec ytm!(number, number, number, number, pos_integer, [option]) :: float
  def ytm!(face, coupon_rate, price, years, freq \\ 2, opts \\ []) do
    face |> ytm(coupon_rate, price, years, freq, opts) |> unwrap!()
  end

  @doc """
  Macaulay duration — the present-value-weighted average time, in years, until a
  bond's cash flows are received. A plain measure of interest-rate sensitivity.

  The face value cancels out, so it isn't a parameter (see the module note).

      iex> Finance.Bonds.duration(0.0, 0.05, 10, 1)
      {:ok, 10.0}

      iex> Finance.Bonds.duration(0.06, 0.06, 3, 1)
      {:ok, 2.833393}
  """
  @spec duration(number, number, number, pos_integer, [option]) ::
          {:ok, float} | {:error, error}
  def duration(coupon_rate, ytm, years, freq \\ 2, opts \\ [])
      when is_number(coupon_rate) and is_number(ytm) and is_number(years) and is_integer(freq) and
             is_list(opts) do
    with_metric(coupon_rate, ytm, years, freq, opts, fn flows ->
      macaulay(flows, ytm / freq, freq)
    end)
  end

  @doc "Same as `duration/4`, but returns the value directly and raises `ArgumentError` on error."
  @spec duration!(number, number, number, pos_integer, [option]) :: float
  def duration!(coupon_rate, ytm, years, freq \\ 2, opts \\ []) do
    coupon_rate |> duration(ytm, years, freq, opts) |> unwrap!()
  end

  @doc """
  Modified duration — Macaulay duration divided by `1 + ytm/freq`. It estimates
  the percentage price change for a small change in yield.

      iex> Finance.Bonds.modified_duration(0.0, 0.05, 10, 1)
      {:ok, 9.52381}

      iex> Finance.Bonds.modified_duration(0.06, 0.06, 3, 1)
      {:ok, 2.673012}
  """
  @spec modified_duration(number, number, number, pos_integer, [option]) ::
          {:ok, float} | {:error, error}
  def modified_duration(coupon_rate, ytm, years, freq \\ 2, opts \\ [])
      when is_number(coupon_rate) and is_number(ytm) and is_number(years) and is_integer(freq) and
             is_list(opts) do
    with_metric(coupon_rate, ytm, years, freq, opts, fn flows ->
      with {:ok, m} <- macaulay(flows, ytm / freq, freq), do: {:ok, m / (1 + ytm / freq)}
    end)
  end

  @doc "Same as `modified_duration/4`, but returns the value directly and raises `ArgumentError` on error."
  @spec modified_duration!(number, number, number, pos_integer, [option]) :: float
  def modified_duration!(coupon_rate, ytm, years, freq \\ 2, opts \\ []) do
    coupon_rate |> modified_duration(ytm, years, freq, opts) |> unwrap!()
  end

  @doc """
  Convexity, in years² — the second-order sensitivity of a bond's price to yield.
  Pairs with modified duration to refine the price-change estimate.

      iex> Finance.Bonds.convexity(0.0, 0.05, 10, 1)
      {:ok, 99.773243}

      iex> Finance.Bonds.convexity(0.06, 0.06, 3, 1)
      {:ok, 9.891032}
  """
  @spec convexity(number, number, number, pos_integer, [option]) ::
          {:ok, float} | {:error, error}
  def convexity(coupon_rate, ytm, years, freq \\ 2, opts \\ [])
      when is_number(coupon_rate) and is_number(ytm) and is_number(years) and is_integer(freq) and
             is_list(opts) do
    with_metric(coupon_rate, ytm, years, freq, opts, fn flows ->
      convexity_value(flows, ytm / freq, freq)
    end)
  end

  @doc "Same as `convexity/4`, but returns the value directly and raises `ArgumentError` on error."
  @spec convexity!(number, number, number, pos_integer, [option]) :: float
  def convexity!(coupon_rate, ytm, years, freq \\ 2, opts \\ []) do
    coupon_rate |> convexity(ytm, years, freq, opts) |> unwrap!()
  end

  # --- helpers -------------------------------------------------------------

  # Shared shape for the risk metrics; keeps each public metric a one-liner. `fun`
  # returns `{:ok, value} | {:error, :undefined}` (undefined when the yield drives
  # the unit-face price to zero, e.g. a negative coupon).
  defp with_metric(coupon_rate, ytm, years, freq, opts, fun) do
    with {:ok, n} <- coupon_periods(years, freq),
         :ok <- check_yield(ytm, freq),
         {:ok, value} <- fun.(bond_flows(1, coupon_rate, n, freq)) do
      {:ok, round_value(value, options(opts, :value))}
    end
  end

  # Whole, positive coupon-period count.
  defp coupon_periods(years, freq) do
    n = years * freq
    t = trunc(n)
    if freq > 0 and n == t and t > 0, do: {:ok, t}, else: {:error, :undefined}
  end

  # The per-period yield must keep `1 + ytm/freq` positive for discounting.
  defp check_yield(ytm, freq) when 1 + ytm / freq <= 0, do: {:error, :undefined}
  defp check_yield(_ytm, _freq), do: :ok

  # Coupon + redemption cash flows on `face`, as [{period, amount}], k = 1..n.
  defp bond_flows(face, coupon_rate, n, freq) do
    coupon = face * coupon_rate / freq

    Enum.map(1..n, fn k ->
      amount = if k == n, do: coupon + face, else: coupon
      {k * 1.0, amount}
    end)
  end

  defp weighted_pv(flows, r) do
    Enum.map(flows, fn {k, cf} -> {k, cf * discount_factor(r, k)} end)
  end

  # Macaulay duration in years: PV-weighted average period, divided by freq.
  # Undefined when the price side is non-positive (only a negative coupon can do it).
  defp macaulay(flows, r, freq) do
    weighted = weighted_pv(flows, r)
    price = Enum.reduce(weighted, 0.0, fn {_k, pv}, acc -> acc + pv end)

    if price <= 0.0,
      do: {:error, :undefined},
      else: {:ok, Enum.reduce(weighted, 0.0, fn {k, pv}, acc -> acc + k * pv end) / price / freq}
  end

  # Convexity in years²: the k·(k+1)-weighted PV sum, annualized by freq².
  defp convexity_value(flows, r, freq) do
    weighted = weighted_pv(flows, r)
    price = Enum.reduce(weighted, 0.0, fn {_k, pv}, acc -> acc + pv end)

    if price <= 0.0 do
      {:error, :undefined}
    else
      num = Enum.reduce(weighted, 0.0, fn {k, pv}, acc -> acc + k * (k + 1) * pv end)
      {:ok, num / price / :math.pow(1 + r, 2) / :math.pow(freq, 2)}
    end
  end
end
