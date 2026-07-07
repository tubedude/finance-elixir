defmodule Finance.CashFlow do
  @moduledoc """
  Discounting a series of cash flows: net present/future value (`npv/2`, `xnpv/2`,
  `xnfv/2`) and internal rate of return (`irr/1`, `xirr/2`, `mirr/3`), plus
  `conventional?/1` to check a series has a single unambiguous IRR.

  The **dated** functions (`xirr`, `xnpv`, `xnfv`) take `{date, amount}` flows at
  arbitrary dates and discount on an Actual/365 basis by default — matching the
  spreadsheet `XIRR`/`XNPV` — selectable with the `:basis` option (see
  `Finance.DayCount`). The **periodic** functions (`irr`, `npv`) take a plain list
  of amounts at equally spaced periods `0, 1, 2, …`.

  `xirr`/`irr` find the rate `r` that brings the net present value to zero,
  `Σ cf_i / (1 + r)^t_i = 0`, using `Finance.Solver` (a safeguarded
  Newton-Raphson by default, with a derivative-free `Finance.Solver.Brent`
  available).

  ## Options

  The rate-finding and value functions take an optional keyword list. Options are
  validated with `nimble_options`: an unknown key or bad value raises, while
  problems with the data come back as `{:error, reason}`.

  #{Finance.Shared.options_docs()}
  """

  import Finance.Shared,
    only: [
      to_amount: 1,
      round_value: 2,
      unwrap!: 1,
      options: 1,
      resolve_solver: 1,
      present_value: 2,
      discount_factor: 2,
      check_currency: 1
    ]

  @type date :: Finance.date()
  @type amount :: Finance.amount()
  @type cash_flow :: Finance.cash_flow()
  @type rate :: Finance.rate()
  @type option :: Finance.option()
  @type error :: Finance.error()

  # === XIRR — internal rate of return for dated flows ======================

  @doc """
  Finds the XIRR of a list of `{date, amount}` cash flows — the annual rate of
  return that the flows imply, given when each one lands.

  Reach for this when your cash flows happen on irregular dates rather than at
  neat intervals. See `xirr/2` if you want to pass options or use the two-list
  form.

      iex> Finance.CashFlow.xirr([{~D[2015-06-01], 1_000_000}, {~D[2015-10-01], -2_200_000}, {~D[2015-11-01], -800_000}])
      {:ok, 21.118359}
  """
  @spec xirr([cash_flow]) :: {:ok, rate} | {:error, error}
  def xirr(cash_flows) when is_list(cash_flows), do: xirr(cash_flows, [])

  @doc """
  Finds the XIRR, accepting either `{date, amount}` pairs together with options,
  or two parallel lists — one of dates, one of amounts.

  The result is `{:ok, rate}` on success or `{:error, reason}` when the data
  can't yield a rate. Flows that fall on the same date are added together first.
  The series has to include at least one positive amount and one negative one,
  because without money flowing both in and out there is no return to solve for.

      iex> Finance.CashFlow.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}], guess: 0.5)
      {:ok, 0.1}

      iex> Finance.CashFlow.xirr([~D[2019-01-01], ~D[2020-01-01]], [-1000, 1100])
      {:ok, 0.1}
  """
  @spec xirr([cash_flow], [option]) :: {:ok, rate} | {:error, error}
  @spec xirr([date], [amount]) :: {:ok, rate} | {:error, error}
  def xirr(first, second) when is_list(first) and is_list(second) do
    if pairs?(first) and options?(second) do
      compute(first, second)
    else
      zip(first, second, [])
    end
  end

  @doc """
  Finds the XIRR from two parallel lists — dates and amounts — while also taking
  options for the solver.

      iex> Finance.CashFlow.xirr([~D[2019-01-01], ~D[2020-01-01]], [-1000, 1100], precision: 2)
      {:ok, 0.1}
  """
  @spec xirr([date], [amount], [option]) :: {:ok, rate} | {:error, error}
  def xirr(dates, values, opts)
      when is_list(dates) and is_list(values) and is_list(opts) do
    zip(dates, values, opts)
  end

  @doc "Same as `xirr/1`, but returns the rate directly and raises `ArgumentError` on error."
  @spec xirr!([cash_flow]) :: rate
  def xirr!(cash_flows), do: cash_flows |> xirr() |> unwrap!()

  @doc "Same as `xirr/2`, but returns the rate directly and raises `ArgumentError` on error."
  @spec xirr!([cash_flow] | [date], [option] | [amount]) :: rate
  def xirr!(first, second), do: first |> xirr(second) |> unwrap!()

  @doc """
  Finds the XIRR of many independent series at once — `xirr/1` for a whole
  portfolio. Each element is its own list of `{date, amount}` flows, and the
  result is a list of `{:ok, rate}` / `{:error, reason}` in the same order (one
  bad series doesn't sink the batch).

  The work runs on the configured solver (see `Finance.Solver`): the default
  pure-Elixir solver parallelizes across schedulers, while a native backend
  (a Rustler or Nx solver) runs the whole batch in one call.

      iex> Finance.CashFlow.xirr_many([
      ...>   [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}],
      ...>   [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1200}]
      ...> ])
      [{:ok, 0.1}, {:ok, 0.2}]
  """
  @spec xirr_many([[cash_flow]], [option]) :: [{:ok, rate} | {:error, error}]
  def xirr_many(series, opts \\ []) when is_list(series) and is_list(opts) do
    opts = options(opts)

    basis = Keyword.fetch!(opts, :basis)

    series
    |> Enum.map(&prepare_dated(&1, basis))
    |> solve_batch(opts)
  end

  # === XNPV — net present value of dated flows =============================

  @doc """
  Computes the **XNPV** — the net present value of a set of dated cash flows,
  discounted back at `rate`.

      Σ cf_i / (1 + rate)^t_i

  Each time `t_i` is the year fraction from the earliest flow under the `:basis`
  day-count convention — the *same* convention `xirr/2` uses. That shared
  convention is what ties the two together: `xnpv(r, flows)` comes out to roughly
  zero when `r` is `xirr(flows)`, so this is a handy way to check an XIRR result.
  And because a net present value is defined for any series, the flows here don't
  have to change sign the way `xirr/2` requires.

  The result is `{:ok, value}` or `{:error, reason}`. Flows sharing a period are
  added together first, and you can pass the same `:precision` and `:basis`
  options as `xirr/2` (basis defaults to Actual/365, precision to `6`).

      iex> Finance.CashFlow.xnpv(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1000}])
      {:ok, -90.909091}

      iex> Finance.CashFlow.xnpv(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
      {:ok, 0.0}
  """
  @spec xnpv(rate, [cash_flow]) :: {:ok, number} | {:error, error}
  def xnpv(rate, cash_flows) when is_number(rate) and is_list(cash_flows) do
    xnpv(rate, cash_flows, [])
  end

  @doc "Same as `xnpv/2`, and additionally takes `:precision` and `:basis`. See `xnpv/2`."
  @spec xnpv(rate, [cash_flow], [option]) :: {:ok, number} | {:error, error}
  def xnpv(rate, cash_flows, opts)
      when is_number(rate) and is_list(cash_flows) and is_list(opts) do
    opts = options(opts)

    with :ok <- check_rate(rate),
         {:ok, flows} <- normalize(cash_flows, Keyword.fetch!(opts, :basis)) do
      {:ok, round_value(present_value(flows, rate), opts)}
    end
  end

  @doc "Same as `xnpv/2`, but returns the value directly and raises `ArgumentError` on error."
  @spec xnpv!(rate, [cash_flow]) :: number
  def xnpv!(rate, cash_flows), do: rate |> xnpv(cash_flows) |> unwrap!()

  @doc """
  Net future value of dated cash flows at `rate` — their combined worth at the
  *latest* date. The future-value mirror of `xnpv/2` (which values them at the
  earliest date); the two differ by compounding over the series' span. Takes the
  same `:precision` and `:basis` options.

  Unlike `xnpv/2`, this compounds *forward*, so an extreme `rate` over a long span
  can overflow and raise `ArithmeticError` rather than returning a value — a future
  value that large has no float representation.

      iex> flows = [{~D[2021-01-01], -1000}, {~D[2022-01-01], 1100}]
      iex> Finance.CashFlow.xnfv(0.1, flows)
      {:ok, 0.0}
  """
  @spec xnfv(rate, [cash_flow]) :: {:ok, number} | {:error, error}
  def xnfv(rate, cash_flows) when is_number(rate) and is_list(cash_flows) do
    xnfv(rate, cash_flows, [])
  end

  @doc "Same as `xnfv/2`, and additionally takes `:precision` and `:basis`. See `xnfv/2`."
  @spec xnfv(rate, [cash_flow], [option]) :: {:ok, number} | {:error, error}
  def xnfv(rate, cash_flows, opts)
      when is_number(rate) and is_list(cash_flows) and is_list(opts) do
    opts = options(opts)

    with :ok <- check_rate(rate),
         {:ok, flows} <- normalize(cash_flows, Keyword.fetch!(opts, :basis)) do
      horizon = flows |> Enum.map(fn {t, _amount} -> t end) |> Enum.max()
      {:ok, round_value(present_value(flows, rate) * :math.pow(1 + rate, horizon), opts)}
    end
  end

  @doc "Same as `xnfv/2`, but returns the value directly and raises `ArgumentError` on error."
  @spec xnfv!(rate, [cash_flow]) :: number
  def xnfv!(rate, cash_flows), do: rate |> xnfv(cash_flows) |> unwrap!()

  @doc """
  Whether a series is *conventional* — its amounts change sign exactly once, so it
  has a single, unambiguous internal rate of return. More than one sign change
  makes it non-conventional: it may admit several valid IRRs, and `xirr`/`irr`
  return the one nearest `:guess`. Use this to detect that case before solving.

  Accepts periodic amounts or `{date, amount}` pairs (ordered by date first).

      iex> Finance.CashFlow.conventional?([-1000, 300, 400, 500])
      true

      iex> Finance.CashFlow.conventional?([-1000, 3000, -2500])
      false
  """
  @spec conventional?([amount] | [cash_flow]) :: boolean
  def conventional?(cash_flows) when is_list(cash_flows) do
    cash_flows |> amounts_in_order() |> sign_changes() == 1
  end

  # === IRR — internal rate of return for periodic flows ====================

  @doc """
  Computes the **IRR** — the internal rate of return for a list of amounts that
  occur at equally spaced periods `0, 1, 2, …`. Think of it as `xirr/2` for the
  common case where your flows land at regular intervals and you don't need to
  track exact dates.

  What comes back is the rate per period. As with `xirr/2`, the series has to
  contain at least one positive amount and one negative one.

      iex> Finance.CashFlow.irr([-1000, 1100])
      {:ok, 0.1}

      iex> Finance.CashFlow.irr([-1000, 500, 500, 300])
      {:ok, 0.156579}
  """
  @spec irr([amount]) :: {:ok, rate} | {:error, error}
  def irr(amounts) when is_list(amounts), do: irr(amounts, [])

  @doc "Same as `irr/1`, and additionally takes the same options as `xirr/2`."
  @spec irr([amount], [option]) :: {:ok, rate} | {:error, error}
  def irr(amounts, opts) when is_list(amounts) and is_list(opts) do
    opts = options(opts)
    flows = periodic_flows(amounts)

    with :ok <- check_currency(amounts), :ok <- validate(flows) do
      resolve_solver(opts).solve(flows, opts)
    end
  end

  @doc "Same as `irr/1`, but returns the rate directly and raises `ArgumentError` on error."
  @spec irr!([amount], [option]) :: rate
  def irr!(amounts, opts \\ []), do: amounts |> irr(opts) |> unwrap!()

  @doc """
  Finds the IRR of many independent series at once — `irr/1` for a whole batch.
  Each element is its own list of amounts at periods `0, 1, 2, …`, and the result
  is a list of `{:ok, rate}` / `{:error, reason}` in the same order.

  Like `xirr_many/2`, the batch runs on the configured solver (see
  `Finance.Solver`).

      iex> Finance.CashFlow.irr_many([[-1000, 1100], [-1000, 500, 500, 300]])
      [{:ok, 0.1}, {:ok, 0.156579}]
  """
  @spec irr_many([[amount]], [option]) :: [{:ok, rate} | {:error, error}]
  def irr_many(series, opts \\ []) when is_list(series) and is_list(opts) do
    opts = options(opts)

    series
    |> Enum.map(&prepare_periodic/1)
    |> solve_batch(opts)
  end

  # === NPV — net present value of periodic flows ===========================

  @doc """
  Computes the periodic **NPV** — the net present value of `amounts` occurring at
  equally spaced periods `0, 1, 2, …`, discounted at `rate`.

      Σ amount_i / (1 + rate)^i    (i starting at 0)

  > #### Convention {: .info}
  > The first amount sits at period 0 and so is left undiscounted. That is what
  > lets `npv/2` and `irr/1` line up: `npv(irr(a), a)` comes out to roughly
  > zero. It also means the result differs from a spreadsheet `NPV`, which
  > places the first amount at period 1. If you want to match a spreadsheet,
  > discount the first amount yourself or prepend a leading `0` to the list.

      iex> Finance.CashFlow.npv(0.1, [-1000, 1100])
      {:ok, 0.0}

      iex> Finance.CashFlow.npv(0.1, [-1000, 600, 600])
      {:ok, 41.322314}
  """
  @spec npv(rate, [amount]) :: {:ok, number} | {:error, error}
  def npv(rate, amounts) when is_number(rate) and is_list(amounts) do
    npv(rate, amounts, [])
  end

  @doc "Same as `npv/2`, and additionally takes a `:precision` option. See `npv/2`."
  @spec npv(rate, [amount], [option]) :: {:ok, number} | {:error, error}
  def npv(_rate, [], _opts), do: {:error, :insufficient_data}

  def npv(rate, amounts, opts)
      when is_number(rate) and is_list(amounts) and is_list(opts) do
    opts = options(opts)

    with :ok <- check_rate(rate),
         :ok <- check_currency(amounts) do
      {:ok, round_value(present_value(periodic_flows(amounts), rate), opts)}
    end
  end

  @doc "Same as `npv/2`, but returns the value directly and raises `ArgumentError` on error."
  @spec npv!(rate, [amount]) :: number
  def npv!(rate, amounts), do: rate |> npv(amounts) |> unwrap!()

  # === MIRR — modified internal rate of return =============================

  @doc """
  Computes the **MIRR** — the modified internal rate of return for periodic
  `amounts`. It refines the idea behind IRR by letting you set two separate
  rates: positive flows are assumed to be reinvested at `reinvest_rate`, and
  negative flows are assumed to be financed at `finance_rate`.

  Because those assumptions are spelled out, MIRR has a closed form and a single
  answer, which sidesteps the multiple-root and convergence trouble that IRR can
  run into. As with `irr/1`, the series has to contain at least one positive
  amount and one negative one.

      iex> Finance.CashFlow.mirr([-120_000, 39_000, 30_000, 21_000, 37_000, 46_000], 0.10, 0.12)
      {:ok, 0.126094}
  """
  @spec mirr([amount], number, number, [option]) :: {:ok, rate} | {:error, error}
  def mirr(amounts, finance_rate, reinvest_rate, opts \\ [])
      when is_list(amounts) and is_number(finance_rate) and is_number(reinvest_rate) and
             is_list(opts) do
    opts = options(opts)

    with :ok <- check_currency(amounts) do
      values = Enum.map(amounts, &to_amount/1)
      n = length(values)

      cond do
        n < 2 -> {:error, :insufficient_data}
        not signed_both_ways?(values) -> {:error, :single_signed_flow}
        1 + finance_rate <= 0 or 1 + reinvest_rate <= 0 -> {:error, :undefined}
        true -> {:ok, round_value(modified_irr(values, finance_rate, reinvest_rate), opts)}
      end
    end
  end

  @doc "Same as `mirr/3`, but returns the rate directly and raises `ArgumentError` on error."
  @spec mirr!([amount], number, number, [option]) :: rate
  def mirr!(amounts, finance_rate, reinvest_rate, opts \\ []) do
    amounts |> mirr(finance_rate, reinvest_rate, opts) |> unwrap!()
  end

  defp modified_irr(values, finance_rate, reinvest_rate) do
    periods = length(values) - 1
    indexed = Enum.with_index(values)

    future_of_inflows =
      indexed
      |> Enum.filter(fn {value, _i} -> value > 0 end)
      |> Enum.reduce(0.0, fn {value, i}, acc ->
        acc + value * :math.pow(1 + reinvest_rate, periods - i)
      end)

    present_of_outflows =
      indexed
      |> Enum.filter(fn {value, _i} -> value < 0 end)
      |> Enum.reduce(0.0, fn {value, i}, acc -> acc + value * discount_factor(finance_rate, i) end)

    :math.pow(future_of_inflows / -present_of_outflows, 1 / periods) - 1
  end

  # === Dispatch & normalization ============================================

  # `xirr(first, second)` is `xirr(pairs, opts)` only when `first` is a list of
  # `{date, amount}` pairs and `second` is options; otherwise it's the two-list
  # `xirr(dates, amounts)` form. A `{date, amount}` pair is a 2-tuple, while a bare
  # date is a `%Date{}` or a `{y, m, d}` 3-tuple, so the head disambiguates.
  defp pairs?([]), do: true
  defp pairs?(list), do: match?([{_, _} | _], list)

  defp options?([]), do: true
  defp options?(list), do: Keyword.keyword?(list)

  # A discount rate at or below -100% has no meaningful `(1 + rate)^t`.
  defp check_rate(rate) when 1 + rate <= 0, do: {:error, :undefined}
  defp check_rate(_rate), do: :ok

  defp zip(dates, values, opts) when length(dates) == length(values) do
    dates |> Enum.zip(values) |> compute(opts)
  end

  defp zip(_dates, _values, _opts), do: {:error, :mismatched_lengths}

  defp compute(cash_flows, opts) do
    opts = options(opts)

    with {:ok, flows} <- normalize(cash_flows, Keyword.fetch!(opts, :basis)),
         :ok <- validate(flows) do
      resolve_solver(opts).solve(flows, opts)
    end
  end

  # Solve a prepared batch: hand the ready series to the solver in one
  # `solve_many/2` call, then reassemble results in the original order,
  # interleaving the series that failed preparation.
  defp solve_batch(prepared, opts) do
    ready = for {:ready, flows} <- prepared, do: flows
    stitch(prepared, resolve_solver(opts).solve_many(ready, opts))
  end

  defp stitch(prepared, solved) do
    {results, _} =
      Enum.map_reduce(prepared, solved, fn
        {:ready, _flows}, [result | rest] -> {result, rest}
        {:error, _reason} = error, acc -> {error, acc}
      end)

    results
  end

  defp prepare_dated(cash_flows, basis) when is_list(cash_flows) do
    with {:ok, flows} <- normalize(cash_flows, basis),
         :ok <- validate(flows) do
      {:ready, flows}
    end
  end

  defp prepare_periodic(amounts) when is_list(amounts) do
    with :ok <- check_currency(amounts) do
      flows = periodic_flows(amounts)

      case validate(flows) do
        :ok -> {:ready, flows}
        error -> error
      end
    end
  end

  # Parse dates, re-express each flow's time as the year fraction since the
  # earliest date under `basis`, and merge flows that share a period — same date,
  # or distinct dates a 30/360 basis maps to the same fraction.
  defp normalize([], _basis), do: {:error, :insufficient_data}

  defp normalize(cash_flows, basis) do
    amounts = Enum.map(cash_flows, fn {_date, amount} -> amount end)

    with :ok <- check_currency(amounts),
         {:ok, parsed} <- parse_dates(cash_flows) do
      min_date = parsed |> Enum.map(&elem(&1, 0)) |> Enum.min(Date)

      flows =
        parsed
        |> Enum.reduce(%{}, fn {date, amount}, acc ->
          period = Finance.DayCount.year_fraction(min_date, date, basis)
          Map.update(acc, period, amount, &(&1 + amount))
        end)
        |> Enum.sort()

      {:ok, flows}
    end
  end

  # A malformed amount is a caller bug, left to raise rather than be reported as an
  # :invalid_date.
  defp parse_dates(cash_flows) do
    Enum.reduce_while(cash_flows, {:ok, []}, fn {date, amount}, {:ok, acc} ->
      case to_date(date) do
        {:ok, parsed_date} -> {:cont, {:ok, [{parsed_date, to_amount(amount)} | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_date}}
      end
    end)
  end

  defp periodic_flows(amounts) do
    amounts
    |> Enum.with_index()
    |> Enum.map(fn {amount, index} -> {index / 1, to_amount(amount)} end)
  end

  defp to_date(%Date{} = date), do: {:ok, date}
  defp to_date({y, m, d}), do: Date.from_erl({y, m, d})

  defp validate([_, _ | _] = flows) do
    if signed_both_ways?(Enum.map(flows, &elem(&1, 1))),
      do: :ok,
      else: {:error, :single_signed_flow}
  end

  defp validate(_flows), do: {:error, :insufficient_data}

  defp signed_both_ways?(amounts) do
    Enum.any?(amounts, &(&1 > 0)) and Enum.any?(amounts, &(&1 < 0))
  end

  # Amounts as floats in chronological order: `{date, amount}` pairs are sorted by
  # date, a bare list of amounts is taken as given.
  defp amounts_in_order(cash_flows) do
    if pairs?(cash_flows) do
      cash_flows
      |> Enum.sort_by(fn {date, _amount} -> to_comparable_date(date) end, Date)
      |> Enum.map(fn {_date, amount} -> to_amount(amount) end)
    else
      Enum.map(cash_flows, &to_amount/1)
    end
  end

  defp to_comparable_date(%Date{} = date), do: date
  defp to_comparable_date({y, m, d}), do: Date.new!(y, m, d)

  # Count the sign changes in a sequence, ignoring zeros (a zero flow is neither a
  # crossing nor a break).
  defp sign_changes(amounts) do
    amounts
    |> Enum.map(&sign/1)
    |> Enum.reject(&(&1 == 0))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a != b end)
  end

  defp sign(amount) when amount > 0, do: 1
  defp sign(amount) when amount < 0, do: -1
  defp sign(_amount), do: 0
end
