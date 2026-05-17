// zig run src/main.zig -- 5 | aplay -f S16_LE -r 44100 -c 1

const std = @import("std");
const math = std.math;
const Io = std.Io;

const sample_rate: u32 = 44100;
const sample_rate_f: f32 = 44100.0;

const amplitude: f32 = 0.5;

const min_note_duration: f32 = 0.02;
const max_note_duration: f32 = 0.3;

const two_pi: f32 = 2.0 * math.pi;
const dt: f32 = 1.0 / sample_rate_f;

fn generateNotes(
    io: Io,
    allocator: std.mem.Allocator,
    total_duration: f32,
    notes: *std.ArrayList(f32),
    durations: *std.ArrayList(f32),
) !void {
    var rng = std.Random.DefaultPrng.init(
        @intCast(Io.Timestamp.now(io, .real).nanoseconds),
    );

    var elapsed: f32 = 0.0;

    while (elapsed < total_duration) {
        const semitone_offset = std.Random.intRangeAtMost(
            rng.random(),
            i32,
            -12,
            12,
        );

        const freq: f32 =
            440.0 *
            math.pow(
                f32,
                2.0,
                @as(f32, @floatFromInt(semitone_offset)) / 12.0,
            );

        _ = try notes.append(allocator, freq);

        const duration: f32 =
            min_note_duration +
            std.Random.float(rng.random(), f32) *
                (max_note_duration - min_note_duration);

        _ = try durations.append(allocator, duration);

        elapsed += duration;
    }
}

fn writePcmToStdout(
    io: Io,
    notes: []const f32,
    durations: []const f32,
) !void {
    var stdout_buf: [8192]u8 = undefined;

    var stdout_writer: Io.File.Writer =
        .init(.stdout(), io, &stdout_buf);

    const writer = &stdout_writer.interface;

    var pcm_buf: [2]u8 = undefined;

    const fade_samples: u32 =
        @intFromFloat(0.005 * sample_rate_f);

    // ~333ms echo
    var echo_buffer: [sample_rate / 3]f32 =
        [_]f32{0} ** (sample_rate / 3);

    var echo_idx: usize = 0;

    // Continuous global phase
    var phase: f32 = 0.0;

    for (notes, 0..) |freq, note_idx| {
        const dur_samples: u32 =
            @intFromFloat(
                durations[note_idx] * sample_rate_f,
            );

        for (0..dur_samples) |i| {
            phase += dt;

            const t: f32 = phase;

            // Main oscillator
            const base: f32 =
                @sin(two_pi * freq * t);

            // Slightly detuned oscillator
            const detune: f32 =
                0.3 *
                @sin(
                    two_pi *
                        (freq * 1.003) *
                        t,
                );

            // Octave harmonic
            const octave: f32 =
                0.15 *
                @sin(
                    two_pi *
                        (freq * 2.0) *
                        t,
                );

            // Slow tremolo
            const tremolo: f32 =
                0.75 +
                0.25 *
                    @sin(
                        two_pi *
                            5.0 *
                            t,
                    );

            // Oscillator mix
            var sample: f32 =
                amplitude *
                tremolo *
                (base + detune + octave) /
                1.45;

            const dry = sample;

            // Echo
            sample +=
                echo_buffer[echo_idx] * 0.25;

            // Store dry only
            echo_buffer[echo_idx] = dry;

            echo_idx =
                (echo_idx + 1) %
                echo_buffer.len;

            // Fade in
            if (i < fade_samples) {
                sample *=
                    @as(f32, @floatFromInt(i)) /
                    @as(f32, @floatFromInt(fade_samples));
            }

            // Fade out
            if (i >= dur_samples - fade_samples) {
                const remaining: f32 =
                    @floatFromInt(
                        dur_samples -
                            @as(u32, @intCast(i)),
                    );

                sample *=
                    remaining /
                    @as(f32, @floatFromInt(fade_samples));
            }

            // Clamp
            sample = @max(
                -1.0,
                @min(1.0, sample),
            );

            // Convert to PCM16
            const pcm: i16 =
                @intFromFloat(sample * 32767.0);

            std.mem.writeInt(
                i16,
                &pcm_buf,
                pcm,
                .little,
            );

            try writer.writeAll(&pcm_buf);
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

    const args =
        try init.minimal.args.toSlice(allocator);

    var total_duration: f32 = 1.0;

    if (args.len > 1) {
        total_duration =
            try std.fmt.parseFloat(
                f32,
                args[1],
            );
    }

    try generateNotes(
        io,
        allocator,
        total_duration,
        &notes,
        &durations,
    );

    var stderr_buf: [256]u8 = undefined;

    var stderr_writer: Io.File.Writer =
        .init(.stderr(), io, &stderr_buf);

    try stderr_writer.interface.print(
        "{d} notes, {d:.1}s\n",
        .{
            notes.items.len,
            total_duration,
        },
    );

    try writePcmToStdout(
        io,
        notes.items,
        durations.items,
    );
}
