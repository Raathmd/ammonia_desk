alias TradingDesk.Data.LiveState
alias TradingDesk.Solver.Port

vars = LiveState.get()
IO.puts("Running Monte Carlo with 100 scenarios...")
{:ok, dist} = Port.monte_carlo(vars, 100)

IO.puts("\nMonte Carlo Results:")
IO.puts("  Scenarios: #{dist.n_scenarios}")
IO.puts("  Feasible: #{dist.n_feasible}")
IO.puts("  Infeasible: #{dist.n_infeasible}")
IO.puts("  Mean: $#{Float.round(dist.mean, 2)}")
IO.puts("  StdDev: $#{Float.round(dist.stddev, 2)}")
IO.puts("  Signal: #{dist.signal}")
IO.puts("  P5: $#{Float.round(dist.p5, 2)}")
IO.puts("  P25: $#{Float.round(dist.p25, 2)}")
IO.puts("  P50: $#{Float.round(dist.p50, 2)}")
IO.puts("  P75: $#{Float.round(dist.p75, 2)}")
IO.puts("  P95: $#{Float.round(dist.p95, 2)}")
IO.puts("  Min: $#{Float.round(dist.min, 2)}")
IO.puts("  Max: $#{Float.round(dist.max, 2)}")
