# Building HiGHS with Zig

No cmake. No Python. Just Zig compiling the HiGHS C/C++ source directly.

## Version Info

| Component | Version |
|-----------|---------|
| **HiGHS** | 1.13.1 (git: ERGO-Code/HiGHS, commit f3cf9ff) |
| **Zig** | 0.15.2+ (or 0.16.0-dev) — used as C/C++ compiler |
| **Solver** | v2 — generic data-driven LP (model descriptor protocol) |
| **Objective modes** | max_profit, min_cost, max_roi, cvar_adjusted, min_risk |

## Source Location

HiGHS source is included in the project at `native/HiGHS/`.
The `HConfig.h` header is pre-generated in that directory.

## 1. Build HiGHS static library

From the project root:

```bash
cd native/HiGHS
mkdir -p build

# Include paths
INC="-I. \
  -I./highs -I./highs/interfaces -I./highs/io -I./highs/io/filereader \
  -I./highs/ipm -I./highs/ipm/ipx -I./highs/ipm/basiclu \
  -I./highs/lp_data -I./highs/mip -I./highs/model -I./highs/parallel \
  -I./highs/pdlp -I./highs/pdlp/cupdlp -I./highs/presolve \
  -I./highs/qpsolver -I./highs/simplex -I./highs/test_kkt -I./highs/util \
  -I./extern -I./extern/pdqsort -I./extern/zstr"

FLAGS="-O2 -DNDEBUG -DCUPDLP_CPU"

# Compile all C++ source files (.cpp)
for f in $(find highs -name "*.cpp" -not -path "*/hipo/*"); do
  echo "C++ $f"
  zig c++ -std=c++17 $FLAGS $INC -c "$f" -o "build/$(echo $f | tr '/' '_').o"
done

# Compile all IPX files (.cc)
for f in $(find highs/ipm/ipx -name "*.cc"); do
  echo "CC  $f"
  zig c++ -std=c++17 $FLAGS $INC -c "$f" -o "build/$(echo $f | tr '/' '_').o"
done

# Compile C files (basiclu + cupdlp)
for f in $(find highs/ipm/basiclu -name "*.c") \
         $(find highs/pdlp/cupdlp -name "*.c" -not -path "*/cuda/*"); do
  echo "C   $f"
  zig cc $FLAGS $INC -c "$f" -o "build/$(echo $f | tr '/' '_').o"
done

# Create static library
ar rcs build/libhighs.a build/*.o
echo ""
echo "Built: build/libhighs.a ($(ls build/*.o | wc -l) object files)"
```

## 2. Install headers and library

```bash
sudo cp build/libhighs.a /usr/local/lib/
sudo cp highs/interfaces/highs_c_api.h /usr/local/include/
sudo cp highs/lp_data/HighsCallbackStruct.h /usr/local/include/
```

## 3. Build the solver (static linked)

```bash
cd trading_desk/native

zig build-exe solver.zig \
  -lhighs -lstdc++ \
  -L/usr/local/lib \
  -lc
```

This produces a **single self-contained binary**. No `.so` files,
no `dlopen`, no library path issues. Copy it anywhere and it runs.

## 4. Verify

```bash
./native/solver
# Solver starts and waits for Erlang Port binary protocol on stdin.
# It will exit cleanly when stdin closes.
```

## Architecture

The solver is **generic and data-driven**. It does NOT contain any
product-group-specific code. All domain knowledge (routes, constraints,
perturbation specs) is sent from Elixir as a binary **model descriptor**
with each solve request.

### Binary Protocol

```
Request:  <<cmd::8, payload::binary>>
  cmd 1 = single solve:   model_descriptor + variables
  cmd 2 = monte carlo:    n_scenarios(u32) + model_descriptor + center_variables

Response: <<status::8, payload::binary>>
  status 0 = ok, 1 = infeasible, 2 = error
```

### Model Descriptor Format

```
Header:     n_vars(u16) n_routes(u8) n_constraints(u8) obj_mode(u8) lambda(f64) profit_floor(f64)
Routes:     R × [sell_var_idx(u8) buy_var_idx(u8) freight_var_idx(u8) transit_cost(f64) transit_days(f64) unit_cap(f64)]
Constraints: C × [ctype(u8) bound_var_idx(u8) bound_min_idx(u8) outage_idx(u8) outage_factor(f64) n_routes(u8) route_indices(u8×N) coefficients(f64×N if custom)]
Perturbations: V × [stddev(f64) lo(f64) hi(f64) n_corr(u8) correlations(u8+f64 × n_corr)]
```

### Objective Modes

| Code | Mode | Description |
|------|------|-------------|
| 0 | max_profit | Maximize Σ(margin × tons) |
| 1 | min_cost | Minimize Σ(cost × tons) |
| 2 | max_roi | Maximize profit / cost (Charnes-Cooper) |
| 3 | cvar_adjusted | Maximize profit - λ × CVaR₅ |
| 4 | min_risk | Minimize CVaR₅ s.t. profit ≥ floor |

### Constraint Types

| Code | Type | Behaviour |
|------|------|-----------|
| 0 | CT_SUPPLY | Σ(route_tons) ≤ bound |
| 1 | CT_DEMAND | Σ(route_tons) ≤ bound (with optional min) |
| 2 | CT_FLEET | Σ(tons / unit_cap) ≤ bound |
| 3 | CT_CAPITAL | Σ(cost_per_ton × tons) ≤ bound |
| 4 | CT_CUSTOM | Σ(coeff × tons) ≤ bound |

## Cross-compile (optional)

Build for Linux ARM64 from any machine:

```bash
# In step 1, add target flag:
zig c++ -std=c++17 -target aarch64-linux-gnu $FLAGS $INC -c "$f" -o "build/..."
zig cc -target aarch64-linux-gnu $FLAGS $INC -c "$f" -o "build/..."

# In step 3:
zig build-exe solver.zig -target aarch64-linux-gnu -lhighs -lstdc++ -L./build -lc
```

## Troubleshooting

**"undefined reference to ..."** during step 3:
You're missing object files. Check that all `.cpp`, `.cc`, and `.c`
files compiled without errors in step 1.

**"HConfig.h not found"**:
Make sure `HConfig.h` is in the HiGHS root directory (same level as
the `highs/` folder). It's pre-generated in `native/HiGHS/HConfig.h`.

**macOS: "library not found for -lstdc++"**:
Use `-lc++` instead of `-lstdc++` on macOS.
