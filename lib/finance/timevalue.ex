defmodule Finance.TimeValue do

  alias Timex.Date

  @days_in_year 365

  def date_diff(d1, d2) do
    (Date.to_days(d2) - Date.to_days(d1))
  end

  def discount_factor(d1, d2, rate) do
    :math.pow(1 + rate, date_diff(d1, d2) / @days_in_year)
  end

  def pv(cashflow, present_date, rate) when not is_list(cashflow) do
    cashflow.value / discount_factor(present_date, cashflow.date, rate)
  end

  def pv(cashflows, present_date, rate) do
    cashflows
    |> Enum.map &pv(&1, present_date,rate)
    |> Enum.sum
  end

end
