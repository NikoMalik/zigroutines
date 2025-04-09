const std = @import("std");
const assert = std.debug.assert;
const os = std.os;
const linux = os.linux;
const io_uring = linux.IoUring;
const builtin = @import("builtin");
const Atomic = std.atomic.Value;
const stack = @import("stack.zig");

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("sorry,only linux for now");
    }
}

pub const Error = error{
    StackTooSmall,
    StackTooLarge,
    Undefined,
    Unexpected,
    PermissionDenied,
    SystemResources,
    SubmissionQueueFull,
    ResourceLimitReached,
    ThreadQuotaExceeded,
    LockedMemoryLimitExceeded,
};

// const m0 = m;
// const z0 = m;
// const mcache0: *mcache;

const isDebug = std.builtin.Mode.Debug == builtin.mode;
const isRelease = std.builtin.Mode.Debug != builtin.mode and !isTest;
const isTest = builtin.is_test;
const allow_assert = isDebug or isTest or std.builtin.OptimizeMode.ReleaseSafe == builtin.mode;

const status_z = union(enum(u8)) {
    IDLE = 0,
    RUNNABLE = 1,
    RUNNING = 2,
    SYSCALL = 3,
    WAITING = 4,
    DEAD = 5,
    COPY_STACK = 6,
    PREEMPTED = 7,
};

const status_p = union(enum(u8)) {
    IDLE = 0,
    RUNNING = 1,
    SYSCALL = 2,
    STOP = 3,
    DEAD = 4,
};

const status_m = union(enum(u8)) {
    freeMsStack = 0, // m done, free stack and reference
    freeMref = 1, // m done free reference
    freeMwait = 2, //m swill in use

};

//TODO: make M:N without p

const _SCAN = 0x1000;
const _SCANRUNNABLE = 0x1001;
const _SCANSYSCALL = 0x1003;
const _SCANWAITING = 0x1004;
const _SCANPREEMTED = 0x1009;

//=================================================//
//tls:
//A “snapshot” of the processor state associated with a particular zigroutine. Without it, runtime would not be able to switch between zigroutines, preserving their execution.
//
//
threadlocal var current_zigroutine: ?*z = null;

threadlocal var m_tls: m = .{};
//=================================================//

//context for current zigroutine
const zoobuf = packed struct { //state
    //pointers
    caller_context: *anyopaque,
    stack_context: *anyopaque,
    user_data: usize,

    const func = *const fn (
        from: *z,
        to: *z,
    ) callconv(.C) noreturn;

    fn init(
        s: stack.Stack,
        user_data: usize,
        args_size: usize,
        entry_point: func,
    ) Error!*zoobuf {
        const stack_base = @intFromPtr(s.ptr);
        const stack_end = @intFromPtr(s.ptr + stack.len);
        var stack_ptr = std.mem.alignBackward(usize, stack_end - @sizeOf(zoobuf), stack.stack_alignment);
        if (stack_ptr < stack_base) return error.StackTooSmall;

        const state: *zoobuf = @ptrFromInt(stack_ptr);

        stack_ptr = std.mem.alignBackward(usize, stack_ptr - args_size, stack.stack_alignment);
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Reserve data for the StackContext.
        stack_ptr = std.mem.alignBackward(
            usize,
            stack_ptr - @sizeOf(usize) * stack.cpu_info.info.word_count,
            stack.stack_alignment,
        );
        if (comptime allow_assert) {
            assert(std.mem.isAligned(stack_ptr, stack.stack_alignment));
        }
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Write the entry point into the StackContext.
        var entry: [*]@TypeOf(entry_point) = @ptrFromInt(stack_ptr);
        entry[stack.info.entry_offset] = entry_point;

        state.* = .{
            .caller_context = undefined,
            .stack_context = @ptrFromInt(stack_ptr),
            .user_data = user_data,
        };

        return state;
    }
};
//sudog
// zigroutine in waitlist
const zoo_waitlist = struct {
    zoo: *z, //// pointer to zigroutine
    next: *zoo_waitlist, // The next waitlist on the waiting list
    prev: *zoo_waitlist, //// Previous sudog in the list
    elem: usize, //pointer to value
    acquiretime: i64, //time block
    releasetime: i64, //time unblock
    ticket: u32, // “Ticket” for ordering
    isSelect: bool, // if using in select
    success: bool, // Whether the operation is successful (e.g. channel closed or data received)
    waiters: u16, //count of waiters in semaphore
    parent: *zoo_waitlist,
    waitlink: *zoo_waitlist,
    waittail: *zoo_waitlist,
    // ch: *zoo_channel //channel where goroutine is locked
    //One goroutine can wait on several channels (e.g., select).
    //Several goroutines can wait on one channel.
    // binds goroutine (g) to a synchronization object (e.g., channel hchan).
};

pub const z = struct {
    id: u64, // id zigroutine
    parent_id: u64, // parent of goroutine
    zoo_pc: usize, // instructions for pc created by zigroutine
    // start_pc: usize, //pc functions goroutine #address begin of function zigroutine

    stack: [*]u8 align(stack.stack_alignment), // stack context
    stackguard0: usize, // pointer to check stack growth in regular code
    stackguard1: usize, // pointer to check stack growth in syscalls

    syscallsp: usize,
    syscallpc: usize,
    syscallbp: usize,
    stktopsp: usize,

    param: usize,

    m: *m, // current thread
    sched: zoobuf, // registers sp,pc and etc.. for save and restore zigroutine

    next_zigroutine: usize,

    atomic_status: Atomic(status_z), //atomic load status zigroutine
    waitsince: i64, // approx time when the z become blocked
    wait_reason: waitReason, //why zigroutine is blocked
    preempt: bool, // signal for displacement
    preemptStop: bool, // signal for displacement when stop

    parking_on_chan: bool, //parking on operation with channel

    waiting: ?*zoo_waitlist, // list of sudog, where zigroutine is waiting
    selectDone: Atomic(u32), // using in select and win in race data

    const Self = @This();
    const func_z = *const fn (
        from: *z,
        to: *z,
    ) callconv(.C) noreturn;

    pub fn createZigRoutine(entry_point: fn (usize) void, user_data: usize, allocator: std.mem.Allocator) !*z {
        const zig = try allocator.create(z);
        const s = try allocator.alignedAlloc(u8, stack.stack_alignment, stack.DEFAULT_SIZE);
        zig.stack = s.ptr;
        zig.sched = try zoobuf.init(.{ .ptr = stack.ptr, .len = s.len }, user_data, 0, entry_point);
        zig.atomic_status = std.atomic.Atomic(u32).init(@intFromEnum(status_z.RUNNABLE));
        zig.m = &m_tls; // bind with current thread
        try schedt.runq.add(zig); // add to queue
        return zig;
    }
};

const unlockf = *const fn (from: *z, *anyopaque) bool;
fn checkTimeouts() void {}
pub fn switchTo(zig: *z) void {
    const state: *zoobuf = &zig.sched;

    const old_state = current_zigroutine;
    assert(old_state != state);
    current_zigroutine = state;
    defer current_zigroutine = old_state;

    stack_swap(&state.caller_context, &state.stack_context);
}
pub inline fn current() ?*z {
    return current_zigroutine;
}

fn acquirem() *m {
    const zp = current();
    zp.?.m.locks + 1;
    return zp.m;
}

fn releasemem(mp: *m) void {
    var zp = current();
    mp.locks - 1;
    if (mp.locks == 0 and zp.?.preempt) {
        zp.?.stackguard0 = stack.stackPreempt;
    }
}

fn readzstatus(zp: *z) u32 {
    return zp.atomic_status.load(.acquire);
}

pub fn zoopark(
    unlockfn: unlockf,
    lock: *anyopaque,
    reason: waitReason,
    traceReason: traceBlockReason,
    traceskip: isize,
) void {
    if (reason != .waitReasonSLeep) {
        checkTimeouts(); //timeouts may expire while two goroutines keep the scheduler busy
    }
    var mp = acquirem();
    var zp = mp.curz;
    const status = readzstatus(zp);
    if ((status != .RUNNING)) {
        @compileLog("zoopark: bad z status");
    }
    mp.waitlock = lock;
    mp.waitunlockf = unlockfn;
    zp.?.wait_reason = reason;
    mp.waitTraceBlockReason = traceReason;
    mp.waitTraceSkip = traceskip;
    releasemem(mp);

    //park_m
}

//
// traceBlockReason is an enumeration of reasons a goroutine might block.
// This is the interface the rest of the runtime uses to tell the
// tracer why a goroutine blocked. The tracer then propagates this information
// into the trace however it sees fit.
//
// Note that traceBlockReasons should not be compared, since reasons that are
// distinct by name may *not* be distinct by value.
//
const traceBlockReason = union(enum(u8)) {
    traceBlockGeneric,
    traceBlockForever,
    traceBlockNet,
    traceBlockSelect,
    traceBlockCondWait,
    traceBlockSync,
    traceBlockChanSend,
    traceBlockChanRecv,
    traceBlockSystemGoroutine,
    traceBlockPreempted,
    traceBlockDebugCall,
    traceBlockSleep,
    traceBlockSynctest,
    traceBlockGCWeakToStrongWait,
};

const waitReason = union(enum(u8)) {
    waitReasonZero,
    waitReasonIOWait, // "IO wait"
    waitReasonChanReceiveNilChan, // "chan receive (nil chan)"
    waitReasonChanSendNilChan, // "chan send (nil chan)"
    waitReasonDumpingHeap, // "dumping heap"
    waitReasonSelect, // "select"
    waitReasonSelectNoCases, // "select (no cases)"
    waitReasonChanReceive, // "chan receive"
    waitReasonChanSend, // "chan send"
    waitReasonFinalizerWait, // "finalizer wait"
    waitReasonSemacquire, // "semacquire"
    waitReasonSleep, // "sleep"
    waitReasonSyncCondWait, // "sync.Cond.Wait"
    waitReasonSyncMutexLock, // "sync.Mutex.Lock"
    waitReasonSyncRWMutexRLock, // "sync.RWMutex.RLock"
    waitReasonSyncRWMutexLock, // "sync.RWMutex.Lock"
    waitReasonSyncWaitGroupWait, // "sync.WaitGroup.Wait"
    waitReasonTraceReaderBlocked, // "trace reader (blocked)"
    waitReasonPreempted, // "preempted"
    waitReasonDebugCall, // "debug call"
    waitReasonStoppingTheWorld, // "stopping the world"
    waitReasonFlushProcCaches, // "flushing proc caches"
    waitReasonTraceGoroutineStatus, // "trace goroutine status"
    waitReasonTraceProcStatus, // "trace proc status"
    waitReasonPageTraceFlush, // "page trace flush"
    waitReasonCoroutine, // "coroutine"
    waitReasonSynctestRun, // "synctest.Run"
    waitReasonSynctestWait, // "synctest.Wait"
    waitReasonSynctestChanReceive, // "chan receive (synctest)"
    waitReasonSynctestChanSend, // "chan send (synctest)"
    waitReasonSynctestSelect, // "select (synctest)"

};

//thread os
const m = struct {
    id: i64, // unique ID thread
    z0: *z, // z0 for runtime code
    curz: ?*z, // current running zigroutine
    p: ?*p, // M:N
    spinning: bool, // thread find job
    blocked: bool, // thread locked
    locks: i32,
    waitlock: *anyopaque,
    waitunlockf: *anyopaque,
    waitTraceBlockReason: traceBlockReason,
    waitTraceSkip: isize,
    // park: note,        //
    schedlink: ?*m, // next thread in queue
    locked_z: ?*z, // zigroutine which blocked thread
    // tls: [tlsSlots]usize, // Thread-local storage
};

//zigroutines queue, caches and more
const p = struct {
    id: i32, // unique id proc
    status: status_p, // (IDLE, RUNNING, and etc)
    m: ?*m, // thread serve
    runqhead: u32, // head queue runnable zigroutines
    runqtail: u32, // tail queue
    runq: [256]?*z, // local queue runnable zigroutines
    runnext: ?*z, // next zigroutine for running
    gFree: struct { // pool free zigroutines
        list: ?*z,
        n: i32,
    },
};

const schedt = struct {
    lock: std.Mutex, // protect access
    runq: std.PriorityQueue, // globalqueue
    midle: ?*m, // useless threads
    nmidle: i32, // count useless threads
    mnext: i64, // next id thread
    gFree: struct { // pool finish zigroutines
        list: ?*z,
        n: i32,
    },
};

extern fn stack_swap(current: **anyopaque, target: **anyopaque) void;
comptime {
    asm (stack.info.asm_t);
}
