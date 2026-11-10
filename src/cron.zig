//! Cron schedules, in UTC as on Railway: five fields, minute hour
//! day-of-month month day-of-week, each a `*`, numbers, ranges `a-b`, lists
//! `a,b` and steps `*/n` or `a-b/n`. Day of week runs 0-6 from Sunday, 7 is
//! Sunday too.

const std = @import("std");

pub const Time = struct { minute: u8, hour: u8, day: u8, month: u8, weekday: u8 };

/// Breaks down a Unix time, in seconds, into UTC fields.
pub fn utc(seconds: i64) Time {
    const days = @divFloor(seconds, 86400);
    const secs_of_day = @mod(seconds, 86400);
    // Howard Hinnant's days_from_civil, run backwards.
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .minute = @intCast(@mod(@divFloor(secs_of_day, 60), 60)),
        .hour = @intCast(@divFloor(secs_of_day, 3600)),
        .day = @intCast(d),
        .month = @intCast(m),
        .weekday = @intCast(@mod(days + 4, 7)),
    };
}

/// A field as a bit set of the values it accepts.
fn parseField(text: []const u8, min: u8, max: u8) !u64 {
    var set: u64 = 0;
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |item| {
        if (item.len == 0) return error.BadCron;
        var range = item;
        var step: u8 = 1;
        if (std.mem.indexOfScalar(u8, item, '/')) |i| {
            range = item[0..i];
            step = std.fmt.parseInt(u8, item[i + 1 ..], 10) catch return error.BadCron;
            if (step == 0) return error.BadCron;
        }
        var lo = min;
        var hi = max;
        if (!std.mem.eql(u8, range, "*")) {
            if (std.mem.indexOfScalar(u8, range, '-')) |i| {
                lo = std.fmt.parseInt(u8, range[0..i], 10) catch return error.BadCron;
                hi = std.fmt.parseInt(u8, range[i + 1 ..], 10) catch return error.BadCron;
            } else {
                lo = std.fmt.parseInt(u8, range, 10) catch return error.BadCron;
                // "5/15" means from 5 to the end, every 15.
                hi = if (step > 1) max else lo;
            }
        }
        if (lo < min or hi > max or lo > hi) return error.BadCron;
        var v = lo;
        while (v <= hi) : (v += step) {
            set |= @as(u64, 1) << @intCast(v);
            if (@as(u16, v) + step > 255) break;
        }
    }
    return set;
}

pub const Schedule = struct {
    minutes: u64,
    hours: u64,
    days: u64,
    months: u64,
    weekdays: u64,
    any_day: bool,
    any_weekday: bool,

    pub fn parse(text: []const u8) !Schedule {
        var fields: [5][]const u8 = undefined;
        var it = std.mem.tokenizeAny(u8, text, " \t");
        for (&fields) |*f| f.* = it.next() orelse return error.BadCron;
        if (it.next() != null) return error.BadCron;
        var weekdays = try parseField(fields[4], 0, 7);
        if (weekdays & (1 << 7) != 0) weekdays |= 1;
        return .{
            .minutes = try parseField(fields[0], 0, 59),
            .hours = try parseField(fields[1], 0, 23),
            .days = try parseField(fields[2], 1, 31),
            .months = try parseField(fields[3], 1, 12),
            .weekdays = weekdays,
            .any_day = std.mem.eql(u8, fields[2], "*"),
            .any_weekday = std.mem.eql(u8, fields[4], "*"),
        };
    }

    fn has(set: u64, v: u8) bool {
        return set & (@as(u64, 1) << @intCast(v)) != 0;
    }

    pub fn matches(self: Schedule, when: Time) bool {
        if (!has(self.minutes, when.minute) or !has(self.hours, when.hour) or !has(self.months, when.month)) return false;
        // As in classic cron: when both day fields are restricted, either may match.
        const day_ok = has(self.days, when.day);
        const weekday_ok = has(self.weekdays, when.weekday);
        if (self.any_day) return weekday_ok;
        if (self.any_weekday) return day_ok;
        return day_ok or weekday_ok;
    }
};

pub fn valid(text: []const u8) bool {
    _ = Schedule.parse(text) catch return false;
    return true;
}

const t = std.testing;

test "UTC breakdown" {
    // 2026-11-10 01:32:12 UTC, a Tuesday.
    const x = utc(1794274332);
    try t.expectEqual(@as(u8, 2026 - 2026 + 10), x.day);
    try t.expectEqual(@as(u8, 11), x.month);
    try t.expectEqual(@as(u8, 1), x.hour);
    try t.expectEqual(@as(u8, 32), x.minute);
    try t.expectEqual(@as(u8, 2), x.weekday);
    // 1970-01-01 was a Thursday.
    try t.expectEqual(@as(u8, 4), utc(0).weekday);
    // 2024-02-29, a leap day.
    const leap = utc(1709164800);
    try t.expectEqual(@as(u8, 29), leap.day);
    try t.expectEqual(@as(u8, 2), leap.month);
}

test "schedules match the right minutes" {
    const every5 = try Schedule.parse("*/5 * * * *");
    try t.expect(every5.matches(.{ .minute = 10, .hour = 3, .day = 1, .month = 1, .weekday = 0 }));
    try t.expect(!every5.matches(.{ .minute = 11, .hour = 3, .day = 1, .month = 1, .weekday = 0 }));

    const weekdays9 = try Schedule.parse("0 9 * * 1-5");
    try t.expect(weekdays9.matches(.{ .minute = 0, .hour = 9, .day = 10, .month = 11, .weekday = 2 }));
    try t.expect(!weekdays9.matches(.{ .minute = 0, .hour = 9, .day = 8, .month = 11, .weekday = 0 }));

    const sunday = try Schedule.parse("30 2 * * 7");
    try t.expect(sunday.matches(.{ .minute = 30, .hour = 2, .day = 8, .month = 11, .weekday = 0 }));

    const either = try Schedule.parse("0 0 1 * 1");
    try t.expect(either.matches(.{ .minute = 0, .hour = 0, .day = 1, .month = 3, .weekday = 4 }));
    try t.expect(either.matches(.{ .minute = 0, .hour = 0, .day = 9, .month = 3, .weekday = 1 }));
    try t.expect(!either.matches(.{ .minute = 0, .hour = 0, .day = 9, .month = 3, .weekday = 2 }));

    const list = try Schedule.parse("5,35 */6 * 1,7 *");
    try t.expect(list.matches(.{ .minute = 35, .hour = 18, .day = 4, .month = 7, .weekday = 3 }));
    try t.expect(!list.matches(.{ .minute = 35, .hour = 19, .day = 4, .month = 7, .weekday = 3 }));
}

test "bad schedules are refused" {
    for ([_][]const u8{ "", "* * * *", "* * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "*/0 * * * *", "a * * * *", "5-1 * * * *" }) |bad| {
        try t.expect(!valid(bad));
    }
}
