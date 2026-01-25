const std = @import("std");
const wss = @import("websocket");

pub const Self = @This();

allocator: std.mem.Allocator,
url: []const u8,
handshake_timeout: u32,
max_size: u32,
buffer_size: u32,
max_retries: u32,
client: ?wss.Client = null,

pub const Opts = struct {
    url: []const u8,
    handshake_timeout: u32 = 10000,
    max_size: u32 = 4096,
    buffer_size: u32 = 1024,
    max_retries: u32 = 10,
};

pub fn init(allocator: std.mem.Allocator, opts: Opts) !Self {
    return Self{
        .allocator = allocator,
        .url = try allocator.dupeZ(u8, opts.url),
        .handshake_timeout = opts.handshake_timeout,
        .max_size = opts.max_size,
        .buffer_size = opts.buffer_size,
        .max_retries = opts.max_retries,
    };
}

pub fn deinit(self: *Self) void {
    self.deinitClient();
    self.allocator.free(self.url);
}

fn deinitClient(self: *Self) void {
    if (self.client) |*client| {
        client.deinit();
        self.client = null;
    }
}

pub fn connectWebSocket(self: *Self) !void {
    const uri = try std.Uri.parse(self.url);

    const host_component = uri.host.?;
    const host = switch (host_component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };

    const port: u16 = uri.port orelse if (std.mem.eql(u8, uri.scheme, "wss")) 443 else 80;
    const is_tls = std.mem.eql(u8, uri.scheme, "wss");

    std.log.info("ws connection details: host={s}, port={}, tls={}", .{ host, port, is_tls });

    self.client = try wss.Client.init(self.allocator, .{
        .port = port,
        .host = host,
        .tls = is_tls,
        .max_size = self.max_size,
        .buffer_size = self.buffer_size,
    });

    const path = switch (uri.path) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };

    const headers = try std.fmt.allocPrint(self.allocator, "Host: {s}", .{host});
    defer self.allocator.free(headers);

    self.client.?.handshake(path, .{
        .timeout_ms = self.handshake_timeout,
        .headers = headers,
    }) catch |err| {
        std.log.err("ws handshake failed: {}", .{err});
        return err;
    };

    std.log.info("✓ ws connection and handshake successful!", .{});
}

pub fn reconnect(self: *Self) !void {
    self.deinitClient();

    var retry_count: u32 = 0;
    const max_retries = self.max_retries;
    var backoff_ms: u64 = 1000; // Start with 1 second

    while (retry_count < max_retries) {
        std.log.info("Reconnection attempt {} of {}", .{ retry_count + 1, max_retries });

        // wait before retry (exponential backoff)
        if (retry_count > 0) {
            std.log.info("Waiting {}ms before retry...", .{backoff_ms});
            std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms *= 2; // Double the backoff time
        }

        self.connectWebSocket() catch |reconnect_err| {
            std.log.warn("Reconnection attempt {} failed: {}", .{ retry_count + 1, reconnect_err });
            retry_count += 1;
            continue;
        };

        std.log.info("reconnected and re-subscribed successfully after {} attempts", .{retry_count + 1});
        break;
    } else {
        std.log.err("failed to reconnect after {} attempts, giving up", .{max_retries});
        return error.ReconnectionFailed;
    }
}

pub fn write(self: *Self, data: []u8) !void {
    if (self.client) |*client| {
        try client.write(data);
    } else {
        return error.ClientNotConnected;
    }
}

pub fn writePong(self: *Self, data: []u8) !void {
    if (self.client) |*client| {
        try client.writePong(data);
    } else {
        return error.ClientNotConnected;
    }
}

pub fn read(self: *Self) !?wss.Message {
    if (self.client) |*client| {
        return try client.read();
    }
    return error.ClientNotConnected;
}

pub fn readTimeout(self: *Self, timeout_ms: u32) !void {
    if (self.client) |*client| {
        try client.readTimeout(timeout_ms);
    } else {
        return error.ClientNotConnected;
    }
}

pub fn done(self: *Self, msg: wss.Message) void {
    if (self.client) |*client| {
        client.done(msg);
    }
}

pub fn close(self: *Self, opts: anytype) !void {
    if (self.client) |*client| {
        try client.close(opts);
    } else {
        return error.ClientNotConnected;
    }
}
