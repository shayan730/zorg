// zig run src/main.zig miniaudio.c -lc -I . -- $(shuf -i 1-10 -n 1)
const std = @import("std");
const math = std.math;
const Io = std.Io;
const c = @cImport({
    @cInclude("miniaudio.h");
});

const sample_rate = 44100;
const amplitude: f32 = 0.5;
const min_note_duration: f32 = 0.02;
const max_note_duration: f32 = 0.3;

const bytes_per_sample: u32 = 2;
const num_channels: u32 = 1;
const byte_rate: u32 = sample_rate * num_channels * bytes_per_sample;
const block_align: u16 = num_channels * bytes_per_sample;

/// Function for generating the note
fn generateNotes(io: std.Io, allocator: std.mem.Allocator, total_duration: f32, notes: *std.ArrayList(f32), durations: *std.ArrayList(f32)) !void {
    var rng = std.Random.DefaultPrng.init(@intCast(Io.Timestamp.now(io, .real).nanoseconds));
    var elapsed: f32 = 0.0;

    while (elapsed < total_duration) {
        const semitone_offset = std.Random.intRangeAtMost(rng.random(), i32, -12, 12);
        const freq = 440.0 * math.pow(f32, 2.0, @floatFromInt(@divFloor(semitone_offset, @as(i32, 12.0))));
        _ = try notes.append(allocator, freq);

        const duration: f32 = min_note_duration +
            std.Random.float(rng.random(), f32) * (max_note_duration - min_note_duration);
        _ = try durations.append(allocator, duration);

        elapsed += duration;
    }
}

/// Function for saving the note
fn saveWavFile(io: std.Io, notes: []const f32, durations: []const f32) !void {
    var sample_count: u32 = 0;
    for (durations) |duration| {
        sample_count += @intFromFloat(duration * sample_rate);
    }

    const file = try std.Io.Dir.cwd().createFile(io, "sound.wav", .{});
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);

    var u32_buf: [4]u8 = undefined;
    var u16_buf: [2]u8 = undefined;
    var i16_buf: [2]u8 = undefined;

    const data_size: u32 = sample_count * bytes_per_sample;
    const chunk_size: u32 = 36 + data_size;

    // WAV HEADER
    try writer.interface.writeAll("RIFF");
    std.mem.writeInt(u32, &u32_buf, chunk_size, .little);
    try writer.interface.writeAll(&u32_buf);

    try writer.interface.writeAll("WAVE");
    try writer.interface.writeAll("fmt ");
    std.mem.writeInt(u32, &u32_buf, 16, .little);
    try writer.interface.writeAll(&u32_buf);

    std.mem.writeInt(u16, &u16_buf, 1, .little);
    try writer.interface.writeAll(&u16_buf);

    std.mem.writeInt(u16, &u16_buf, num_channels, .little);
    try writer.interface.writeAll(&u16_buf);

    std.mem.writeInt(u32, &u32_buf, sample_rate, .little);
    try writer.interface.writeAll(&u32_buf);

    std.mem.writeInt(u32, &u32_buf, byte_rate, .little);
    try writer.interface.writeAll(&u32_buf);

    std.mem.writeInt(u16, &u16_buf, block_align, .little);
    try writer.interface.writeAll(&u16_buf);

    std.mem.writeInt(u16, &u16_buf, 16, .little);
    try writer.interface.writeAll(&u16_buf);

    try writer.interface.writeAll("data");
    std.mem.writeInt(u32, &u32_buf, data_size, .little);
    try writer.interface.writeAll(&u32_buf);

    // AUDIO DATA
    const fade_time: f32 = 0.005;
    const fade_samples: u32 = @intFromFloat(fade_time * sample_rate);

    for (notes, 0..notes.len) |freq, note_idx| {
        const dur_samples: u32 = @intFromFloat(durations[note_idx] * sample_rate);

        for (0..dur_samples) |i| {
            const i_f: f32 = @as(f32, @floatFromInt(i));
            const t = i_f / sample_rate;
            var sample: f64 = amplitude * math.sin(2.0 * math.pi * freq * t);

            if (i < fade_samples) {
                const fade_factor = i_f / @as(f32, fade_samples);
                sample *= fade_factor;
            }

            if (i >= dur_samples - fade_samples) {
                const i_int: u64 = @as(u64, i);
                const fade_factor: f64 = @floatFromInt(dur_samples - i_int);
                const fade_factor_f = fade_factor / @as(f32, fade_samples);
                sample *= fade_factor_f;
            }

            const int_sample: i16 = @intFromFloat(sample * 32767.0);
            std.mem.writeInt(i16, &i16_buf, int_sample, .little);
            try writer.interface.writeAll(&i16_buf);
        }
    }
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var notes: std.ArrayList(f32) = .empty;
    defer notes.deinit(allocator);
    var durations: std.ArrayList(f32) = .empty;
    defer durations.deinit(allocator);

    const args = try init.minimal.args.toSlice(allocator);
    var total_duration_arg: ?f32 = null;
    for (args, 0..) |arg, idx| {
        if (idx == 1) total_duration_arg = try std.fmt.parseFloat(f32, arg);
    }
    const total_duration = total_duration_arg orelse 1.0;

    try generateNotes(io, allocator, total_duration, &notes, &durations);
    try saveWavFile(io, notes.items, durations.items);

    // Play WAV with Miniaudio
    var engine: c.ma_engine = undefined;
    const result = c.ma_engine_init(null, &engine);
    if (result != c.MA_SUCCESS) return error.EngineInitFailed;
    defer c.ma_engine_uninit(&engine);

    const path: [*:0]const u8 = "sound.wav";
    const play_result = c.ma_engine_play_sound(&engine, path, null);
    if (play_result != c.MA_SUCCESS) return error.SoundPlayFailed;

    std.debug.print("Playing random melody for {d} seconds ... Press Enter to quit.\n", .{total_duration});

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    _ = try stdin_reader.streamDelimiter(stdout_writer, '\n');
    _ = try stdout_writer.writeAll("Bye!");
    _ = try stdout_writer.flush();
}
