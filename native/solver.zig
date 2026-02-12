const std = @import("std");
const highs = @cImport({
    @cInclude("highs_c_api.h");
});

// ============================================================
// Input struct — 20 f64s matching Elixir's Variables.to_binary/1
// ============================================================
const Input = struct {
    river_stage: f64,
    lock_hrs: f64,
    temp_f: f64,
    wind_mph: f64,
    vis_mi: f64,
    precip_in: f64,
    inv_don: f64,
    inv_geis: f64,
    stl_outage: f64, // 1.0 or 0.0
    mem_outage: f64,
    barge_count: f64,
    nola_buy: f64,
    sell_stl: f64,
    sell_mem: f64,
    fr_don_stl: f64,
    fr_don_mem: f64,
    fr_geis_stl: f64,
    fr_geis_mem: f64,
    nat_gas: f64,
    working_cap: f64,
};

const SolveResult = struct {
    status: u8, // 0=optimal, 1=infeasible, 2=error
    profit: f64,
    tons: f64,
    barges: f64,
    cost: f64,
    eff_barge: f64,
    route_tons: [4]f64,
    route_profits: [4]f64,
    margins: [4]f64,
    transits: [4]f64,
    shadow: [6]f64,
};

fn solve_one(input: Input) SolveResult {
    var r = SolveResult{
        .status = 2,
        .profit = 0,
        .tons = 0,
        .barges = 0,
        .cost = 0,
        .eff_barge = 0,
        .route_tons = .{ 0, 0, 0, 0 },
        .route_profits = .{ 0, 0, 0, 0 },
        .margins = .{ 0, 0, 0, 0 },
        .transits = .{ 0, 0, 0, 0 },
        .shadow = .{ 0, 0, 0, 0, 0, 0 },
    };

    const dm: f64 = if (input.river_stage < 12) 0.75 else if (input.river_stage < 18) 0.90 else 1.0;
    r.eff_barge = 1500.0 * dm;

    const dd = input.lock_hrs / 24.0;
    var wa: f64 = 0;
    if (input.wind_mph > 15) wa += 0.5;
    if (input.vis_mi <= 0.5) wa += 0.5;
    if (input.temp_f < 32) wa += 0.5;
    if (input.river_stage < 10) wa += 1.0;
    const ta = dd + wa;

    const bt = [4]f64{ 9.0, 5.5, 9.5, 6.0 };
    const fr = [4]f64{ input.fr_don_stl, input.fr_don_mem, input.fr_geis_stl, input.fr_geis_mem };
    const sp = [4]f64{ input.sell_stl, input.sell_mem, input.sell_stl, input.sell_mem };

    for (0..4) |idx| {
        r.transits[idx] = bt[idx] + ta;
        r.margins[idx] = sp[idx] - input.nola_buy - fr[idx] - r.transits[idx] * 0.5;
    }

    var sa: f64 = 8000.0 - 2500.0;
    var ma: f64 = 6000.0 - 4000.0;
    if (input.stl_outage > 0.5) sa *= 0.5;
    if (input.mem_outage > 0.5) ma *= 0.5;
    if (sa < 0) sa = 0;
    if (ma < 0) ma = 0;
    const sc = @min(@as(f64, 5000), sa);
    const mc = @min(@as(f64, 4000), ma);

    const h = highs.Highs_create() orelse return r;
    defer highs.Highs_destroy(h);
    _ = highs.Highs_setBoolOptionValue(h, "output_flag", 0);

    var lo_v = [4]f64{ 0, 0, 0, 0 };
    var hi_v = [4]f64{ 1e30, 1e30, 1e30, 1e30 };
    _ = highs.Highs_addVars(h, 4, &lo_v, &hi_v);
    _ = highs.Highs_changeObjectiveSense(h, highs.kHighsObjSenseMaximize);
    for (0..4) |idx| _ = highs.Highs_changeColCost(h, @intCast(idx), r.margins[idx]);

    var idx_01 = [2]c_int{ 0, 1 };
    var idx_23 = [2]c_int{ 2, 3 };
    var idx_02 = [2]c_int{ 0, 2 };
    var idx_13 = [2]c_int{ 1, 3 };
    var idx_a = [4]c_int{ 0, 1, 2, 3 };
    var o2 = [2]f64{ 1, 1 };

    _ = highs.Highs_addRow(h, 0, input.inv_don, 2, &idx_01, &o2);
    _ = highs.Highs_addRow(h, 0, input.inv_geis, 2, &idx_23, &o2);
    _ = highs.Highs_addRow(h, sc, sa, 2, &idx_02, &o2);
    _ = highs.Highs_addRow(h, mc, ma, 2, &idx_13, &o2);
    var fc = [4]f64{ 1.0 / r.eff_barge, 1.0 / r.eff_barge, 1.0 / r.eff_barge, 1.0 / r.eff_barge };
    _ = highs.Highs_addRow(h, 0, input.barge_count, 4, &idx_a, &fc);
    var cc: [4]f64 = undefined;
    for (0..4) |idx| cc[idx] = input.nola_buy + fr[idx];
    _ = highs.Highs_addRow(h, 0, input.working_cap, 4, &idx_a, &cc);

    _ = highs.Highs_run(h);
    const ms = highs.Highs_getModelStatus(h);

    if (ms == 7) {
        r.status = 0; // optimal
    } else if (ms == 8) {
        r.status = 1; // infeasible
        return r;
    } else {
        r.status = 2;
        return r;
    }

    var cd: [4]f64 = undefined;
    var rv: [6]f64 = undefined;
    _ = highs.Highs_getSolution(h, &r.route_tons, &cd, &rv, &r.shadow);

    for (0..4) |idx| {
        if (r.route_tons[idx] > 0.5) {
            r.route_profits[idx] = r.route_tons[idx] * r.margins[idx];
            r.tons += r.route_tons[idx];
            r.profit += r.route_profits[idx];
            r.barges += r.route_tons[idx] / r.eff_barge;
            r.cost += r.route_tons[idx] * (input.nola_buy + fr[idx]);
        }
    }
    return r;
}

// ============================================================
// Monte Carlo Implementation
// ============================================================

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
    sensitivity: [20]f64, // Pearson correlation of each variable with profit
};

// Simple xoshiro256** PRNG (no allocator needed)
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

fn rand_normal() f64 {
    // Box-Muller transform
    const rand1 = @as(f64, @floatFromInt(prng_next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    const rand2 = @as(f64, @floatFromInt(prng_next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    const rand1_safe = if (rand1 < 1e-15) 1e-15 else rand1;
    return @sqrt(-2.0 * @log(rand1_safe)) * @cos(2.0 * std.math.pi * rand2);
}

fn clamp(val: f64, lo: f64, hi: f64) f64 {
    return if (val < lo) lo else if (val > hi) hi else val;
}

fn perturb_correlated(center: Input) Input {
    // Layer 1: Weather (independent)
    const temp = clamp(center.temp_f + rand_normal() * 5.0, -20, 115);
    const wind = clamp(center.wind_mph + rand_normal() * 3.0, 0, 55);
    const precip = clamp(center.precip_in + rand_normal() * 0.5, 0, 8);
    const vis = clamp(center.vis_mi + rand_normal() * 1.5, 0.05, 15);

    // Layer 2: River (correlated with precip)
    const precip_delta = precip - center.precip_in;
    const stage = clamp(center.river_stage + rand_normal() * 3.0 + precip_delta * 3.0, 2, 55);

    // Layer 3: Lock delays (correlated with stage, temp, wind)
    var lock_base = center.lock_hrs + rand_normal() * 4.0;
    if (stage < 10) lock_base += (10.0 - stage) * 2.0;
    if (temp < 20) lock_base += 8.0;
    if (wind > 30) lock_base += 4.0;
    const lock = clamp(lock_base, 0, 96);

    // Layer 4: Barge availability (correlated with river + weather)
    var barge_adj: f64 = 0;
    if (stage < 10) barge_adj -= 3;
    if (stage > 40) barge_adj -= 2;
    if (temp < 15) barge_adj -= 1;
    const barges = clamp(center.barge_count + rand_normal() * 2.0 + barge_adj, 1, 30);

    // Layer 5: Prices (correlated with logistics difficulty)
    const difficulty = lock / 24.0 + (if (stage < 12) @as(f64, 2.0) else 0.0);
    const freight_adj = difficulty * 2.0;
    const gas = clamp(center.nat_gas + rand_normal() * 0.3, 1, 8);

    // Outage flips (rare)
    const stl_flip = (prng_next() % 100) < 8;
    const mem_flip = (prng_next() % 100) < 5;
    const stl_out = if (stl_flip) 1.0 - center.stl_outage else center.stl_outage;
    const mem_out = if (mem_flip) 1.0 - center.mem_outage else center.mem_outage;

    return Input{
        .river_stage = stage,
        .lock_hrs = lock,
        .temp_f = temp,
        .wind_mph = wind,
        .vis_mi = vis,
        .precip_in = precip,
        .inv_don = clamp(center.inv_don + rand_normal() * 1000, 0, 15000),
        .inv_geis = clamp(center.inv_geis + rand_normal() * 800, 0, 10000),
        .stl_outage = stl_out,
        .mem_outage = mem_out,
        .barge_count = barges,
        .nola_buy = clamp(center.nola_buy + rand_normal() * 15.0, 200, 600),
        .sell_stl = clamp(center.sell_stl + rand_normal() * 12.0 + freight_adj, 300, 600),
        .sell_mem = clamp(center.sell_mem + rand_normal() * 10.0 + freight_adj, 280, 550),
        .fr_don_stl = clamp(center.fr_don_stl + rand_normal() * 5.0 + freight_adj, 20, 130),
        .fr_don_mem = clamp(center.fr_don_mem + rand_normal() * 3.0 + freight_adj * 0.5, 10, 80),
        .fr_geis_stl = clamp(center.fr_geis_stl + rand_normal() * 5.0 + freight_adj, 20, 135),
        .fr_geis_mem = clamp(center.fr_geis_mem + rand_normal() * 3.0 + freight_adj * 0.5, 10, 85),
        .nat_gas = gas,
        .working_cap = clamp(center.working_cap + rand_normal() * 200000, 500000, 10000000),
    };
}

fn sort_f64(arr: []f64) void {
    // Simple insertion sort — fine for 1000 elements
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

fn pearson(x: []const f64, y: []const f64, y_mean: f64) f64 {
    if (x.len != y.len or x.len == 0) return 0;

    // Compute mean of x
    var x_sum: f64 = 0;
    for (x) |val| x_sum += val;
    const x_mean = x_sum / @as(f64, @floatFromInt(x.len));

    // Compute covariance and variances
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

fn compute_sensitivity(inputs: []const Input, profits: []const f64, profit_mean: f64) [20]f64 {
    var sens: [20]f64 = undefined;
    const n = inputs.len;

    // Extract each variable into array and compute correlation
    var vals: [10000]f64 = undefined;

    // 0: river_stage
    for (inputs, 0..) |inp, i| vals[i] = inp.river_stage;
    sens[0] = pearson(vals[0..n], profits, profit_mean);

    // 1: lock_hrs
    for (inputs, 0..) |inp, i| vals[i] = inp.lock_hrs;
    sens[1] = pearson(vals[0..n], profits, profit_mean);

    // 2: temp_f
    for (inputs, 0..) |inp, i| vals[i] = inp.temp_f;
    sens[2] = pearson(vals[0..n], profits, profit_mean);

    // 3: wind_mph
    for (inputs, 0..) |inp, i| vals[i] = inp.wind_mph;
    sens[3] = pearson(vals[0..n], profits, profit_mean);

    // 4: vis_mi
    for (inputs, 0..) |inp, i| vals[i] = inp.vis_mi;
    sens[4] = pearson(vals[0..n], profits, profit_mean);

    // 5: precip_in
    for (inputs, 0..) |inp, i| vals[i] = inp.precip_in;
    sens[5] = pearson(vals[0..n], profits, profit_mean);

    // 6: inv_don
    for (inputs, 0..) |inp, i| vals[i] = inp.inv_don;
    sens[6] = pearson(vals[0..n], profits, profit_mean);

    // 7: inv_geis
    for (inputs, 0..) |inp, i| vals[i] = inp.inv_geis;
    sens[7] = pearson(vals[0..n], profits, profit_mean);

    // 8: stl_outage
    for (inputs, 0..) |inp, i| vals[i] = inp.stl_outage;
    sens[8] = pearson(vals[0..n], profits, profit_mean);

    // 9: mem_outage
    for (inputs, 0..) |inp, i| vals[i] = inp.mem_outage;
    sens[9] = pearson(vals[0..n], profits, profit_mean);

    // 10: barge_count
    for (inputs, 0..) |inp, i| vals[i] = inp.barge_count;
    sens[10] = pearson(vals[0..n], profits, profit_mean);

    // 11: nola_buy
    for (inputs, 0..) |inp, i| vals[i] = inp.nola_buy;
    sens[11] = pearson(vals[0..n], profits, profit_mean);

    // 12: sell_stl
    for (inputs, 0..) |inp, i| vals[i] = inp.sell_stl;
    sens[12] = pearson(vals[0..n], profits, profit_mean);

    // 13: sell_mem
    for (inputs, 0..) |inp, i| vals[i] = inp.sell_mem;
    sens[13] = pearson(vals[0..n], profits, profit_mean);

    // 14: fr_don_stl
    for (inputs, 0..) |inp, i| vals[i] = inp.fr_don_stl;
    sens[14] = pearson(vals[0..n], profits, profit_mean);

    // 15: fr_don_mem
    for (inputs, 0..) |inp, i| vals[i] = inp.fr_don_mem;
    sens[15] = pearson(vals[0..n], profits, profit_mean);

    // 16: fr_geis_stl
    for (inputs, 0..) |inp, i| vals[i] = inp.fr_geis_stl;
    sens[16] = pearson(vals[0..n], profits, profit_mean);

    // 17: fr_geis_mem
    for (inputs, 0..) |inp, i| vals[i] = inp.fr_geis_mem;
    sens[17] = pearson(vals[0..n], profits, profit_mean);

    // 18: nat_gas
    for (inputs, 0..) |inp, i| vals[i] = inp.nat_gas;
    sens[18] = pearson(vals[0..n], profits, profit_mean);

    // 19: working_cap
    for (inputs, 0..) |inp, i| vals[i] = inp.working_cap;
    sens[19] = pearson(vals[0..n], profits, profit_mean);

    return sens;
}

fn run_monte_carlo(center: Input, n: u32) MonteCarloResult {
    // Seed PRNG with current time-ish value
    prng_state[0] = @bitCast(center.river_stage);
    prng_state[1] = @bitCast(center.nola_buy);

    var profits: [10000]f64 = undefined;
    var inputs: [10000]Input = undefined;
    const count = if (n > 10000) @as(u32, 10000) else n;
    var n_feasible: u32 = 0;

    for (0..count) |_| {
        const scenario = perturb_correlated(center);
        const result = solve_one(scenario);
        if (result.status == 0 and result.profit > 0) {
            profits[n_feasible] = result.profit;
            inputs[n_feasible] = scenario;
            n_feasible += 1;
        }
    }

    if (n_feasible == 0) {
        return MonteCarloResult{
            .n_scenarios = count,
            .n_feasible = 0,
            .n_infeasible = count,
            .mean = 0,
            .stddev = 0,
            .p5 = 0,
            .p25 = 0,
            .p50 = 0,
            .p75 = 0,
            .p95 = 0,
            .min = 0,
            .max = 0,
            .sensitivity = [_]f64{0} ** 20,
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

    // Compute sensitivity (Pearson correlation of each variable with profit)
    const sensitivity = compute_sensitivity(inputs[0..n_feasible], profits[0..n_feasible], mean);

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
    };
}

fn encode_monte_carlo(mc: MonteCarloResult) [253]u8 {
    var buf: [253]u8 = undefined;
    buf[0] = 0; // status OK

    var off: usize = 1;

    const ints = [3]u32{ mc.n_scenarios, mc.n_feasible, mc.n_infeasible };
    for (ints) |v| {
        const bytes = @as(*const [4]u8, @ptrCast(&v));
        @memcpy(buf[off .. off + 4], bytes);
        off += 4;
    }

    const floats = [10]f64{
        mc.mean, mc.stddev, mc.p5, mc.p25, mc.p50,
        mc.p75, mc.p95, mc.min, mc.max, 0, // padding
    };
    for (floats) |v| {
        const bytes = @as(*const [8]u8, @ptrCast(&v));
        @memcpy(buf[off .. off + 8], bytes);
        off += 8;
    }

    // Append 20 sensitivity values
    for (mc.sensitivity) |v| {
        const bytes = @as(*const [8]u8, @ptrCast(&v));
        @memcpy(buf[off .. off + 8], bytes);
        off += 8;
    }

    return buf;
}

// ============================================================
// Port protocol: read/write with 4-byte length prefix
// ============================================================
fn read_packet(reader: anytype, buf: []u8) !usize {
    // Read 4-byte length prefix
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

fn parse_input(data: []const u8) Input {
    var vals: [20]f64 = undefined;
    for (0..20) |idx| {
        var bytes: [8]u8 = undefined;
        @memcpy(&bytes, data[idx * 8 .. idx * 8 + 8]);
        vals[idx] = @bitCast(bytes);
    }
    return Input{
        .river_stage = vals[0],
        .lock_hrs = vals[1],
        .temp_f = vals[2],
        .wind_mph = vals[3],
        .vis_mi = vals[4],
        .precip_in = vals[5],
        .inv_don = vals[6],
        .inv_geis = vals[7],
        .stl_outage = vals[8],
        .mem_outage = vals[9],
        .barge_count = vals[10],
        .nola_buy = vals[11],
        .sell_stl = vals[12],
        .sell_mem = vals[13],
        .fr_don_stl = vals[14],
        .fr_don_mem = vals[15],
        .fr_geis_stl = vals[16],
        .fr_geis_mem = vals[17],
        .nat_gas = vals[18],
        .working_cap = vals[19],
    };
}

fn encode_solve_result(r: SolveResult) [217]u8 {
    var buf: [217]u8 = undefined; // 1 + 27*8 = 217
    buf[0] = r.status;

    var off: usize = 1;
    const fields = [_]f64{
        r.profit,           r.tons,             r.barges,           r.cost,          r.eff_barge,
        r.route_tons[0],    r.route_tons[1],    r.route_tons[2],    r.route_tons[3], r.route_profits[0],
        r.route_profits[1], r.route_profits[2], r.route_profits[3], r.margins[0],    r.margins[1],
        r.margins[2],       r.margins[3],       r.transits[0],      r.transits[1],   r.transits[2],
        r.transits[3],      r.shadow[0],        r.shadow[1],        r.shadow[2],     r.shadow[3],
        r.shadow[4],        r.shadow[5],
    };

    for (fields) |v| {
        const bytes = @as(*const [8]u8, @ptrCast(&v));
        @memcpy(buf[off .. off + 8], bytes);
        off += 8;
    }
    return buf;
}

// ============================================================
// Main loop — reads commands from stdin, writes results to stdout
// ============================================================
pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var buf: [65536]u8 = undefined;

    while (true) {
        const len = read_packet(stdin, &buf) catch break;
        if (len < 1) continue;

        const cmd = buf[0];
        const payload = buf[1..len];

        switch (cmd) {
            1 => {
                if (payload.len < 160) continue;
                const input = parse_input(payload);
                const result = solve_one(input);
                const encoded = encode_solve_result(result);
                write_packet(stdout, &encoded) catch break;
            },
            2 => {
                if (payload.len < 164) continue; // 4 + 20*8
                var n_buf: [4]u8 = undefined;
                @memcpy(&n_buf, payload[0..4]);
                const n: u32 = @bitCast(n_buf);
                const input = parse_input(payload[4..]);
                const mc = run_monte_carlo(input, n);
                const encoded = encode_monte_carlo(mc);
                write_packet(stdout, &encoded) catch break;
            },
            else => {},
        }
    }
}
