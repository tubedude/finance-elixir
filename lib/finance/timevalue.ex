defmodule Finance.TimeValue do

  @days_in_year 365

  defp date_diff(d1, d2) do
    (Date.to_days(d2) - Date.to_days(d1)) / @days_in_year
  end

  def pv(cashflow, present_date, rate) do
    cashflow.value / :math.power(1 + rate, date_diff(present_date, cashflow.date))
  end
end
