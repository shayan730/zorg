// zig run src/main.zig -- 5 | aplay -f S16_LE -r 44100 -c 1
const std = @import("std");
const math = std.math;
const Io = std.Io;

const sample_rate: u32 = 44100;
const amplitude: f32 = 0.5;
const min_note_duration: f32 = 0.02;
const max_note_duration: f32 = 0.3;

fn generateNotes(io: Io, allocator: std.mem.Allocator, total_duration: f32, notes: *std.ArrayList(f32), durations: *std.ArrayList(f32)) !void {
    var rng = std.Random.DefaultPrng.init(@intCast(Io.Timestamp.now(io, .real).nanoseconds));
    var elapsed: f32 = 0.0;

    while (elapsed < total_duration) {
        const semitone_offset = std.Random.intRangeAtMost(rng.random(), i32, -12, 12);
        const freq: f32 = 440.0 * math.pow(f32, 2.0, @as(f32, @floatFromInt(semitone_offset)) / 12.0);
        _ = try notes.append(allocator, freq);

        const duration: f32 = min_note_duration + std.Random.float(rng.random(), f32) * (max_note_duration - min_note_duration);
        _ = try durations.append(allocator, duration);
        elapsed += duration;
    }
}

fn writePcmToStdout(io: Io, notes: []const f32, durations: []const f32) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &stdout_file_writer.interface;

    var i16_buf: [2]u8 = undefined;
    const fade_samples: u32 = @intFromFloat(0.005 * @as(f32, @floatFromInt(sample_rate)));

    for (notes, 0..) |freq, note_idx| {
        const dur_samples: u32 = @intFromFloat(durations[note_idx] * @as(f32, @floatFromInt(sample_rate)));

        for (0..dur_samples) |i| {
            const i_f: f32 = @floatFromInt(i);
            const t: f32 = i_f / @as(f32, @floatFromInt(sample_rate));
            var sample: f32 = amplitude * @sin(2.0 * math.pi * freq * t);

            if (i < fade_samples) {
                sample *= i_f / @as(f32, @floatFromInt(fade_samples));
            }

            if (i >= dur_samples - fade_samples) {
                const remaining: f32 = @floatFromInt(dur_samples - @as(u32, @intCast(i)));
                sample *= remaining / @as(f32, @floatFromInt(fade_samples));
            }

            std.mem.writeInt(i16, &i16_buf, @intFromFloat(sample * 32767.0), .little);
            try writer.writeAll(&i16_buf);
        }
    }
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var notes: std.ArrayList(f32) = .empty;
    defer notes.deinit(allocator);
    var durations: std.ArrayList(f32) = .empty;
    defer durations.deinit(allocator);

    const args = try init.minimal.args.toSlice(allocator);
    var total_duration: f32 = 1.0;
    if (args.len > 1) {
        total_duration = try std.fmt.parseFloat(f32, args[1]);
    }
    try generateNotes(io, allocator, total_duration, &notes, &durations);

    var stderr_buf: [256]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    try stderr_writer.interface.print("{d} notes, {d:.1}s\n", .{ notes.items.len, total_duration });
    try writePcmToStdout(io, notes.items, durations.items);
}
