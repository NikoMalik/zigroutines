const std = @import("std");
const assert = std.debug.assert;
const os = std.os;
const linux = os.linux;
const io_uring = linux.IoUring;
const builtin = @import("builtin");
const Atomic = std.atomic.Value;

pub const ptrsize = @sizeOf(*anyopaque);
pub const uintptrmask = 1 << (8 * ptrsize) - 1;
pub const MAX_CACHED_ATTACKS = 64;
pub const DEFAULT_SIZE = 1024;
pub const stack_alignment = cpu_info.info.alignment;
pub const Stack = []align(stack_alignment) u8;

// Goroutine preemption request.
// 0xfffffade in hex.
pub const stackPreempt = uintptrmask & -1314;

// Thread is forking. Causes a split stack check failure.
// 0xfffffb2e in hex.
pub const stackFork = uintptrmask & -1234;

// stackPoisonMin is the lowest allowed stack poison value.
pub const stackPoisonMin = uintptrmask & -4096;

pub const cpu_info = struct {
    asm_t: []const u8,
    cpu_arch: builtin.cpu.arch,
    os_t: builtin.os.tag,
    alignment: usize,
    word_count: usize,
    const entry_offset = cpu_info.word_count - 1;
};

const info: cpu_info = switch (builtin.cpu.arch) {
    .x86_64 => .{ // linux,x86_64
        .asm_t = @embedFile("asm/x86_64.s"),
        .cpu_arch = .x86_64,
        .os_t = builtin.os.tag.linux,
        .alignment = 16,
        .word_count = 7,
    },
};
