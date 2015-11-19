defmodule Finance.Cashflow do
  defstruct date: nil, value: nil

  def new({date, value}) do
    new(date, value)
  end

  def new(date, value) do
    %Finance.Cashflow{date: date, value: value}
  end
end
