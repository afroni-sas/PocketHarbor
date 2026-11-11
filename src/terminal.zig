//! The web terminal: `pdock exec -it` on a pseudo-terminal, relayed to a
//! WebSocket. The browser sends text frames: "i" and keystrokes, or "r" and
//! "COLS,ROWS" when its window changes size. The output goes back in binary
//! frames, as the terminal wrote it.

const std = @import("std");
const sys = @import("sys.zig");
const ws = @import("ws.zig");
const engine = @import("engine.zig");
const linux = sys.linux;
const Allocator = std.mem.Allocator;

const TIOCSCTTY: u32 = 0x540E;
const TIOCSWINSZ: u32 = 0x5414;

/// bash when the image has it, sh otherwise.
const shell = "if command -v bash >/dev/null 2>&1; then exec bash -l; fi; exec sh -l";

pub const Size = struct { cols: u16, rows: u16 };

/// "COLS,ROWS", as the browser sends it.
pub fn parseSize(text: []const u8) ?Size {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    const cols = std.fmt.parseInt(u16, text[0..comma], 10) catch return null;
    const rows = std.fmt.parseInt(u16, text[comma + 1 ..], 10) catch return null;
    if (cols == 0 or rows == 0 or cols > 1000 or rows > 500) return null;
    return .{ .cols = cols, .rows = rows };
}

fn setSize(fd: i32, size: Size) void {
    var ws_size = [4]u16{ size.rows, size.cols, 0, 0 };
    _ = linux.ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws_size));
}

/// The panel's environment, with TERM set for xterm.js.
fn environment(a: Allocator, envp: engine.Envp) ![*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        if (std.mem.startsWith(u8, std.mem.span(entry), "TERM=")) continue;
        try list.append(a, entry);
    }
    try list.append(a, "TERM=xterm-256color");
    try list.append(a, null);
    return @ptrCast(list.items.ptr);
}

/// Runs until the shell exits or the browser goes away. `fd` is the socket,
/// after the WebSocket handshake.
pub fn session(a: Allocator, fd: i32, bin: [:0]const u8, envp: engine.Envp, container: []const u8) void {
    // The panel's sockets give up after 20 s of silence; a shell may be idle.
    const none = linux.timeval{ .sec = 0, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&none), @sizeOf(linux.timeval));

    const pty = sys.openPty() catch return ws.close(fd, 1011, "no pseudo-terminal available");
    setSize(pty.master, .{ .cols = 80, .rows = 24 });
    const env = environment(a, envp) catch return ws.close(fd, 1011, "out of memory");
    const name = a.dupeSentinel(u8, container, 0) catch return ws.close(fd, 1011, "out of memory");
    const argv = [_:null]?[*:0]const u8{ "pdock", "exec", "-it", name.ptr, "/bin/sh", "-c", shell };

    const pid = sys.fork() catch return ws.close(fd, 1011, "could not start the shell");
    if (pid == 0) {
        _ = linux.setsid();
        _ = linux.ioctl(pty.slave, TIOCSCTTY, 0);
        _ = linux.dup2(pty.slave, 0);
        _ = linux.dup2(pty.slave, 1);
        _ = linux.dup2(pty.slave, 2);
        _ = linux.execve(bin.ptr, &argv, env);
        linux.exit_group(127);
    }
    sys.close(pty.slave);
    defer {
        sys.close(pty.master);
        // The shell's session goes with its terminal; make sure of it.
        _ = linux.kill(-pid, .HUP);
        var status: i32 = 0;
        var waited: u32 = 0;
        while (linux.waitpid(pid, &status, linux.W.NOHANG) == 0 and waited < 30) : (waited += 1) sys.sleepMs(100);
        if (waited == 30) {
            _ = linux.kill(-pid, .KILL);
            _ = linux.waitpid(pid, &status, 0);
        }
    }
    relay(fd, pty.master);
}

fn relay(fd: i32, master: i32) void {
    var frame_buf: [64 * 1024]u8 = undefined;
    var output: [16 * 1024]u8 = undefined;
    while (true) {
        var pfds = [2]linux.pollfd{
            .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = master, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&pfds, 2, -1);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) return;

        if (pfds[1].revents & linux.POLL.IN != 0) {
            const n = linux.read(master, &output, output.len);
            const e = linux.errno(n);
            if (e == .SUCCESS and n > 0) {
                ws.writeFrame(fd, .binary, output[0..n]) catch return;
            } else if (e != .INTR and e != .AGAIN) {
                return ws.close(fd, 1000, "the shell exited");
            }
        } else if (pfds[1].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
            return ws.close(fd, 1000, "the shell exited");
        }

        if (pfds[0].revents & linux.POLL.IN != 0) {
            const f = ws.readFrame(fd, &frame_buf) catch return;
            switch (f.opcode) {
                .text, .binary, .continuation => {
                    if (f.payload.len == 0) continue;
                    switch (f.payload[0]) {
                        'i' => sys.writeAll(master, f.payload[1..]) catch return,
                        'r' => if (parseSize(f.payload[1..])) |size| setSize(master, size),
                        else => {},
                    }
                },
                .ping => ws.writeFrame(fd, .pong, f.payload) catch return,
                .close => return ws.close(fd, 1000, ""),
                else => {},
            }
        } else if (pfds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
            return;
        }
    }
}

test "sizes from the browser" {
    try std.testing.expectEqual(Size{ .cols = 120, .rows = 40 }, parseSize("120,40").?);
    try std.testing.expect(parseSize("0,40") == null);
    try std.testing.expect(parseSize("abc") == null);
    try std.testing.expect(parseSize("5000,40") == null);
}
