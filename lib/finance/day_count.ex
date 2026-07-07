defmodule Finance.DayCount do
  @moduledoc """
  Day-count conventions — the fraction of a year between two dates.

  Dated cash-flow functions (`Finance.CashFlow.xirr/2`, `xnpv/2`) discount each
  flow by `(1 + rate)^t`, where `t` is the year fraction from the earliest date to
  the flow's date. Which fraction to use depends on the market convention the
  instrument is quoted under, selected with the `:basis` option.

  Five conventions ship built in, named by atom:

  | `:basis`         | convention         | year fraction |
  | ---------------- | ------------------ | ------------- |
  | `:actual_365`    | Actual/365 Fixed   | days / 365 (the default, matching spreadsheet `XIRR`) |
  | `:actual_360`    | Actual/360         | days / 360 |
  | `:actual_actual` | Actual/Actual ISDA | each calendar year's days over its own length (365 or 366) |
  | `:thirty_360`    | 30/360 US (NASD)   | 30-day months, day 31 pulled to 30 |
  | `:thirty_e_360`  | 30E/360 Eurobond   | as 30/360, day 31 pulled to 30 on both ends |

  Both "Actual/Actual" and "30/360" name more than one method, so to be precise
  about which ones ship:

    * `:actual_actual` is **Actual/Actual (ISDA)** — the sensible choice for
      irregular cash flows. Each calendar year the span touches contributes its own
      days over its own length, so leap years are weighted exactly. It is *not*
      Excel's `YEARFRAC(_, 1)`, which uses a different average-year-length method.
    * `:thirty_360` is the basic **US/NASD** rule (Excel `DAYS360` US): day 31 is
      pulled to 30, with **no** end-of-February adjustment (that EOM behaviour is a
      separate SIA variant, not shipped).
    * `:thirty_e_360` leaves February alone, so `Feb 28 → Mar 1` counts three days.
      That is a known property of the convention, not a bug.

  Because the 30/360 conventions round day-of-month, two *distinct* dates can map to
  the same year fraction (e.g. the 30th and 31st of a month). `xirr`/`xnpv` merge
  flows that share a period, so under a 30/360 basis a two-flow series on adjacent
  such dates collapses to one period — and can then report `:insufficient_data`.

  ## Custom conventions

  `:basis` also accepts any **module** implementing this behaviour — a single
  `year_fraction/3` callback. The third argument carries convention-specific
  parameters (coupon-period boundaries, frequency, a maturity flag) that methods
  like Actual/Actual ICMA or 30E/360 ISDA need; the built-in static conventions
  ignore it.

  A convention that needs a holiday calendar this dependency-free library can't
  carry — Brazil's Business/252, where the fraction is `business_days(from, to)
  / 252` against the ANBIMA calendar — lives in your app. Prefer materializing the
  market's published holidays into a static business-day set and counting against
  it (a library like [Tempo](https://hex.pm/packages/ex_tempo) can build that set
  from an `.ics` file and refresh it when new dates are published) over computing
  it at runtime:

      defmodule MyApp.Business252 do
        @behaviour Finance.DayCount
        @impl true
        def year_fraction(from, to, _opts) do
          MyApp.Holidays.business_days_between(from, to) / 252
        end
      end

      Finance.CashFlow.xirr(flows, basis: MyApp.Business252)
  """

  @doc """
  The year fraction from `from` to `to`, where `from <= to`. `opts` carries
  convention-specific parameters; the built-in conventions ignore it.
  """
  @callback year_fraction(from :: Date.t(), to :: Date.t(), opts :: keyword) :: float

  @bases [:actual_365, :actual_360, :actual_actual, :thirty_360, :thirty_e_360]

  @typedoc "A built-in day-count convention."
  @type builtin :: :actual_365 | :actual_360 | :actual_actual | :thirty_360 | :thirty_e_360

  @typedoc "A `:basis`: a built-in convention or a module implementing `Finance.DayCount`."
  @type basis :: builtin | module

  @doc "The built-in `:basis` atoms."
  @spec bases() :: [builtin]
  def bases, do: @bases

  @doc """
  The year fraction from `date1` to `date2` under `basis` — a built-in atom or a
  module implementing `Finance.DayCount`. Assumes `date1 <= date2`. `opts` is
  passed through to a custom module and ignored by the built-in conventions.

      iex> Finance.DayCount.year_fraction(~D[2019-01-01], ~D[2020-01-01], :actual_365)
      1.0

      iex> Finance.DayCount.year_fraction(~D[2019-01-01], ~D[2020-01-01], :actual_360)
      1.0138888888888888

      iex> Finance.DayCount.year_fraction(~D[2019-01-01], ~D[2020-01-01], :thirty_360)
      1.0

  30E/360 leaves February untouched, so `Feb 28 → Mar 1` is three days, not one:

      iex> Finance.DayCount.year_fraction(~D[2019-02-28], ~D[2019-03-01], :thirty_e_360)
      0.008333333333333333
  """
  @spec year_fraction(Date.t(), Date.t(), basis, keyword) :: float
  def year_fraction(date1, date2, basis, opts \\ [])
  def year_fraction(date1, date2, :actual_365, _opts), do: Date.diff(date2, date1) / 365.0
  def year_fraction(date1, date2, :actual_360, _opts), do: Date.diff(date2, date1) / 360.0
  def year_fraction(date1, date2, :actual_actual, _opts), do: actual_actual(date1, date2)
  def year_fraction(date1, date2, :thirty_360, _opts), do: thirty(date1, date2, :us) / 360.0
  def year_fraction(date1, date2, :thirty_e_360, _opts), do: thirty(date1, date2, :euro) / 360.0

  def year_fraction(date1, date2, module, opts) when is_atom(module) do
    module.year_fraction(date1, date2, opts)
  end

  # Actual/Actual (ISDA): each calendar year the interval touches contributes its
  # own days over its own length (365 or 366), so leap years are weighted exactly.
  # A multi-year span sums a partial first year, each whole intervening year (which
  # is exactly 1.0), and a partial last year — never one denominator for the span.
  defp actual_actual(%Date{year: year} = date1, %Date{year: year} = date2) do
    Date.diff(date2, date1) / days_in_year(year)
  end

  defp actual_actual(%Date{year: y1} = date1, %Date{year: y2} = date2) do
    stub1 = Date.diff(Date.new!(y1 + 1, 1, 1), date1) / days_in_year(y1)
    stub2 = Date.diff(date2, Date.new!(y2, 1, 1)) / days_in_year(y2)
    stub1 + (y2 - y1 - 1) + stub2
  end

  defp days_in_year(year), do: if(Calendar.ISO.leap_year?(year), do: 366, else: 365)

  # 30/360 day count: whole months count as 30 days. The day-of-month adjustments
  # are the only thing that differs between the US and European conventions.
  defp thirty(%Date{year: y1, month: m1, day: d1}, %Date{year: y2, month: m2, day: d2}, variant) do
    {d1, d2} = adjust(d1, d2, variant)
    360 * (y2 - y1) + 30 * (m2 - m1) + (d2 - d1)
  end

  # US/NASD: pull a day-31 start to 30; then pull a day-31 end to 30 only when the
  # start already sits on the 30th. Order matters — the end rule depends on the
  # adjusted start.
  defp adjust(d1, d2, :us) do
    d1 = min(d1, 30)
    {d1, if(d2 == 31 and d1 == 30, do: 30, else: d2)}
  end

  # European (30E/360): pull a day-31 to 30 on both ends, unconditionally.
  defp adjust(d1, d2, :euro), do: {min(d1, 30), min(d2, 30)}
end
