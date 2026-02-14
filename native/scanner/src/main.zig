// Contract Scanner — Zig native binary called from Elixir via Port.
//
// This is a hash provider. It tells Elixir what files exist on SharePoint
// and whether their hashes changed. That's it.
//
// Responsibilities (and ONLY these):
//   1. List contract files in a SharePoint folder — returns metadata + hashes
//   2. Compare app-provided hashes against current Graph API hashes
//   3. Hash a local file (testing / UNC fallback)
//
// What it does NOT do:
//   - Download file content (Copilot accesses files via Graph API directly)
//   - Extract clauses (Copilot does that)
//   - Decide what to ingest (the app does that)
//
// Elixir stores {item_id, drive_id, filename, sha256} from scan results.
// On subsequent runs, Elixir sends those stored hashes back via diff_hashes
// and the scanner tells it what changed.
//
// Protocol: JSON lines over stdin/stdout.
//
// Commands:
//   ping        — health check
//   scan        — list files + hashes from a SharePoint folder
//   diff_hashes — batch-compare app's stored hashes against Graph API
//   hash_local  — SHA-256 of a local file

const std = @import("std");
const crypto = std.crypto;
const json = std.json;
const mem = std.mem;
const io = std.io;
const fs = std.fs;
const http = std.http;
const Uri = std.Uri;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    const stderr = io.getStdErr().writer();

    try stderr.print("contract_scanner: started\n", .{});

    while (true) {
        const line = stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024 * 1024) catch |err| {
            try writeError(stdout, allocator, "read_error", @errorName(err));
            continue;
        };

        if (line == null) break;
        defer allocator.free(line.?);

        const trimmed = mem.trim(u8, line.?, &[_]u8{ ' ', '\t', '\r', '\n' });
        if (trimmed.len == 0) continue;

        handleCommand(allocator, trimmed, stdout, stderr) catch |err| {
            try writeError(stdout, allocator, "command_error", @errorName(err));
        };
    }
}

fn handleCommand(
    allocator: mem.Allocator,
    raw_json: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    const parsed = json.parseFromSlice(json.Value, allocator, raw_json, .{}) catch {
        try writeError(stdout, allocator, "parse_error", "invalid JSON input");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const cmd_val = root.object.get("cmd") orelse {
        try writeError(stdout, allocator, "missing_field", "cmd is required");
        return;
    };
    const cmd = switch (cmd_val) {
        .string => |s| s,
        else => {
            try writeError(stdout, allocator, "invalid_field", "cmd must be a string");
            return;
        },
    };

    try stderr.print("contract_scanner: cmd={s}\n", .{cmd});

    if (mem.eql(u8, cmd, "ping")) {
        try cmdPing(stdout, allocator);
    } else if (mem.eql(u8, cmd, "scan")) {
        try cmdScan(allocator, root, stdout, stderr);
    } else if (mem.eql(u8, cmd, "diff_hashes")) {
        try cmdDiffHashes(allocator, root, stdout, stderr);
    } else if (mem.eql(u8, cmd, "hash_local")) {
        try cmdHashLocal(allocator, root, stdout);
    } else {
        try writeError(stdout, allocator, "unknown_command", cmd);
    }
}

// ─────────────────────────────────────────────────────────────
// CMD: ping
// ─────────────────────────────────────────────────────────────

fn cmdPing(stdout: anytype, allocator: mem.Allocator) !void {
    var obj = json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("status", json.Value{ .string = "ok" });
    try obj.put("scanner", json.Value{ .string = "contract_scanner" });
    try obj.put("version", json.Value{ .string = "1.1.0" });
    try writeJsonLine(stdout, allocator, json.Value{ .object = obj });
}

// ─────────────────────────────────────────────────────────────
// CMD: scan — list files + hashes from a SharePoint folder
//
// Graph API provides SHA-256 hashes as file metadata.
// Elixir stores {item_id, drive_id, filename, sha256} for later
// comparison via diff_hashes.
//
// Input:
//   {"cmd": "scan", "token": "Bearer ...",
//    "drive_id": "...", "folder_path": "/Contracts/Ammonia"}
//
// Output:
//   {"status": "ok", "file_count": 12, "files": [
//     {"item_id": "abc123", "drive_id": "drv456",
//      "name": "Koch_FOB_2026.docx", "size": 145320,
//      "sha256": "a1b2c3...", "quick_xor_hash": "...",
//      "modified_at": "2026-01-15T14:30:00Z",
//      "web_url": "https://..."}
//   ]}
// ─────────────────────────────────────────────────────────────

fn cmdScan(
    allocator: mem.Allocator,
    root: json.Value,
    stdout: anytype,
    stderr: anytype,
) !void {
    const token = getStr(root, "token") orelse {
        try writeError(stdout, allocator, "missing_field", "token is required");
        return;
    };
    const drive_id = getStr(root, "drive_id") orelse {
        try writeError(stdout, allocator, "missing_field", "drive_id is required");
        return;
    };
    const folder_path = getStr(root, "folder_path") orelse "/";

    const url = try std.fmt.allocPrint(
        allocator,
        "https://graph.microsoft.com/v1.0/drives/{s}/root:{s}:/children?$select=id,name,file,size,lastModifiedDateTime,webUrl&$top=200",
        .{ drive_id, folder_path },
    );
    defer allocator.free(url);

    try stderr.print("contract_scanner: scan url={s}\n", .{url});

    const response = graphGet(allocator, url, token) catch |err| {
        try writeError(stdout, allocator, "graph_api_error", @errorName(err));
        return;
    };
    defer allocator.free(response);

    const graph_parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
        try writeError(stdout, allocator, "graph_parse_error", "invalid Graph API response");
        return;
    };
    defer graph_parsed.deinit();

    const items_val = graph_parsed.value.object.get("value") orelse {
        try writeError(stdout, allocator, "graph_format_error", "no 'value' array in response");
        return;
    };
    const items = switch (items_val) {
        .array => |a| a,
        else => {
            try writeError(stdout, allocator, "graph_format_error", "'value' is not an array");
            return;
        },
    };

    var files = json.Array.init(allocator);
    defer files.deinit();

    for (items.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const file_prop = item_obj.get("file") orelse continue;
        const name = getStrFromObj(item_obj, "name") orelse continue;
        if (!isSupportedExt(name)) continue;

        var entry = json.ObjectMap.init(allocator);

        if (getStrFromObj(item_obj, "id")) |id| {
            try entry.put("item_id", json.Value{ .string = id });
        }
        try entry.put("name", json.Value{ .string = name });
        try entry.put("drive_id", json.Value{ .string = drive_id });

        if (item_obj.get("size")) |sz| try entry.put("size", sz);
        if (getStrFromObj(item_obj, "lastModifiedDateTime")) |m| try entry.put("modified_at", json.Value{ .string = m });
        if (getStrFromObj(item_obj, "webUrl")) |w| try entry.put("web_url", json.Value{ .string = w });

        if (extractFileHashes(file_prop)) |h| {
            if (h.sha256) |sha| try entry.put("sha256", json.Value{ .string = sha });
            if (h.quick_xor) |qx| try entry.put("quick_xor_hash", json.Value{ .string = qx });
        }

        try files.append(json.Value{ .object = entry });
    }

    var result = json.ObjectMap.init(allocator);
    defer result.deinit();
    try result.put("status", json.Value{ .string = "ok" });
    try result.put("file_count", json.Value{ .integer = @intCast(files.items.len) });
    try result.put("files", json.Value{ .array = files });
    try writeJsonLine(stdout, allocator, json.Value{ .object = result });
}

// ─────────────────────────────────────────────────────────────
// CMD: diff_hashes — compare app's stored hashes against Graph API
//
// Elixir sends the hashes it stored from previous scans.
// Zig hits Graph API for each file's current hash (metadata only,
// no downloads) and returns what's different.
//
// Input:
//   {"cmd": "diff_hashes", "token": "Bearer ...",
//    "known": [
//      {"id": "contract-uuid", "drive_id": "...", "item_id": "...",
//       "hash": "abc123..."}
//    ]}
//
// Output:
//   {"status": "ok",
//    "changed": [{"id": "...", "item_id": "...", "drive_id": "...",
//                  "old_hash": "abc123", "new_hash": "def456", "size": N}],
//    "unchanged": [{"id": "...", "item_id": "..."}],
//    "missing": [{"id": "...", "item_id": "...", "error": "..."}]}
// ─────────────────────────────────────────────────────────────

fn cmdDiffHashes(
    allocator: mem.Allocator,
    root: json.Value,
    stdout: anytype,
    stderr: anytype,
) !void {
    const token = getStr(root, "token") orelse {
        try writeError(stdout, allocator, "missing_field", "token is required");
        return;
    };

    const known_val = root.object.get("known") orelse {
        try writeError(stdout, allocator, "missing_field", "known array is required");
        return;
    };
    const known = switch (known_val) {
        .array => |a| a,
        else => {
            try writeError(stdout, allocator, "invalid_field", "known must be an array");
            return;
        },
    };

    var changed = json.Array.init(allocator);
    defer changed.deinit();
    var unchanged = json.Array.init(allocator);
    defer unchanged.deinit();
    var missing = json.Array.init(allocator);
    defer missing.deinit();

    for (known.items) |entry_val| {
        const entry_obj = switch (entry_val) {
            .object => |o| o,
            else => continue,
        };

        const id = getStrFromObj(entry_obj, "id") orelse continue;
        const drive_id = getStrFromObj(entry_obj, "drive_id") orelse continue;
        const item_id = getStrFromObj(entry_obj, "item_id") orelse continue;
        const old_hash = getStrFromObj(entry_obj, "hash") orelse continue;

        const url = try std.fmt.allocPrint(
            allocator,
            "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}?$select=file,size",
            .{ drive_id, item_id },
        );
        defer allocator.free(url);

        const response = graphGet(allocator, url, token) catch |err| {
            try stderr.print("contract_scanner: diff error {s}: {s}\n", .{ id, @errorName(err) });
            var m = json.ObjectMap.init(allocator);
            try m.put("id", json.Value{ .string = id });
            try m.put("item_id", json.Value{ .string = item_id });
            try m.put("error", json.Value{ .string = @errorName(err) });
            try missing.append(json.Value{ .object = m });
            continue;
        };
        defer allocator.free(response);

        const item_parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
            var m = json.ObjectMap.init(allocator);
            try m.put("id", json.Value{ .string = id });
            try m.put("item_id", json.Value{ .string = item_id });
            try m.put("error", json.Value{ .string = "parse_error" });
            try missing.append(json.Value{ .object = m });
            continue;
        };
        defer item_parsed.deinit();

        const current_hash = extractSha256FromItem(item_parsed.value);

        if (current_hash) |ch| {
            if (mem.eql(u8, ch, old_hash)) {
                var u = json.ObjectMap.init(allocator);
                try u.put("id", json.Value{ .string = id });
                try u.put("item_id", json.Value{ .string = item_id });
                try unchanged.append(json.Value{ .object = u });
            } else {
                var c = json.ObjectMap.init(allocator);
                try c.put("id", json.Value{ .string = id });
                try c.put("item_id", json.Value{ .string = item_id });
                try c.put("drive_id", json.Value{ .string = drive_id });
                try c.put("old_hash", json.Value{ .string = old_hash });
                try c.put("new_hash", json.Value{ .string = ch });
                if (item_parsed.value.object.get("size")) |sz| try c.put("size", sz);
                try changed.append(json.Value{ .object = c });
            }
        } else {
            var c = json.ObjectMap.init(allocator);
            try c.put("id", json.Value{ .string = id });
            try c.put("item_id", json.Value{ .string = item_id });
            try c.put("drive_id", json.Value{ .string = drive_id });
            try c.put("old_hash", json.Value{ .string = old_hash });
            try c.put("new_hash", json.Value{ .string = "unavailable" });
            try changed.append(json.Value{ .object = c });
        }
    }

    var result = json.ObjectMap.init(allocator);
    defer result.deinit();
    try result.put("status", json.Value{ .string = "ok" });
    try result.put("changed_count", json.Value{ .integer = @intCast(changed.items.len) });
    try result.put("unchanged_count", json.Value{ .integer = @intCast(unchanged.items.len) });
    try result.put("missing_count", json.Value{ .integer = @intCast(missing.items.len) });
    try result.put("changed", json.Value{ .array = changed });
    try result.put("unchanged", json.Value{ .array = unchanged });
    try result.put("missing", json.Value{ .array = missing });
    try writeJsonLine(stdout, allocator, json.Value{ .object = result });
}

// ─────────────────────────────────────────────────────────────
// CMD: hash_local — SHA-256 of a local file (testing / UNC paths)
// ─────────────────────────────────────────────────────────────

fn cmdHashLocal(
    allocator: mem.Allocator,
    root: json.Value,
    stdout: anytype,
) !void {
    const path = getStr(root, "path") orelse {
        try writeError(stdout, allocator, "missing_field", "path is required");
        return;
    };

    const file = fs.cwd().openFile(path, .{}) catch {
        try writeError(stdout, allocator, "file_not_found", path);
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch |err| {
        try writeError(stdout, allocator, "read_error", @errorName(err));
        return;
    };
    defer allocator.free(content);

    const hash_hex = computeSha256Hex(allocator, content) catch |err| {
        try writeError(stdout, allocator, "hash_error", @errorName(err));
        return;
    };
    defer allocator.free(hash_hex);

    var result = json.ObjectMap.init(allocator);
    defer result.deinit();
    try result.put("status", json.Value{ .string = "ok" });
    try result.put("path", json.Value{ .string = path });
    try result.put("sha256", json.Value{ .string = hash_hex });
    try result.put("size", json.Value{ .integer = @intCast(content.len) });
    try writeJsonLine(stdout, allocator, json.Value{ .object = result });
}

// ─────────────────────────────────────────────────────────────
// SHA-256
// ─────────────────────────────────────────────────────────────

fn computeSha256Hex(allocator: mem.Allocator, data: []const u8) ![]u8 {
    var hasher = crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const hex = try allocator.alloc(u8, 64);
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

// ─────────────────────────────────────────────────────────────
// Graph API HTTP
// ─────────────────────────────────────────────────────────────

fn graphGet(allocator: mem.Allocator, url: []const u8, token: []const u8) ![]u8 {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try Uri.parse(url);

    var header_buf: [8192]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = token },
            .{ .name = "Accept", .value = "application/json" },
        },
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.status != .ok) {
        return error.GraphApiError;
    }

    return try req.reader().readAllAlloc(allocator, 50 * 1024 * 1024);
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

const FileHashes = struct {
    sha256: ?[]const u8,
    quick_xor: ?[]const u8,
};

fn extractFileHashes(file_prop: json.Value) ?FileHashes {
    const file_obj = switch (file_prop) {
        .object => |o| o,
        else => return null,
    };
    const hashes_val = file_obj.get("hashes") orelse return null;
    const hashes_obj = switch (hashes_val) {
        .object => |o| o,
        else => return null,
    };
    return FileHashes{
        .sha256 = getStrFromObj(hashes_obj, "sha256Hash"),
        .quick_xor = getStrFromObj(hashes_obj, "quickXorHash"),
    };
}

fn extractSha256FromItem(item: json.Value) ?[]const u8 {
    const file_val = item.object.get("file") orelse return null;
    const file_obj = switch (file_val) {
        .object => |o| o,
        else => return null,
    };
    const hashes_val = file_obj.get("hashes") orelse return null;
    const hashes_obj = switch (hashes_val) {
        .object => |o| o,
        else => return null,
    };
    return getStrFromObj(hashes_obj, "sha256Hash");
}

fn isSupportedExt(name: []const u8) bool {
    const supported = [_][]const u8{ ".pdf", ".docx", ".docm", ".txt", ".doc" };
    const lower_ext = blk: {
        var i: usize = name.len;
        while (i > 0) {
            i -= 1;
            if (name[i] == '.') break :blk name[i..];
        }
        break :blk "";
    };
    for (supported) |ext| {
        if (std.ascii.eqlIgnoreCase(lower_ext, ext)) return true;
    }
    return false;
}

fn writeJsonLine(writer: anytype, allocator: mem.Allocator, value: json.Value) !void {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    try json.stringify(value, .{}, output.writer());
    try output.append('\n');
    try writer.writeAll(output.items);
}

fn writeError(writer: anytype, allocator: mem.Allocator, error_type: []const u8, detail: []const u8) !void {
    var obj = json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("status", json.Value{ .string = "error" });
    try obj.put("error", json.Value{ .string = error_type });
    try obj.put("detail", json.Value{ .string = detail });
    try writeJsonLine(writer, allocator, json.Value{ .object = obj });
}

fn getStr(value: json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return getStrFromObj(obj, key);
}

fn getStrFromObj(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "sha256 hash computation" {
    const allocator = std.testing.allocator;
    const result = try computeSha256Hex(allocator, "hello world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        result,
    );
}

test "supported extension check" {
    try std.testing.expect(isSupportedExt("contract.docx"));
    try std.testing.expect(isSupportedExt("contract.PDF"));
    try std.testing.expect(isSupportedExt("terms.docm"));
    try std.testing.expect(isSupportedExt("notes.txt"));
    try std.testing.expect(!isSupportedExt("image.png"));
    try std.testing.expect(!isSupportedExt("data.xlsx"));
}
