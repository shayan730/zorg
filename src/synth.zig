// zig run src/synth.zig | aplay -r 44100 -f S16_LE -c 1 -t raw
// zig run src/synth.zig | pacat --format=s16le --rate=44100 --channels=1 --raw --latency-msec=5

const std = @import("std");
const math = std.math;
const Io = std.Io;
const posix = std.posix;

const sample_rate: u32 = 44100;
const sample_rate_f: f32 = 44100.0;

const amplitude: f32 = 0.5;

const min_note_duration: f32 = 0.1;
const max_note_duration: f32 = 5;

const two_pi: f32 = 2.0 * math.pi;
const dt: f32 = 1.0 / sample_rate_f;

var freq_multiplier: f32 = 1.0;

fn randFreq(rng: std.Random) f32 {
    const semitone_offset = std.Random.intRangeAtMost(rng, i32, -12, 12);

    return 440.0 * math.pow(
        f32,
        2.0,
        @as(f32, @floatFromInt(semitone_offset)) / 12.0,
    );
}

fn randDurationSamples(rng: std.Random) u32 {
    const dur =
        min_note_duration +
        std.Random.float(rng, f32) *
            (max_note_duration - min_note_duration);

    return @intFromFloat(dur * sample_rate_f);
}

fn setupRawInput() void {
    var termios = posix.tcgetattr(posix.STDIN_FILENO) catch return;
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.cc[@intFromEnum(posix.V.MIN)] = 0;
    termios.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, termios) catch return;
}

fn pollInput() void {
    var buf: [8]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch return;
    if (n >= 3 and buf[0] == 0x1b and buf[1] == '[') {
        if (buf[2] == 'A') {
            freq_multiplier *= 2.0;
        } else if (buf[2] == 'B') freq_multiplier /= 2.0;
    }
}

fn writePcmToStdout(io: Io) !void {
    setupRawInput();
    var stdout_buf: [512]u8 = undefined;

    var stdout_writer: Io.File.Writer =
        .init(.stdout(), io, &stdout_buf);

    const writer = &stdout_writer.interface;

    var pcm_buf: [2]u8 = undefined;

    const fade_samples: u32 =
        @intFromFloat(0.005 * sample_rate_f);

    var echo_buffer: [sample_rate / 3]f32 =
        [_]f32{0} ** (sample_rate / 3);

    var echo_idx: usize = 0;

    var phase: f32 = 0.0;

    var prng = std.Random.DefaultPrng.init(
        @intCast(Io.Timestamp.now(io, .real).nanoseconds),
    );
    const rng = prng.random();

    var freq: f32 = randFreq(rng);
    var remaining: u32 = randDurationSamples(rng);
    var sample_count: u32 = 0;

    while (true) {
        phase += dt;
        const t: f32 = phase;

        if (remaining == 0) {
            freq = randFreq(rng);
            remaining = randDurationSamples(rng);
        } else {
            remaining -= 1;
        }

        sample_count += 1;
        if (sample_count >= 128) {
            sample_count = 0;
            pollInput();
        }

        const i = remaining;

        const effective_freq = freq * freq_multiplier;
        const base: f32 = @sin(two_pi * effective_freq * t);
        const detune: f32 = 0.3 * @sin(two_pi * (effective_freq * 1.003) * t);
        const octave: f32 = 0.15 * @sin(two_pi * (effective_freq * 2.0) * t);
        const tremolo: f32 = 0.75 + 0.25 * @sin(two_pi * 5.0 * t);

        var sample: f32 =
            amplitude *
            tremolo *
            (base + detune + octave) / 1.45;

        const dry = sample;

        sample += echo_buffer[echo_idx] * 0.25;
        echo_buffer[echo_idx] = dry;

        echo_idx = (echo_idx + 1) % echo_buffer.len;

        if (i < fade_samples) {
            const f =
                @as(f32, @floatFromInt(i)) /
                @as(f32, @floatFromInt(fade_samples));
            sample *= f;
        }

        sample = @max(-1.0, @min(1.0, sample));

        const pcm: i16 = @intFromFloat(sample * 32767.0);

        std.mem.writeInt(i16, &pcm_buf, pcm, .little);
        try writer.writeAll(&pcm_buf);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    _ = writePcmToStdout(io) catch {};
}
