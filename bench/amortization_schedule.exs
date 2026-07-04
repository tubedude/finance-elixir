# Benchmark: float vs Decimal `amortization_schedule`.
#
# The Decimal path (given Decimal inputs) is exact to the cent but does more work
# — Decimal arithmetic plus `(1+r)^n` by repeated multiplication. This measures
# the runtime and memory cost of that exactness across typical loan terms.
#
# Run with:  mix run bench/amortization_schedule.exs

annual_rate = 0.06
monthly = annual_rate / 12
pv = 300_000

dec_monthly = Decimal.div(Decimal.new("0.06"), Decimal.new(12))
dec_pv = Decimal.new(pv)

# Number of monthly periods for a few common loan terms.
inputs = %{
  "1yr (12 periods)" => 12,
  "5yr (60 periods)" => 60,
  "15yr (180 periods)" => 180,
  "30yr (360 periods)" => 360
}

Benchee.run(
  %{
    "float" => fn n -> Finance.TVM.amortization_schedule(monthly, n, pv) end,
    "decimal" => fn n -> Finance.TVM.amortization_schedule(dec_monthly, n, dec_pv) end
  },
  inputs: inputs,
  time: 3,
  memory_time: 1,
  warmup: 1
)
