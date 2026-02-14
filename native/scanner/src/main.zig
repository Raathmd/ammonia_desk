// Contract Scanner — Zig native binary called from Elixir via Port.
//
// Responsibilities:
//   1. Scan SharePoint/OneDrive for contract files via Microsoft Graph API
//   2. Get file metadata + hashes from Graph without downloading
//   3. Download changed files, compute SHA-256 on raw bytes
//   4. Return results as JSON to Elixir over stdout
//
// Protocol: JSON lines over stdin/stdout.
//   Elixir sends a JSON command per line on stdin.
//   Scanner writes a JSON response per line on stdout.
//   stderr is used for logging (Elixir can capture or ignore).
//
// Commands:
//   scan           — list all contract files in a SharePoint folder
//   check_hashes   — compare stored hashes against current Graph API hashes
//   fetch          — download a file and return content + SHA-256 hash
//   hash_local     — compute SHA-256 of a local file (testing/fallback)
//   ping           — health check, returns {"status": "ok"}

const std = @import("std");
const crypto = std.crypto;
const json = std.json;
const mem = std.mem;
const io = std.io;
const fs = std.fs;
const http = std.http;
const Uri = std.Uri;

// ─────────────────────────────────────────────────────────────
// Entry point — read JSON commands from stdin, write responses to stdout
// ─────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    const stderr = io.getStdErr().writer();

    try stderr.print("contract_scanner: started, awaiting commands\n", .{});

    // Read lines from stdin until EOF
    while (true) {
        const line = stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024 * 1024) catch |err| {
            try writeError(stdout, allocator, "read_error", @errorName(err));
            continue;
        };

        if (line == null) break; // EOF — Elixir closed the port
        defer allocator.free(line.?);

        const trimmed = mem.trim(u8, line.?, &[_]u8{ ' ', '\t', '\r', '\n' });
        if (trimmed.len == 0) continue;

        handleCommand(allocator, trimmed, stdout, stderr) catch |err| {
            try writeError(stdout, allocator, "command_error", @errorName(err));
        };
    }

    try stderr.print("contract_scanner: stdin closed, exiting\n", .{});
}

// ─────────────────────────────────────────────────────────────
// Command dispatch
// ─────────────────────────────────────────────────────────────

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
        try writePing(stdout, allocator);
    } else if (mem.eql(u8, cmd, "scan")) {
        try cmdScan(allocator, root, stdout, stderr);
    } else if (mem.eql(u8, cmd, "check_hashes")) {
        try cmdCheckHashes(allocator, root, stdout, stderr);
    } else if (mem.eql(u8, cmd, "fetch")) {
        try cmdFetch(allocator, root, stdout, stderr);
    } else if (mem.eql(u8, cmd, "hash_local")) {
        try cmdHashLocal(allocator, root, stdout);
    } else {
        try writeError(stdout, allocator, "unknown_command", cmd);
    }
}

// ─────────────────────────────────────────────────────────────
// CMD: ping — health check
// ─────────────────────────────────────────────────────────────

fn writePing(stdout: anytype, allocator: mem.Allocator) !void {
    var obj = json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("status", json.Value{ .string = "ok" });
    try obj.put("scanner", json.Value{ .string = "contract_scanner" });
    try obj.put("version", json.Value{ .string = "1.0.0" });
    try writeJsonLine(stdout, allocator, json.Value{ .object = obj });
}

// ─────────────────────────────────────────────────────────────
// CMD: scan — list contract files in a SharePoint folder via Graph API
//
// Input:
//   {"cmd": "scan", "token": "Bearer ...", "site_id": "...",
//    "drive_id": "...", "folder_path": "/Contracts/Ammonia"}
//
// Output:
//   {"status": "ok", "files": [
//     {"item_id": "...", "name": "Koch_FOB_2026.docx",
//      "size": 145320, "sha256": "abc123...", "quick_xor": "...",
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

    // Build Graph API URL:
    // GET /drives/{drive-id}/root:{folder-path}:/children?$select=id,name,file,size,lastModifiedDateTime,webUrl
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

    // Parse Graph API response
    const graph_parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
        try writeError(stdout, allocator, "graph_parse_error", "invalid Graph API response");
        return;
    };
    defer graph_parsed.deinit();

    const graph_root = graph_parsed.value;
    const items_val = graph_root.object.get("value") orelse {
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

    // Build files array — only include actual files (have "file" property),
    // filter to supported extensions
    var files = json.Array.init(allocator);
    defer files.deinit();

    for (items.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        // Skip folders (no "file" property)
        const file_prop = item_obj.get("file") orelse continue;
        const name = getStrFromObj(item_obj, "name") orelse continue;

        // Filter to contract file extensions
        if (!isSupportedExt(name)) continue;

        var file_entry = json.ObjectMap.init(allocator);

        // Core fields
        if (getStrFromObj(item_obj, "id")) |id| {
            try file_entry.put("item_id", json.Value{ .string = id });
        }
        try file_entry.put("name", json.Value{ .string = name });
        try file_entry.put("drive_id", json.Value{ .string = drive_id });

        // Size
        if (item_obj.get("size")) |size_val| {
            try file_entry.put("size", size_val);
        }

        // Modified timestamp
        if (getStrFromObj(item_obj, "lastModifiedDateTime")) |mod| {
            try file_entry.put("modified_at", json.Value{ .string = mod });
        }

        // Web URL
        if (getStrFromObj(item_obj, "webUrl")) |web| {
            try file_entry.put("web_url", json.Value{ .string = web });
        }

        // Hashes from file.hashes
        const file_obj = switch (file_prop) {
            .object => |o| o,
            else => null,
        };

        if (file_obj) |fo| {
            if (fo.get("hashes")) |hashes_val| {
                const hashes_obj = switch (hashes_val) {
                    .object => |o| o,
                    else => null,
                };

                if (hashes_obj) |ho| {
                    if (getStrFromObj(ho, "sha256Hash")) |sha| {
                        try file_entry.put("sha256", json.Value{ .string = sha });
                    }
                    if (getStrFromObj(ho, "quickXorHash")) |qxor| {
                        try file_entry.put("quick_xor_hash", json.Value{ .string = qxor });
                    }
                }
            }
        }

        try files.append(json.Value{ .object = file_entry });
    }

    // Build response
    var result = json.ObjectMap.init(allocator);
    defer result.deinit();
    try result.put("status", json.Value{ .string = "ok" });
    try result.put("file_count", json.Value{ .integer = @intCast(files.items.len) });
    try result.put("files", json.Value{ .array = files });

    try writeJsonLine(stdout, allocator, json.Value{ .object = result });
}

// ─────────────────────────────────────────────────────────────
// CMD: check_hashes — compare stored hashes against Graph API
//
// Input:
//   {"cmd": "check_hashes", "token": "Bearer ...",
//    "files": [
//      {"drive_id": "...", "item_id": "...", "stored_hash": "abc123...",
//       "contract_id": "elixir-uuid"}
//    ]}
//
// Output:
//   {"status": "ok",
//    "changed": [{"contract_id": "...", "item_id": "...",
//                  "stored_hash": "old", "current_hash": "new", "size": 145320}],
//    "unchanged": [{"contract_id": "...", "item_id": "..."}],
//    "errors": [{"contract_id": "...", "error": "not_found"}]}
// ─────────────────────────────────────────────────────────────

fn cmdCheckHashes(
    allocator: mem.Allocator,
    root: json.Value,
    stdout: anytype,
    stderr: anytype,
) !void {
    const token = getStr(root, "token") orelse {
        try writeError(stdout, allocator, "missing_field", "token is required");
        return;
    };

    const files_val = root.object.get("files") orelse {
        try writeError(stdout, allocator, "missing_field", "files array is required");
        return;
    };

    const files = switch (files_val) {
        .array => |a| a,
        else => {
            try writeError(stdout, allocator, "invalid_field", "files must be an array");
            return;
        },
    };

    var changed = json.Array.init(allocator);
    defer changed.deinit();
    var unchanged = json.Array.init(allocator);
    defer unchanged.deinit();
    var errors = json.Array.init(allocator);
    defer errors.deinit();

    for (files.items) |file_val| {
        const file_obj = switch (file_val) {
            .object => |o| o,
            else => continue,
        };

        const contract_id = getStrFromObj(file_obj, "contract_id") orelse continue;
        const drive_id = getStrFromObj(file_obj, "drive_id") orelse continue;
        const item_id = getStrFromObj(file_obj, "item_id") orelse continue;
        const stored_hash = getStrFromObj(file_obj, "stored_hash") orelse continue;

        // Get current metadata from Graph API
        const url = try std.fmt.allocPrint(
            allocator,
            "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}?$select=file,size",
            .{ drive_id, item_id },
        );
        defer allocator.free(url);

        const response = graphGet(allocator, url, token) catch |err| {
            try stderr.print("contract_scanner: check_hash error for {s}: {s}\n", .{ contract_id, @errorName(err) });
            var err_entry = json.ObjectMap.init(allocator);
            try err_entry.put("contract_id", json.Value{ .string = contract_id });
            try err_entry.put("error", json.Value{ .string = @errorName(err) });
            try errors.append(json.Value{ .object = err_entry });
            continue;
        };
        defer allocator.free(response);

        const item_parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
            var err_entry = json.ObjectMap.init(allocator);
            try err_entry.put("contract_id", json.Value{ .string = contract_id });
            try err_entry.put("error", json.Value{ .string = "parse_error" });
            try errors.append(json.Value{ .object = err_entry });
            continue;
        };
        defer item_parsed.deinit();

        // Extract current hash
        const current_hash = extractSha256(item_parsed.value);
        const current_qxor = extractQuickXor(item_parsed.value);

        // Compare — use SHA-256 if available, fall back to quickXorHash
        const hash_match = if (current_hash) |ch|
            mem.eql(u8, ch, stored_hash)
        else if (current_qxor) |_|
            false // can't compare — different hash types, force re-check
        else
            false; // no hash available, assume changed

        if (hash_match) {
            var entry = json.ObjectMap.init(allocator);
            try entry.put("contract_id", json.Value{ .string = contract_id });
            try entry.put("item_id", json.Value{ .string = item_id });
            try unchanged.append(json.Value{ .object = entry });
        } else {
            var entry = json.ObjectMap.init(allocator);
            try entry.put("contract_id", json.Value{ .string = contract_id });
            try entry.put("item_id", json.Value{ .string = item_id });
            try entry.put("drive_id", json.Value{ .string = drive_id });
            try entry.put("stored_hash", json.Value{ .string = stored_hash });
            if (current_hash) |ch| {
                try entry.put("current_hash", json.Value{ .string = ch });
            }
            if (current_qxor) |cq| {
                try entry.put("current_quick_xor", json.Value{ .string = cq });
            }
            // Include size for the changed entry
            if (item_parsed.value.object.get("size")) |sz| {
                try entry.put("size", sz);
            }
            try changed.append(json.Value{ .object = entry });
        }
    }

    // Build response
    var result = json.ObjectMap.init(allocator);
    defer result.deinit();
    try result.put("status", json.Value{ .string = "ok" });
    try result.put("changed_count", json.Value{ .integer = @intCast(changed.items.len) });
    try result.put("unchanged_count", json.Value{ .integer = @intCast(unchanged.items.len) });
    try result.put("error_count", json.Value{ .integer = @intCast(errors.items.len) });
    try result.put("changed", json.Value{ .array = changed });
    try result.put("unchanged", json.Value{ .array = unchanged });
    try result.put("errors", json.Value{ .array = errors });

    try writeJsonLine(stdout, allocator, json.Value{ .object = result });
}

// ─────────────────────────────────────────────────────────────
// CMD: fetch — download file content from Graph API + compute SHA-256
//
// Input:
//   {"cmd": "fetch", "token": "Bearer ...",
//    "drive_id": "...", "item_id": "..."}
//
// Output:
//   {"status": "ok", "item_id": "...", "sha256": "hex...",
//    "size": 145320, "content_base64": "base64..."}
//
// The content is base64-encoded so it can travel over JSON.
// Elixir decodes it and passes the text to Copilot for extraction.
// ─────────────────────────────────────────────────────────────

fn cmdFetch(
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
    const item_id = getStr(root, "item_id") orelse {
        try writeError(stdout, allocator, "missing_field", "item_id is required");
        return;
    };

    // Download file content
    // GET /drives/{drive-id}/items/{item-id}/content
    const url = try std.fmt.allocPrint(
        allocator,
        "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}/content",
        .{ drive_id, item_id },
    );
    defer allocator.free(url);

    try stderr.print("contract_scanner: fetching {s}/{s}\n", .{ drive_id, item_id });

    const content = graphGet(allocator, url, token) catch |err| {
        try writeError(stdout, allocator, "fetch_error", @errorName(err));
        return;
    };
    defer allocator.free(content);

    // Compute SHA-256 on raw bytes
    const hash_hex = computeSha256Hex(allocator, content) catch |err| {
        try writeError(stdout, allocator, "hash_error", @errorName(err));
        return;
    };
    defer allocator.free(hash_hex);

    // Base64-encode content for JSON transport
    const b64_len = std.base64.standard.Encoder.calcSize(content.len);
    const b64_buf = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64_buf);
    _ = std.base64.standard.Encoder.encode(b64_buf, content);

    // Build response
    var result = json.ObjectMap.init(allocator);
    defer result.deinit();
    try result.put("status", json.Value{ .string = "ok" });
    try result.put("item_id", json.Value{ .string = item_id });
    try result.put("sha256", json.Value{ .string = hash_hex });
    try result.put("size", json.Value{ .integer = @intCast(content.len) });
    try result.put("content_base64", json.Value{ .string = b64_buf });

    try writeJsonLine(stdout, allocator, json.Value{ .object = result });
}

// ─────────────────────────────────────────────────────────────
// CMD: hash_local — SHA-256 of a local file (testing / UNC paths)
//
// Input:  {"cmd": "hash_local", "path": "/path/to/file.docx"}
// Output: {"status": "ok", "path": "...", "sha256": "hex...", "size": 12345}
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

    // Read file and compute hash
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
// SHA-256 hashing
// ─────────────────────────────────────────────────────────────

fn computeSha256Hex(allocator: mem.Allocator, data: []const u8) ![]u8 {
    var hasher = crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // Convert to lowercase hex
    const hex = try allocator.alloc(u8, 64);
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

// ─────────────────────────────────────────────────────────────
// Graph API HTTP client
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

    const body = try req.reader().readAllAlloc(allocator, 50 * 1024 * 1024);
    return body;
}

// ─────────────────────────────────────────────────────────────
// Graph API response helpers
// ─────────────────────────────────────────────────────────────

fn extractSha256(item: json.Value) ?[]const u8 {
    const file_obj = switch (item.object.get("file") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const hashes = switch (file_obj.get("hashes") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return getStrFromObj(hashes, "sha256Hash");
}

fn extractQuickXor(item: json.Value) ?[]const u8 {
    const file_obj = switch (item.object.get("file") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const hashes = switch (file_obj.get("hashes") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return getStrFromObj(hashes, "quickXorHash");
}

// ─────────────────────────────────────────────────────────────
// File extension filter
// ─────────────────────────────────────────────────────────────

fn isSupportedExt(name: []const u8) bool {
    const supported = [_][]const u8{ ".pdf", ".docx", ".docm", ".txt", ".doc" };
    const lower_ext = blk: {
        // Find last '.'
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

// ─────────────────────────────────────────────────────────────
// JSON output helpers
// ─────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────
// JSON value access helpers
// ─────────────────────────────────────────────────────────────

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

    // Known SHA-256 of "hello world"
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
