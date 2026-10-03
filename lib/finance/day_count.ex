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
  | `:thirty_360`    | 30/360 US (NASD)   | every month counts as 30 days, every year as 360; a day 31 is treated as day 30 (US rule below) |
  | `:thirty_e_360`  | 30E/360 Eurobond   | same, but a day 31 is always treated as day 30 |

  ## How 30/360 counts days

  The 30/360 conventions ignore the real calendar. They count the days between
  two dates as if every month had 30 days:

      days = 360 * (year2 - year1) + 30 * (month2 - month1) + (day2 - day1)

  and then divide by 360. For example, `Jan 15 → Mar 10` is
  `30 * 2 + (10 - 15) = 55` days, so the year fraction is `55 / 360`. The real
  calendar has 54 days between those dates (non-leap year), so the two counts differ.

  The only difference between the US and Eurobond variants is what happens when a
  date falls on day 31, because "day 31" does not exist in a 30-day month:

    * **US (`:thirty_360`)**: a start date on day 31 becomes day 30. An end date on
      day 31 becomes day 30 only if the start date is on day 30 or 31. Otherwise it
      stays 31.
    * **Eurobond (`:thirty_e_360`)**: a day 31 becomes day 30, on both the start
      and the end date.

  ## Which variant you get

  The names "Actual/Actual" and "30/360" each cover several slightly different
  methods. These are the ones this library uses:

    * `:actual_actual` is **Actual/Actual (ISDA)**. Each calendar year in the span
      counts its own days over its own length (365 or 366), so leap years are
      handled exactly. It is a good choice for irregular cash flows. It does *not*
      match Excel's `YEARFRAC(_, 1)`, which uses an average year length instead.
    * `:thirty_360` is the **US/NASD** rule, the same as Excel's `DAYS360` in US
      mode. It does not give the end of February any special treatment. (Another
      variant, called SIA, does. This library does not include it.)
    * `:thirty_e_360` also leaves February alone. So `Feb 28 → Mar 1` counts as
      three days (28 → 30 → 1). That is how the convention is defined, not a bug.

  ## Two dates can give the same result

  Under 30/360, day 31 becomes day 30. So the 30th and the 31st of the same month
  give the same year fraction. `xirr`/`xnpv` add together flows that land on the
  same year fraction. If a series has only two flows, on the 30th and the 31st,
  they become one flow, and the result is `{:error, :insufficient_data}`.

  ## Custom conventions

  `:basis` also accepts a **module** that implements this behaviour. The module
  needs one function, `year_fraction/3`. Its third argument is a keyword list of
  settings, such as payment frequency or a maturity date. Methods like
  Actual/Actual ICMA or 30E/360 ISDA need these.

  To give your module settings, pass `:basis` as a `{module, settings}` tuple.
  `xirr`/`xnpv`/`xnfv` then pass `settings` to every `year_fraction/3` call:

      Finance.CashFlow.xirr(flows, basis: {MyApp.ActualActualIcma, frequency: 2})

  A plain module (no tuple) gets `[]`. The built-in conventions take no settings,
  so a tuple such as `{:thirty_360, []}` raises an error.

  Some conventions need a holiday calendar. One example is Brazil's Business/252,
  where the fraction is `business_days(from, to) / 252`, counted against the
  ANBIMA holiday calendar. This library does not include holiday calendars, so
  you write that module in your app.

  Load the market's published holidays into a fixed set of business days, and
  count against that set. This is better than working out holidays at runtime.
  [Tempo](https://hex.pm/packages/ex_tempo) can build the set from an `.ics` file
  and update it when new dates are published:

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

  @typedoc """
  A `:basis`: a built-in convention, a module implementing `Finance.DayCount`, or
  `{module, settings}` to pass that module a keyword list of settings.
  """
  @type basis :: builtin | module | {module, keyword}

  @doc "The built-in `:basis` atoms."
  @spec bases() :: [builtin]
  def bases, do: @bases

  @doc """
  The year fraction from `date1` to `date2` under `basis`. Assumes
  `date1 <= date2`.

  `basis` is a built-in atom, a module implementing `Finance.DayCount`, or a
  `{module, settings}` tuple. A custom module receives `opts`, merged over the
  tuple's `settings` when there is one. The built-in conventions ignore `opts`.

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

  # `{module, settings}`: the settings go to the module, with any `opts` passed
  # here taking precedence.
  def year_fraction(date1, date2, {module, settings}, opts) when is_atom(module) do
    module.year_fraction(date1, date2, Keyword.merge(settings, opts))
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

  # 30/360 day count: returns a whole number of days, counting every month as 30
  # days and every year as 360. The caller divides it by 360 to get years.
  # Example: Jan 15 -> Mar 10 is 30 * 2 + (10 - 15) = 55 days.
  # Day 31 does not exist in a 30-day month, so `adjust/3` first rewrites it to 30.
  # That rewrite is the only thing that differs between the US and European rules.
  defp thirty(%Date{year: y1, month: m1, day: d1}, %Date{year: y2, month: m2, day: d2}, variant) do
    {d1, d2} = adjust(d1, d2, variant)
    360 * (y2 - y1) + 30 * (m2 - m1) + (d2 - d1)
  end

  # US/NASD:
  #   1. A start on day 31 becomes day 30.
  #   2. An end on day 31 becomes day 30 only if the start is now day 30
  #      (it was 30 or 31 to begin with). Otherwise the end stays 31.
  # Do step 1 first: step 2 reads the already-adjusted start.
  # Example: Jan 30 -> Mar 31 counts as Jan 30 -> Mar 30 (60 days), but
  # Jan 15 -> Mar 31 keeps the 31 (76 days).
  defp adjust(d1, d2, :us) do
    d1 = min(d1, 30)
    {d1, if(d2 == 31 and d1 == 30, do: 30, else: d2)}
  end

  # European (30E/360): a day 31 becomes day 30 on both the start and the end,
  # whatever the other date is.
  defp adjust(d1, d2, :euro), do: {min(d1, 30), min(d2, 30)}
end
