# Benchmark: float vs Decimal vs integer-cents `amortization_schedule`.
#
# The Decimal path (given Decimal inputs) is exact to the cent but does bignum
# arithmetic. Integer-cents is the alternative: hold money as whole cents, so
# add/sub are exact integer ops and only the interest (balance × rate) needs
# rounding — exact to the cent like Decimal, but much cheaper.
#
# Run with:  mix run bench/amortization_schedule.exs

defmodule IntCents do
  @moduledoc false

  # Amortization schedule in integer cents (money scaled by 100). Reuses TVM.pmt
  # for the level payment, then walks a running integer-cent balance. Only the
  # interest (balance × rate) needs rounding; every other step is exact integer
  # arithmetic. The final row pays off whatever remains, so the balance ends at 0.
  def schedule(rate, nper, pv) do
    {:ok, payment} = Finance.TVM.pmt(rate, nper, pv)
    payment_cents = round(payment * 100)
    opening = round(pv * 100)

    {rows, _balance} =
      Enum.map_reduce(1..nper, opening, fn period, balance ->
        interest = round(-balance * rate)
        principal = if period == nper, do: -balance, else: payment_cents - interest
        new_balance = balance + principal
        row_payment = if period == nper, do: interest + principal, else: payment_cents

        {%{
           period: period,
           payment: row_payment,
           interest: interest,
           principal: principal,
           balance: new_balance
         }, new_balance}
      end)

    rows
  end
end

annual_rate = 0.06
monthly = annual_rate / 12
pv = 300_000

dec_monthly = Decimal.div(Decimal.new("0.06"), Decimal.new(12))
dec_pv = Decimal.new(pv)

# --- correctness: integer-cents must match the Decimal schedule to the cent ---
{:ok, dec_rows} = Finance.TVM.amortization_schedule(dec_monthly, 360, dec_pv)
int_rows = IntCents.schedule(monthly, 360, pv)

matches? =
  Enum.zip(dec_rows, int_rows)
  |> Enum.all?(fn {d, i} ->
    Decimal.equal?(d.balance, Decimal.div(Decimal.new(i.balance), 100)) and
      Decimal.equal?(d.interest, Decimal.div(Decimal.new(i.interest), 100))
  end)

IO.puts("integer-cents matches Decimal to the cent (360 periods): #{matches?}")

IO.puts(
  "last balance — decimal: #{Decimal.to_string(List.last(dec_rows).balance)}, " <>
    "int-cents: #{List.last(int_rows).balance} cents\n"
)

# --- benchmark ---
inputs = %{
  "1yr (12 periods)" => 12,
  "5yr (60 periods)" => 60,
  "15yr (180 periods)" => 180,
  "30yr (360 periods)" => 360
}

Benchee.run(
  %{
    "float" => fn n -> Finance.TVM.amortization_schedule(monthly, n, pv) end,
    "decimal" => fn n -> Finance.TVM.amortization_schedule(dec_monthly, n, dec_pv) end,
    "integer-cents" => fn n -> IntCents.schedule(monthly, n, pv) end
  },
  inputs: inputs,
  time: 3,
  memory_time: 1,
  warmup: 1
)
