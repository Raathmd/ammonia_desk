# Ammonia Desk — Barge Trading Scenario Engine

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  TRADER (Phoenix LiveView)                          │
│  - 18 variable sliders with live API values         │
│  - Override any variable, solve instantly            │
│  - Monte Carlo distribution view                    │
│  - Save/compare scenarios                           │
│  - Auto-runner signal: GO / CAUTIOUS / NO-GO        │
└──────────────┬──────────────────────────────────────┘
               │ LiveView events
┌──────────────▼──────────────────────────────────────┐
│  ELIXIR (Domain + Orchestration)                    │
│                                                     │
│  Data.Poller      — USGS, NOAA, USACE, EIA APIs    │
│  Data.LiveState   — Current 18-variable state       │
│  Scenarios.Store  — Saved scenario comparison       │
│  Scenarios.AutoRunner — Continuous Monte Carlo      │
│  Solver.Port      — Erlang Port to Zig binary       │
│                                                     │
│  Variables        — 18-var struct + binary protocol  │
└──────────────┬──────────────────────────────────────┘
               │ stdin/stdout (4-byte length-prefixed packets)
               │ 20 f64s in → result struct out
┌──────────────▼──────────────────────────────────────┐
│  ZIG (Solver)                                       │
│                                                     │
│  - Receives raw variable values                     │
│  - Frames LP model (constraints, objective)         │
│  - Calls HiGHS C API via dlopen                     │
│  - Returns: status, tons, profit, shadow prices     │
│  - Monte Carlo: correlated scenario generation      │
│                                                     │
│  All math in one place. No domain knowledge split.  │
└──────────────┬──────────────────────────────────────┘
               │ dlopen / dlsym
┌──────────────▼──────────────────────────────────────┐
│  HiGHS (C API)                                      │
│  - LP / MIP / QP solver                             │
│  - Simplex + interior point                         │
│  - Solves in microseconds for this problem size     │
└─────────────────────────────────────────────────────┘
```

## The 18 Variables

| #  | Variable           | Source         | Group       |
|----|--------------------|----------------|-------------|
| 1  | River flow         | USGS API       | Environment |
| 2  | River stage        | USGS API       | Environment |
| 3  | Lock status        | USACE API      | Environment |
| 4  | Lock delays        | USACE API      | Environment |
| 5  | Temperature        | NOAA API       | Environment |
| 6  | Wind               | NOAA API       | Environment |
| 7  | Precipitation      | NOAA API       | Environment |
| 8  | Visibility/Fog     | NOAA API       | Environment |
| 9  | Terminal inventory  | Internal       | Operations  |
| 10 | Terminal capacity   | Internal       | Operations  |
| 11 | Terminal outages    | Internal       | Operations  |
| 12 | Barge capacity     | Internal       | Operations  |
| 13 | Transit times      | Historical     | Operations  |
| 14 | Contracts          | Internal       | Commercial  |
| 15 | Ammonia prices     | Market         | Commercial  |
| 16 | Natural gas prices | EIA API        | Commercial  |
| 17 | Freight rates      | Brokers        | Commercial  |
| 18 | Working capital    | Finance        | Commercial  |

## Two Operating Modes

**Automated** — AutoRunner polls live data, generates 1000 correlated
scenarios per hour, solves all via HiGHS, reports profit distribution
and trading signal. No human interaction needed.

**Interactive** — Trader sees live values, overrides any variable via
slider, hits Solve for instant result (<100ms round trip). Can run
Monte Carlo around their overrides. Save and compare scenarios.

## Running

```bash
# Build solver
cd native && zig build-exe solver.zig -lc

# Install deps and start
mix deps.get
mix phx.server

# Open http://localhost:4000
```

## Key Design Decisions

1. **Zig frames the model, not Elixir** — all math (draft penalties,
   transit adjustments, margin calculations, constraint construction)
   lives in Zig alongside the solver. Elixir sends raw values, gets
   back results. No domain logic split across languages.

2. **Port, not NIF** — process isolation. If the solver crashes, the
   BEAM survives. Upgrade to dirty NIF only if sub-ms latency needed.

3. **Correlated scenario generation in Zig** — weather drives river
   drives locks drives barges drives prices. Causal chains, not
   independent random sampling. Rejection filter kills impossible
   combinations.

4. **Binary protocol** — 20 little-endian f64s in, result struct out.
   4-byte big-endian length prefix (Erlang :packet 4). Zero parsing
   overhead.
