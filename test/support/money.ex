defmodule Money do
  @moduledoc false
  # A minimal stand-in for ex_money's `%Money{}` — the same shape (a currency atom
  # and a `Decimal` amount) — so the suite can exercise the ex_money code path
  # without pulling ex_money (and its Decimal 2.x pin) into finance's own deps.
  defstruct [:currency, :amount]
end
