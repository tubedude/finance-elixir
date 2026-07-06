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
  | `:actual_actual` | Actual/Actual ISDA | days apportioned across each calendar year by its length |
  | `:thirty_360`    | 30/360 US (NASD)   | 30-day months, day 31 pulled to 30 (Excel `DAYS360` US) |
  | `:thirty_e_360`  | 30E/360 Eurobond   | as 30/360, day 31 pulled to 30 on both ends |

  ## Custom conventions

  `:basis` also accepts any **module** implementing this behaviour — a single
  `year_fraction/2` callback. Conventions that need a holiday calendar this
  dependency-free library can't carry (Brazilian Business/252, say) live in your
  own app and plug in the same way:

      defmodule MyApp.Business252 do
        @behaviour Finance.DayCount
        @impl true
        def year_fraction(date1, date2) do
          MyApp.Calendar.business_days_between(date1, date2) / 252
        end
      end

      Finance.CashFlow.xirr(flows, basis: MyApp.Business252)
  """

  @doc "The year fraction from `date1` to `date2`, where `date1 <= date2`."
  @callback year_fraction(date1 :: Date.t(), date2 :: Date.t()) :: float

  @bases [:actual_365, :actual_360, :actual_actual, :thirty_360, :thirty_e_360]

  @type basis :: :actual_365 | :actual_360 | :actual_actual | :thirty_360 | :thirty_e_360 | module

  @doc "The built-in `:basis` atoms."
  @spec bases() :: [atom]
  def bases, do: @bases

  @doc """
  The year fraction from `date1` to `date2` under `basis` — a built-in atom or a
  module implementing `Finance.DayCount`. Assumes `date1 <= date2`.

      iex> Finance.DayCount.year_fraction(~D[2019-01-01], ~D[2020-01-01], :actual_365)
      1.0

      iex> Finance.DayCount.year_fraction(~D[2019-01-01], ~D[2020-01-01], :actual_360)
      1.0138888888888888

      iex> Finance.DayCount.year_fraction(~D[2019-01-01], ~D[2020-01-01], :thirty_360)
      1.0
  """
  @spec year_fraction(Date.t(), Date.t(), basis) :: float
  def year_fraction(date1, date2, :actual_365), do: Date.diff(date2, date1) / 365.0
  def year_fraction(date1, date2, :actual_360), do: Date.diff(date2, date1) / 360.0
  def year_fraction(date1, date2, :actual_actual), do: actual_actual(date1, date2)
  def year_fraction(date1, date2, :thirty_360), do: thirty(date1, date2, :us) / 360.0
  def year_fraction(date1, date2, :thirty_e_360), do: thirty(date1, date2, :euro) / 360.0

  def year_fraction(date1, date2, module) when is_atom(module) do
    module.year_fraction(date1, date2)
  end

  # Actual/Actual (ISDA): each calendar year the interval touches contributes its
  # own days over its own length (365 or 366), so leap years are weighted exactly.
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
  # start already sits on the 30th.
  defp adjust(d1, d2, :us) do
    d1 = min(d1, 30)
    {d1, if(d2 == 31 and d1 == 30, do: 30, else: d2)}
  end

  # European (30E/360): pull a day-31 to 30 on both ends, unconditionally.
  defp adjust(d1, d2, :euro), do: {min(d1, 30), min(d2, 30)}
end
