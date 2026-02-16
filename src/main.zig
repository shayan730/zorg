// zig run src/main.zig miniaudio.c -lc -I .

const std = @import("std");

const c = @cImport({
    @cInclude("miniaudio.h");
});
const Io = std.Io;
const math = std.math;

const sample_rate = 44100;
const duration = 0.2 * 10; // seconds
const frequency = 440.0;
const amplitude = 0.5;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const sample_count: u32 = @intFromFloat(duration * sample_rate);
    const bytes_per_sample: u32 = 2; // 16-bit PCM
    const num_channels: u32 = 1;
    const byte_rate: u32 = sample_rate * num_channels * bytes_per_sample;
    const block_align: u16 = num_channels * bytes_per_sample;
    const data_size: u32 = sample_count * bytes_per_sample;
    const chunk_size: u32 = 36 + data_size;

    const file = try std.Io.Dir.cwd().createFile(io, "sound.wav", .{});
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);

    // helper buffers for integer writing
    var u32_buf: [4]u8 = undefined;
    var u16_buf: [2]u8 = undefined;
    var i16_buf: [2]u8 = undefined;

    // --- WAV HEADER ---

    try writer.interface.writeAll("RIFF");

    std.mem.writeInt(u32, &u32_buf, chunk_size, .little);
    try writer.interface.writeAll(&u32_buf);

    try writer.interface.writeAll("WAVE");

    try writer.interface.writeAll("fmt ");
    std.mem.writeInt(u32, &u32_buf, 16, .little);
    try writer.interface.writeAll(&u32_buf);

    std.mem.writeInt(u16, &u16_buf, 1, .little); // PCM
    try writer.interface.writeAll(&u16_buf);

    std.mem.writeInt(u16, &u16_buf, num_channels, .little);
    try writer.interface.writeAll(&u16_buf);

    std.mem.writeInt(u32, &u32_buf, sample_rate, .little);
    try writer.interface.writeAll(&u32_buf);

    std.mem.writeInt(u32, &u32_buf, byte_rate, .little);
    try writer.interface.writeAll(&u32_buf);

    std.mem.writeInt(u16, &u16_buf, block_align, .little);
    try writer.interface.writeAll(&u16_buf);

    std.mem.writeInt(u16, &u16_buf, 16, .little); // bits per sample
    try writer.interface.writeAll(&u16_buf);

    try writer.interface.writeAll("data");

    std.mem.writeInt(u32, &u32_buf, data_size, .little);
    try writer.interface.writeAll(&u32_buf);

    // --- AUDIO DATA ---

    var i: u32 = 0;
    while (i < sample_count) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / sample_rate;
        const sample = amplitude *
            @sin(2.0 * math.pi * frequency * t);

        const int_sample: i16 = @intFromFloat(sample * 32767.0);

        std.mem.writeInt(i16, &i16_buf, int_sample, .little);
        try writer.interface.writeAll(&i16_buf);
    }

    try writer.interface.flush();

    var engine: c.ma_engine = undefined;

    // Passing null to config uses defaults
    const result = c.ma_engine_init(null, &engine);
    std.debug.print("engine init result: {d}\n", .{result});
    if (result != c.MA_SUCCESS) {
        std.debug.print("Failed to initialize engine. Error: {d}\n", .{result});
        return error.EngineInitFailed;
    }
    defer c.ma_engine_uninit(&engine);

    // 2. Play the sound
    // Use a null-terminated string literal explicitly

    const path: [*:0]const u8 = "sound.wav";

    const play_result = c.ma_engine_play_sound(&engine, path, null);

    if (play_result != c.MA_SUCCESS) {
        // -7 = MA_INVALID_ARGS
        std.debug.print("Error playing sound: {d}\n", .{play_result});
        return error.SoundPlayFailed;
    } // Use a null-terminated string literal explicitly

    // 3. Keep the program alive
    // ma_engine_play_sound is asynchronous.
    // If the program exits immediately, you won't hear anything!
    std.debug.print("Playing sound... Press Enter to quit.", .{});

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

