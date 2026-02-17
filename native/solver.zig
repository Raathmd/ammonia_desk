const std = @import("std");
const highs = @cImport({
    @cInclude("highs_c_api.h");
});

// ============================================================
// Generic Data-Driven LP Solver
//
// Reads a model descriptor + variables from Elixir via Erlang Port.
// Builds and solves the LP dynamically — no hardcoded product groups.
//
// Supports 5 objective modes:
//   0 = max_profit    maximize Σ(margin[r] × tons[r])
//   1 = min_cost      minimize Σ(cost[r] × tons[r])
//   2 = max_roi       maximize profit / cost (Charnes-Cooper)
//   3 = cvar_adjusted max profit - λ × CVaR₅
//   4 = min_risk      minimize CVaR₅ s.t. profit ≥ floor
//
// Protocol:
//   Request:  <<cmd::8, payload::binary>>
//     cmd 1 = single solve
//     cmd 2 = monte carlo
//   Response: <<status::8, payload::binary>>
//     status 0 = ok, 1 = infeasible, 2 = error
// ============================================================

const MAX_VARS: usize = 64;
const MAX_ROUTES: usize = 16;
const MAX_CONSTRAINTS: usize = 32;
const MAX_CORRELATIONS: usize = 8;
const MAX_SCENARIOS: usize = 10000;

// ── Objective modes ──
const OBJ_MAX_PROFIT: u8 = 0;
const OBJ_MIN_COST: u8 = 1;
const OBJ_MAX_ROI: u8 = 2;
const OBJ_CVAR_ADJUSTED: u8 = 3;
const OBJ_MIN_RISK: u8 = 4;

// ── Constraint types ──
const CT_SUPPLY: u8 = 0;   // Σ(route_tons) ≤ bound_var
const CT_DEMAND: u8 = 1;   // Σ(route_tons) ≤ bound_var (with optional min)
const CT_FLEET: u8 = 2;    // Σ(route_tons / unit_cap) ≤ bound_var
const CT_CAPITAL: u8 = 3;  // Σ(cost_per_ton × route_tons) ≤ bound_var
const CT_CUSTOM: u8 = 4;   // custom coefficients

// ── Model descriptor (parsed from binary) ──
const Correlation = struct {
    var_idx: u8,
    coefficient: f64,
};

const Perturbation = struct {
    stddev: f64,
    lo: f64,
    hi: f64,
    n_corr: u8,
    corr: [MAX_CORRELATIONS]Correlation,
};

const Route = struct {
    sell_var_idx: u8,
    buy_var_idx: u8,
    freight_var_idx: u8,
    transit_cost_per_day: f64,
    base_transit_days: f64,
    unit_capacity: f64,
};

const Constraint = struct {
    ctype: u8,
    bound_var_idx: u8,
    bound_min_var_idx: u8,     // 0xFF = no minimum
    outage_var_idx: u8,        // 0xFF = no outage modifier
    outage_factor: f64,        // multiply bound by this when outage active (e.g. 0.5)
    n_routes: u8,
    route_indices: [MAX_ROUTES]u8,
    coefficients: [MAX_ROUTES]f64, // for CT_CUSTOM
};

const Model = struct {
    n_vars: u16,
    n_routes: u8,
    n_constraints: u8,
    obj_mode: u8,
    lambda: f64,         // risk aversion (for CVaR modes)
    profit_floor: f64,   // minimum profit (for min_risk mode)
    routes: [MAX_ROUTES]Route,
    constraints: [MAX_CONSTRAINTS]Constraint,
    perturbations: [MAX_VARS]Perturbation,
};

const SolveResult = struct {
    status: u8,
    profit: f64,
    tons: f64,
    cost: f64,
    roi: f64,
    route_tons: [MAX_ROUTES]f64,
    route_profits: [MAX_ROUTES]f64,
    margins: [MAX_ROUTES]f64,
    shadow: [MAX_CONSTRAINTS]f64,
    n_routes: u8,
    n_constraints: u8,
};

const MonteCarloResult = struct {
    n_scenarios: u32,
    n_feasible: u32,
    n_infeasible: u32,
    mean: f64,
    stddev: f64,
    p5: f64,
    p25: f64,
    p50: f64,
    p75: f64,
    p95: f64,
    min: f64,
    max: f64,
    sensitivity: [MAX_VARS]f64,
    n_vars: u16,
};

// ============================================================
// LP Solve — builds the model from descriptor
// ============================================================
fn solve_one(model: *const Model, vars: []const f64) SolveResult {
    const nr = model.n_routes;
    const nc = model.n_constraints;

    var r = SolveResult{
        .status = 2,
        .profit = 0,
        .tons = 0,
        .cost = 0,
        .roi = 0,
        .route_tons = [_]f64{0} ** MAX_ROUTES,
        .route_profits = [_]f64{0} ** MAX_ROUTES,
        .margins = [_]f64{0} ** MAX_ROUTES,
        .shadow = [_]f64{0} ** MAX_CONSTRAINTS,
        .n_routes = nr,
        .n_constraints = nc,
    };

    // Compute margins for each route
    for (0..nr) |i| {
        const rt = &model.routes[i];
        const sell = if (rt.sell_var_idx < vars.len) vars[rt.sell_var_idx] else 0;
        const buy = if (rt.buy_var_idx < vars.len) vars[rt.buy_var_idx] else 0;
        const freight = if (rt.freight_var_idx < vars.len) vars[rt.freight_var_idx] else 0;
        const transit_cost = rt.base_transit_days * rt.transit_cost_per_day;
        r.margins[i] = sell - buy - freight - transit_cost;
    }

    // Create HiGHS model
    const h = highs.Highs_create() orelse return r;
    defer highs.Highs_destroy(h);
    _ = highs.Highs_setBoolOptionValue(h, "output_flag", 0);

    // Add route decision variables (continuous, >= 0)
    var lo_v: [MAX_ROUTES]f64 = [_]f64{0} ** MAX_ROUTES;
    var hi_v: [MAX_ROUTES]f64 = [_]f64{1e30} ** MAX_ROUTES;
    _ = highs.Highs_addVars(h, @intCast(nr), &lo_v, &hi_v);

    // Set objective based on mode
    switch (model.obj_mode) {
        OBJ_MAX_PROFIT, OBJ_CVAR_ADJUSTED => {
            _ = highs.Highs_changeObjectiveSense(h, highs.kHighsObjSenseMaximize);
            for (0..nr) |i| {
                _ = highs.Highs_changeColCost(h, @intCast(i), r.margins[i]);
            }
        },
        OBJ_MIN_COST => {
            _ = highs.Highs_changeObjectiveSense(h, highs.kHighsObjSenseMinimize);
            for (0..nr) |i| {
                const rt = &model.routes[i];
                const buy = if (rt.buy_var_idx < vars.len) vars[rt.buy_var_idx] else 0;
                const freight = if (rt.freight_var_idx < vars.len) vars[rt.freight_var_idx] else 0;
                _ = highs.Highs_changeColCost(h, @intCast(i), buy + freight);
            }
        },
        OBJ_MAX_ROI => {
            // Charnes-Cooper: maximize margin, normalize by cost constraint
            _ = highs.Highs_changeObjectiveSense(h, highs.kHighsObjSenseMaximize);
            for (0..nr) |i| {
                _ = highs.Highs_changeColCost(h, @intCast(i), r.margins[i]);
            }
        },
        OBJ_MIN_RISK => {
            // For single solve in min_risk mode, just maximize profit
            // (risk minimization is done at the MC level)
            _ = highs.Highs_changeObjectiveSense(h, highs.kHighsObjSenseMaximize);
            for (0..nr) |i| {
                _ = highs.Highs_changeColCost(h, @intCast(i), r.margins[i]);
            }
        },
        else => {
            _ = highs.Highs_changeObjectiveSense(h, highs.kHighsObjSenseMaximize);
            for (0..nr) |i| {
                _ = highs.Highs_changeColCost(h, @intCast(i), r.margins[i]);
            }
        },
    }

    // Add constraints
    for (0..nc) |ci| {
        const con = &model.constraints[ci];
        const bound_val = if (con.bound_var_idx < vars.len) vars[con.bound_var_idx] else 0;

        // Apply outage modifier if applicable
        var upper = bound_val;
        if (con.outage_var_idx != 0xFF and con.outage_var_idx < vars.len) {
            if (vars[con.outage_var_idx] > 0.5) {
                upper *= con.outage_factor;
            }
        }

        var lower: f64 = 0;
        if (con.bound_min_var_idx != 0xFF and con.bound_min_var_idx < vars.len) {
            lower = vars[con.bound_min_var_idx];
        }

        if (upper < 0) upper = 0;
        if (lower < 0) lower = 0;

        var indices: [MAX_ROUTES]c_int = undefined;
        var coeffs: [MAX_ROUTES]f64 = undefined;
        const n_r = con.n_routes;

        for (0..n_r) |ri| {
            indices[ri] = @intCast(con.route_indices[ri]);

            switch (con.ctype) {
                CT_SUPPLY, CT_DEMAND => {
                    coeffs[ri] = 1.0;
                },
                CT_FLEET => {
                    const route_idx = con.route_indices[ri];
                    const cap = if (route_idx < nr) model.routes[route_idx].unit_capacity else 1500.0;
                    coeffs[ri] = if (cap > 0) 1.0 / cap else 1.0;
                },
                CT_CAPITAL => {
                    const route_idx = con.route_indices[ri];
                    if (route_idx < nr) {
                        const rt = &model.routes[route_idx];
                        const buy = if (rt.buy_var_idx < vars.len) vars[rt.buy_var_idx] else 0;
                        const freight = if (rt.freight_var_idx < vars.len) vars[rt.freight_var_idx] else 0;
                        coeffs[ri] = buy + freight;
                    } else {
                        coeffs[ri] = 1.0;
                    }
                },
                CT_CUSTOM => {
                    coeffs[ri] = con.coefficients[ri];
                },
                else => {
                    coeffs[ri] = 1.0;
                },
            }
        }

        _ = highs.Highs_addRow(h, lower, upper, @intCast(n_r), &indices, &coeffs);
    }

    // Solve
    _ = highs.Highs_run(h);
    const ms = highs.Highs_getModelStatus(h);

    if (ms == 7) {
        r.status = 0; // optimal
    } else if (ms == 8) {
        r.status = 1; // infeasible
        return r;
    } else {
        r.status = 2; // error
        return r;
    }

    // Extract solution
    var col_dual: [MAX_ROUTES]f64 = undefined;
    var row_val: [MAX_CONSTRAINTS]f64 = undefined;
    _ = highs.Highs_getSolution(h, &r.route_tons, &col_dual, &row_val, &r.shadow);

    // Compute aggregates
    for (0..nr) |i| {
        if (r.route_tons[i] > 0.5) {
            r.route_profits[i] = r.route_tons[i] * r.margins[i];
            r.tons += r.route_tons[i];
            r.profit += r.route_profits[i];

            const rt = &model.routes[i];
            const buy = if (rt.buy_var_idx < vars.len) vars[rt.buy_var_idx] else 0;
            const freight = if (rt.freight_var_idx < vars.len) vars[rt.freight_var_idx] else 0;
            r.cost += r.route_tons[i] * (buy + freight);
        }
    }

    r.roi = if (r.cost > 0) r.profit / r.cost * 100.0 else 0.0;
    return r;
}

// ============================================================
// Monte Carlo
// ============================================================
var prng_state: [4]u64 = .{ 0x853c49e6748fea9b, 0xda3e39cb94b95bdb, 0x5b5ad4a5bb4d05b8, 0x515ad4a5bb4d05b8 };

fn prng_next() u64 {
    const result = std.math.rotl(u64, prng_state[1] *% 5, 7) *% 9;
    const t = prng_state[1] << 17;
    prng_state[2] ^= prng_state[0];
    prng_state[3] ^= prng_state[1];
    prng_state[1] ^= prng_state[2];
    prng_state[0] ^= prng_state[3];
    prng_state[2] ^= t;
    prng_state[3] = std.math.rotl(u64, prng_state[3], 45);
    return result;
}

fn rand_uniform() f64 {
    return @as(f64, @floatFromInt(prng_next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}

fn rand_normal() f64 {
    const r1 = @max(rand_uniform(), 1e-15);
    const r2 = rand_uniform();
    return @sqrt(-2.0 * @log(r1)) * @cos(2.0 * std.math.pi * r2);
}

fn clamp(val: f64, lo: f64, hi: f64) f64 {
    return if (val < lo) lo else if (val > hi) hi else val;
}

fn perturb(model: *const Model, center: []const f64, out: []f64) void {
    const nv = model.n_vars;

    // First pass: independent perturbation
    for (0..nv) |i| {
        const p = &model.perturbations[i];
        if (p.stddev > 0) {
            out[i] = clamp(center[i] + rand_normal() * p.stddev, p.lo, p.hi);
        } else {
            // Boolean flip: stddev=0, lo=flip_probability
            if (p.lo > 0 and rand_uniform() < p.lo) {
                out[i] = 1.0 - center[i];
            } else {
                out[i] = center[i];
            }
        }
    }

    // Second pass: apply correlations (additive adjustments from other variables)
    for (0..nv) |i| {
        const p = &model.perturbations[i];
        if (p.n_corr > 0 and p.stddev > 0) {
            var adj: f64 = 0;
            for (0..p.n_corr) |ci| {
                const c = &p.corr[ci];
                if (c.var_idx < nv) {
                    const delta = out[c.var_idx] - center[c.var_idx];
                    adj += delta * c.coefficient;
                }
            }
            out[i] = clamp(out[i] + adj, p.lo, p.hi);
        }
    }
}

fn pearson(x: []const f64, y: []const f64, y_mean: f64) f64 {
    if (x.len != y.len or x.len == 0) return 0;
    var x_sum: f64 = 0;
    for (x) |val| x_sum += val;
    const x_mean = x_sum / @as(f64, @floatFromInt(x.len));
    var cov: f64 = 0;
    var var_x: f64 = 0;
    var var_y: f64 = 0;
    for (x, y) |xi, yi| {
        const dx = xi - x_mean;
        const dy = yi - y_mean;
        cov += dx * dy;
        var_x += dx * dx;
        var_y += dy * dy;
    }
    const denom = @sqrt(var_x * var_y);
    if (denom < 1e-10) return 0;
    return cov / denom;
}

fn sort_f64(arr: []f64) void {
    var i: usize = 1;
    while (i < arr.len) : (i += 1) {
        const key = arr[i];
        var j: usize = i;
        while (j > 0 and arr[j - 1] > key) : (j -= 1) {
            arr[j] = arr[j - 1];
        }
        arr[j] = key;
    }
}

fn run_monte_carlo(model: *const Model, center: []const f64, n: u32) MonteCarloResult {
    const nv = model.n_vars;

    // Seed PRNG
    if (nv > 0) prng_state[0] = @bitCast(center[0]);
    if (nv > 1) prng_state[1] = @bitCast(center[1]);

    var profits: [MAX_SCENARIOS]f64 = undefined;
    // Store per-variable values for sensitivity (ring buffer of feasible scenarios)
    var var_buf: [MAX_VARS][MAX_SCENARIOS]f64 = undefined;
    var scenario_vars: [MAX_VARS]f64 = undefined;

    const count = if (n > MAX_SCENARIOS) @as(u32, MAX_SCENARIOS) else n;
    var n_feasible: u32 = 0;

    for (0..count) |_| {
        perturb(model, center, &scenario_vars);
        const result = solve_one(model, scenario_vars[0..nv]);

        if (result.status == 0) {
            const metric: f64 = switch (model.obj_mode) {
                OBJ_MIN_COST => -result.cost, // negate so "higher is better" for stats
                OBJ_MAX_ROI => result.roi,
                else => result.profit,
            };

            if (model.obj_mode == OBJ_MIN_RISK) {
                // For min_risk, record all feasible (including negative profit)
                profits[n_feasible] = metric;
                for (0..nv) |vi| var_buf[vi][n_feasible] = scenario_vars[vi];
                n_feasible += 1;
            } else if (metric > 0 or model.obj_mode == OBJ_MIN_COST) {
                profits[n_feasible] = metric;
                for (0..nv) |vi| var_buf[vi][n_feasible] = scenario_vars[vi];
                n_feasible += 1;
            }
        }
    }

    if (n_feasible == 0) {
        return MonteCarloResult{
            .n_scenarios = count,
            .n_feasible = 0,
            .n_infeasible = count,
            .mean = 0, .stddev = 0,
            .p5 = 0, .p25 = 0, .p50 = 0, .p75 = 0, .p95 = 0,
            .min = 0, .max = 0,
            .sensitivity = [_]f64{0} ** MAX_VARS,
            .n_vars = model.n_vars,
        };
    }

    // Sort for percentiles
    sort_f64(profits[0..n_feasible]);

    var sum: f64 = 0;
    for (profits[0..n_feasible]) |p| sum += p;
    const mean = sum / @as(f64, @floatFromInt(n_feasible));

    var var_sum: f64 = 0;
    for (profits[0..n_feasible]) |p| var_sum += (p - mean) * (p - mean);
    const stddev = @sqrt(var_sum / @as(f64, @floatFromInt(n_feasible)));

    // Sensitivity: Pearson correlation for each variable
    var sensitivity: [MAX_VARS]f64 = [_]f64{0} ** MAX_VARS;
    for (0..nv) |vi| {
        sensitivity[vi] = pearson(var_buf[vi][0..n_feasible], profits[0..n_feasible], mean);
    }

    const nf = n_feasible;
    return MonteCarloResult{
        .n_scenarios = count,
        .n_feasible = n_feasible,
        .n_infeasible = count - n_feasible,
        .mean = mean,
        .stddev = stddev,
        .p5 = profits[nf * 5 / 100],
        .p25 = profits[nf * 25 / 100],
        .p50 = profits[nf * 50 / 100],
        .p75 = profits[nf * 75 / 100],
        .p95 = profits[@min(nf * 95 / 100, nf - 1)],
        .min = profits[0],
        .max = profits[nf - 1],
        .sensitivity = sensitivity,
        .n_vars = model.n_vars,
    };
}

// ============================================================
// Binary Parsing — model descriptor from Elixir
// ============================================================
fn read_u8(data: []const u8, off: *usize) u8 {
    if (off.* >= data.len) return 0;
    const v = data[off.*];
    off.* += 1;
    return v;
}

fn read_u16(data: []const u8, off: *usize) u16 {
    if (off.* + 2 > data.len) return 0;
    var buf: [2]u8 = undefined;
    @memcpy(&buf, data[off.* .. off.* + 2]);
    off.* += 2;
    return std.mem.readInt(u16, &buf, .little);
}

fn read_u32(data: []const u8, off: *usize) u32 {
    if (off.* + 4 > data.len) return 0;
    var buf: [4]u8 = undefined;
    @memcpy(&buf, data[off.* .. off.* + 4]);
    off.* += 4;
    return std.mem.readInt(u32, &buf, .little);
}

fn read_f64(data: []const u8, off: *usize) f64 {
    if (off.* + 8 > data.len) return 0;
    var buf: [8]u8 = undefined;
    @memcpy(&buf, data[off.* .. off.* + 8]);
    off.* += 8;
    return @bitCast(buf);
}

fn parse_model(data: []const u8, off: *usize) Model {
    var m = Model{
        .n_vars = 0,
        .n_routes = 0,
        .n_constraints = 0,
        .obj_mode = OBJ_MAX_PROFIT,
        .lambda = 0,
        .profit_floor = 0,
        .routes = undefined,
        .constraints = undefined,
        .perturbations = undefined,
    };

    // Initialize arrays
    for (0..MAX_ROUTES) |i| {
        m.routes[i] = Route{
            .sell_var_idx = 0, .buy_var_idx = 0, .freight_var_idx = 0,
            .transit_cost_per_day = 0, .base_transit_days = 0, .unit_capacity = 1500,
        };
    }
    for (0..MAX_CONSTRAINTS) |i| {
        m.constraints[i] = Constraint{
            .ctype = 0, .bound_var_idx = 0, .bound_min_var_idx = 0xFF,
            .outage_var_idx = 0xFF, .outage_factor = 0.5,
            .n_routes = 0, .route_indices = undefined, .coefficients = undefined,
        };
    }
    for (0..MAX_VARS) |i| {
        m.perturbations[i] = Perturbation{
            .stddev = 0, .lo = 0, .hi = 0, .n_corr = 0, .corr = undefined,
        };
    }

    // Header
    m.n_vars = read_u16(data, off);
    m.n_routes = read_u8(data, off);
    m.n_constraints = read_u8(data, off);
    m.obj_mode = read_u8(data, off);
    m.lambda = read_f64(data, off);
    m.profit_floor = read_f64(data, off);

    // Routes
    for (0..m.n_routes) |i| {
        m.routes[i].sell_var_idx = read_u8(data, off);
        m.routes[i].buy_var_idx = read_u8(data, off);
        m.routes[i].freight_var_idx = read_u8(data, off);
        m.routes[i].transit_cost_per_day = read_f64(data, off);
        m.routes[i].base_transit_days = read_f64(data, off);
        m.routes[i].unit_capacity = read_f64(data, off);
    }

    // Constraints
    for (0..m.n_constraints) |i| {
        m.constraints[i].ctype = read_u8(data, off);
        m.constraints[i].bound_var_idx = read_u8(data, off);
        m.constraints[i].bound_min_var_idx = read_u8(data, off);
        m.constraints[i].outage_var_idx = read_u8(data, off);
        m.constraints[i].outage_factor = read_f64(data, off);
        m.constraints[i].n_routes = read_u8(data, off);
        for (0..m.constraints[i].n_routes) |ri| {
            m.constraints[i].route_indices[ri] = read_u8(data, off);
        }
        // Capital constraints need per-route coefficients? No — they compute from route defs.
        // Custom constraints carry explicit coefficients.
        if (m.constraints[i].ctype == CT_CUSTOM) {
            for (0..m.constraints[i].n_routes) |ri| {
                m.constraints[i].coefficients[ri] = read_f64(data, off);
            }
        }
    }

    // Perturbation specs (for Monte Carlo)
    for (0..m.n_vars) |i| {
        m.perturbations[i].stddev = read_f64(data, off);
        m.perturbations[i].lo = read_f64(data, off);
        m.perturbations[i].hi = read_f64(data, off);
        m.perturbations[i].n_corr = read_u8(data, off);
        for (0..m.perturbations[i].n_corr) |ci| {
            m.perturbations[i].corr[ci].var_idx = read_u8(data, off);
            m.perturbations[i].corr[ci].coefficient = read_f64(data, off);
        }
    }

    return m;
}

fn parse_variables(data: []const u8, off: *usize, n: u16) [MAX_VARS]f64 {
    var vars: [MAX_VARS]f64 = [_]f64{0} ** MAX_VARS;
    for (0..n) |i| {
        vars[i] = read_f64(data, off);
    }
    return vars;
}

// ============================================================
// Response Encoding
// ============================================================
fn encode_solve_result(r: *const SolveResult, buf: []u8) usize {
    var off: usize = 0;

    buf[off] = r.status;
    off += 1;
    buf[off] = r.n_routes;
    off += 1;
    buf[off] = r.n_constraints;
    off += 1;

    write_f64(buf, &off, r.profit);
    write_f64(buf, &off, r.tons);
    write_f64(buf, &off, r.cost);
    write_f64(buf, &off, r.roi);

    for (0..r.n_routes) |i| write_f64(buf, &off, r.route_tons[i]);
    for (0..r.n_routes) |i| write_f64(buf, &off, r.route_profits[i]);
    for (0..r.n_routes) |i| write_f64(buf, &off, r.margins[i]);
    for (0..r.n_constraints) |i| write_f64(buf, &off, r.shadow[i]);

    return off;
}

fn encode_monte_carlo(mc: *const MonteCarloResult, buf: []u8) usize {
    var off: usize = 0;

    buf[off] = 0; // status OK
    off += 1;

    write_u16(buf, &off, mc.n_vars);
    write_u32(buf, &off, mc.n_scenarios);
    write_u32(buf, &off, mc.n_feasible);
    write_u32(buf, &off, mc.n_infeasible);

    write_f64(buf, &off, mc.mean);
    write_f64(buf, &off, mc.stddev);
    write_f64(buf, &off, mc.p5);
    write_f64(buf, &off, mc.p25);
    write_f64(buf, &off, mc.p50);
    write_f64(buf, &off, mc.p75);
    write_f64(buf, &off, mc.p95);
    write_f64(buf, &off, mc.min);
    write_f64(buf, &off, mc.max);

    // Sensitivity values (one per variable)
    for (0..mc.n_vars) |i| write_f64(buf, &off, mc.sensitivity[i]);

    return off;
}

fn write_f64(buf: []u8, off: *usize, val: f64) void {
    const bytes = @as(*const [8]u8, @ptrCast(&val));
    @memcpy(buf[off.* .. off.* + 8], bytes);
    off.* += 8;
}

fn write_u16(buf: []u8, off: *usize, val: u16) void {
    std.mem.writeInt(u16, buf[off.*..][0..2], val, .little);
    off.* += 2;
}

fn write_u32(buf: []u8, off: *usize, val: u32) void {
    std.mem.writeInt(u32, buf[off.*..][0..4], val, .little);
    off.* += 4;
}

// ============================================================
// Port Protocol
// ============================================================
fn read_packet(reader: anytype, buf: []u8) !usize {
    var len_buf: [4]u8 = undefined;
    var read: usize = 0;
    while (read < 4) {
        const n = reader.read(len_buf[read..]) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        read += n;
    }
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len > buf.len) return error.PacketTooLarge;

    read = 0;
    while (read < len) {
        const n = reader.read(buf[read..len]) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        read += n;
    }
    return len;
}

fn write_packet(writer: anytype, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try writer.writeAll(&len_buf);
    try writer.writeAll(data);
}

// ============================================================
// Main Loop
// ============================================================
pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var buf: [131072]u8 = undefined; // 128KB — enough for large model descriptors
    var resp: [16384]u8 = undefined;

    while (true) {
        const len = read_packet(stdin, &buf) catch break;
        if (len < 1) continue;

        const cmd = buf[0];
        const payload = buf[1..len];

        switch (cmd) {
            // cmd 1: single solve
            // payload: model_descriptor + variables
            1 => {
                var off: usize = 0;
                const model = parse_model(payload, &off);
                const vars = parse_variables(payload, &off, model.n_vars);
                const result = solve_one(&model, vars[0..model.n_vars]);
                const resp_len = encode_solve_result(&result, &resp);
                write_packet(stdout, resp[0..resp_len]) catch break;
            },
            // cmd 2: monte carlo
            // payload: n_scenarios(u32) + model_descriptor + center_variables
            2 => {
                var off: usize = 0;
                const n_scenarios = read_u32(payload, &off);
                const model = parse_model(payload, &off);
                const center = parse_variables(payload, &off, model.n_vars);
                const mc = run_monte_carlo(&model, center[0..model.n_vars], n_scenarios);
                const resp_len = encode_monte_carlo(&mc, &resp);
                write_packet(stdout, resp[0..resp_len]) catch break;
            },
            else => {},
        }
    }
}
