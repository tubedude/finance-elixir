defmodule Finance.Cashflows do
  def new(dates, values) do
    Enum.zip(dates, values)
    |> Enum.map &Finance.Cashflow.new(&1)
  end
end
