const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../shared/types.zig");
const io_mod = @import("../../shared/io.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const result_store = @import("../../session/result_store.zig");
const session_runtime = @import("../../session/session.zig");
const compactor = @import("../../compactor/compactor.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const worker_runtime = @import("../worker_runtime.zig");
const runtime_agent = @import("agent.zig");
const runtime_config = @import("config.zig");
const runtime_deps = @import("deps.zig");
const runtime_prompt_context = @import("prompt_context.zig");
const runtime_text_completion = @import("text_completion.zig");
const orchestrator = @import("orchestrator.zig");

const Allocator = std.mem.Allocator;

pub const fallback_deadline_ms: i64 = 8_000;
const poll_interval_ns: u64 = 50 * std.time.ns_per_ms;

pub const Skip = enum {
    disabled,
    unsupported_host,
    subagent,
    cancelled,
    prompt_waiting,
    mirror_mode,
    compacted_this_turn,
    unknown_size,
    below_threshold,
    no_history,
};

pub const Decision = union(enum) {
    run,
    skip: Skip,
};

pub const Inputs = struct {
    warm_percent: u8,
    auto_percent: u8,
    request_tokens: ?usize,
    warm_at_tokens: ?usize,
    host_supported: bool,
    subagent: bool,
    cancelled: bool,
    prompt_waiting: bool,
    mirror_mode: bool,
    compacted_this_turn: bool,
    has_history: bool,
};

pub fn decide(inputs: Inputs) Decision {
    if (inputs.warm_percent == 0 or inputs.warm_percent >= inputs.auto_percent) return .{ .skip = .disabled };
    if (!inputs.host_supported) return .{ .skip = .unsupported_host };
    if (inputs.subagent) return .{ .skip = .subagent };
    if (inputs.mirror_mode) return .{ .skip = .mirror_mode };
    if (inputs.cancelled) return .{ .skip = .cancelled };
    if (inputs.prompt_waiting) return .{ .skip = .prompt_waiting };
    if (inputs.compacted_this_turn) return .{ .skip = .compacted_this_turn };
    if (!inputs.has_history) return .{ .skip = .no_history };
    const at = inputs.warm_at_tokens orelse return .{ .skip = .unknown_size };
    const request = inputs.request_tokens orelse return .{ .skip = .unknown_size };
    if (request < at) return .{ .skip = .below_threshold };
    return .run;
}

pub fn shouldAbandon(elapsed_ms: i64, deadline_ms: i64, prompt_waiting: bool, cancelled: bool) bool {
    return cancelled or (prompt_waiting and elapsed_ms >= deadline_ms);
}

const Watch = struct {
    deps: *const runtime_deps.AgentRuntimeDeps,
    parent: *std.atomic.Value(bool),
    started_ms: i64,
    deadline_ms: i64,
    abandon: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    deadline_hit: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watch) void {
        while (!self.done.load(.acquire)) {
            const waiting = if (self.deps.prompt_waiting) |probe| probe(self.deps.ctx) else false;
            const cancelled = self.parent.load(.seq_cst);
            const elapsed = io_mod.milliTimestamp() - self.started_ms;
            if (shouldAbandon(elapsed, self.deadline_ms, waiting, cancelled)) {
                if (!cancelled) self.deadline_hit.store(true, .release);
                self.abandon.store(true, .seq_cst);
                return;
            }
            io_mod.sleep(poll_interval_ns);
        }
    }
};

pub const Turn = struct {
    deps: *const runtime_deps.AgentRuntimeDeps,
    config: *const runtime_config.Config,
    job: *const worker_runtime.QueuedPrompt,
    agent: *runtime_agent.Agent,
    request: ?agent_stream_provider.RequestData = null,
    cost: ?runtime_prompt_context.RequestCost = null,
    capabilities: model_capabilities.Capabilities = .{},
    api_key: []const u8 = "",
    model: []const u8 = "",

    pub fn capture(
        self: *Turn,
        request: agent_stream_provider.RequestData,
        cost: ?runtime_prompt_context.RequestCost,
        capabilities: model_capabilities.Capabilities,
        api_key: []const u8,
        model: []const u8,
    ) void {
        self.request = request;
        self.cost = cost;
        self.capabilities = capabilities;
        self.api_key = api_key;
        self.model = model;
    }

    pub fn run(
        self: *Turn,
        arena: Allocator,
        reply: types.ChatMessage,
        history: []const types.HistoryTurn,
        compacted_this_turn: bool,
        trace_ctx: debug_trace.TraceContext,
    ) void {
        self.runChecked(arena, reply, history, compacted_this_turn, trace_ctx) catch |err| {
            compactor.traceFailure(trace_ctx, .warm_decision, "result=failed err={s}", .{@errorName(err)});
        };
    }

    fn requestTokens(self: *const Turn) ?usize {
        const cost = self.cost orelse return null;
        if (self.agent.request_token_calibration) |*calibration| {
            if (std.mem.eql(u8, calibration.modelSlice(), self.model) and calibration.cost.applies(cost)) {
                return runtime_prompt_context.calibrateProviderRequest(cost, calibration.cost).estimated_input_tokens;
            }
        }
        return cost.estimated_input_tokens;
    }

    fn runChecked(
        self: *Turn,
        arena: Allocator,
        reply: types.ChatMessage,
        history: []const types.HistoryTurn,
        compacted_this_turn: bool,
        trace_ctx: debug_trace.TraceContext,
    ) !void {
        if (comptime builtin.target.cpu.arch.isWasm()) return;
        const config = self.config;
        const deps = self.deps;
        const sent = self.request orelse return;
        const request_tokens = self.requestTokens();
        const warm_size = compactor.Size.of(self.capabilities, @max(config.auto_compact_warm_percent, 10));
        const decision = decide(.{
            .warm_percent = config.auto_compact_warm_percent,
            .auto_percent = config.auto_compact_percent,
            .request_tokens = request_tokens,
            .warm_at_tokens = warm_size.compact_at_tokens,
            .host_supported = !builtin.target.cpu.arch.isWasm() and deps.prompt_waiting != null and deps.compaction_activity != null,
            .subagent = config.origin == .subagent or config.subagent_id != 0,
            .cancelled = config.cancel_flag.load(.seq_cst),
            .prompt_waiting = if (deps.prompt_waiting) |probe| probe(deps.ctx) else false,
            .mirror_mode = false,
            .compacted_this_turn = compacted_this_turn,
            .has_history = history.len > 0,
        });
        switch (decision) {
            .skip => |reason| {
                compactor.traceEventIf(
                    reason == .below_threshold or reason == .prompt_waiting,
                    trace_ctx,
                    .warm_decision,
                    "decision=skip reason={s} tokens={any} warm_at_tokens={any} warm_percent={d}",
                    .{ @tagName(reason), request_tokens, warm_size.compact_at_tokens, config.auto_compact_warm_percent },
                );
                return;
            },
            .run => {},
        }
        compactor.traceEvent(
            trace_ctx,
            .warm_decision,
            "decision=run tokens={any} warm_at_tokens={any} warm_percent={d}",
            .{ request_tokens, warm_size.compact_at_tokens, config.auto_compact_warm_percent },
        );

        const messages = try arena.alloc(types.ChatMessage, sent.messages.len + 1);
        @memcpy(messages[0..sent.messages.len], sent.messages);
        messages[sent.messages.len] = reply;
        var conversation = sent;
        conversation.messages = messages;

        var size = orchestrator.compactionSize(self.agent, self.capabilities, config.auto_compact_percent, self.model);
        size.request_tokens = request_tokens;

        var watch: Watch = .{
            .deps = deps,
            .parent = config.cancel_flag,
            .started_ms = io_mod.milliTimestamp(),
            .deadline_ms = fallback_deadline_ms,
        };
        const watcher = std.Thread.spawn(.{}, Watch.run, .{&watch}) catch return error.WarmWatchUnavailable;
        defer {
            watch.done.store(true, .release);
            watcher.join();
        }

        const job = self.job;
        var summary_model: runtime_text_completion.CompactorCaller = .{
            .stream_provider = deps.agent_stream_provider,
            .cooperative_transport_pulse = deps.cooperative_transport_pulse,
            .provider = job.provider,
            .model = self.model,
            .api_key = self.api_key,
            .credential_source = job.credential_source,
            .account_id = job.account_id,
            .gateway_team = job.gateway_team,
            .session_id = sent.session_id,
            .retry_count = config.gateway_retry_count,
            .provider_options = sent.provider_options,
            .max_output_tokens = sent.max_output_tokens,
            .capabilities_context = deps.ctx,
            .capabilities_fn = deps.available_model_capabilities,
            .usage = deps.usage,
            .usage_allocator = deps.usage_allocator,
            .conversation = conversation,
        };
        const started_ms = watch.started_ms;
        const result = orchestrator.compactContext(arena, deps, .{
            .activity_origin = .warm,
            .compactor = .{
                .history = history,
                .append_messages = session_runtime.appendHistoryChatMessages,
                .size = size,
                .caller = summary_model.caller(),
                .records = if (config.session_child_capability) |capability| result_store.compactorStore(capability) else null,
                .cancel_flag = &watch.abandon,
                .trace_ctx = trace_ctx,
            },
        }) catch |err| {
            if (err == error.Cancelled) {
                compactor.traceEvent(trace_ctx, .warm_decision, "result=cancelled reason={s} elapsed_ms={d}", .{
                    if (watch.deadline_hit.load(.acquire)) "prompt_waiting_deadline" else "cancelled",
                    io_mod.milliTimestamp() - started_ms,
                });
                return;
            }
            return err;
        };
        if (result) |outcome| {
            self.agent.request_token_calibration = null;
            compactor.traceEvent(
                trace_ctx,
                .warm_committed,
                "removed_turns={d} compaction_count={d} summary_bytes={d} elapsed_ms={d}",
                .{ outcome.cut.turns, outcome.checkpoint.compaction_count, outcome.model_text.len, io_mod.milliTimestamp() - started_ms },
            );
        }
    }
};

fn baseInputs() Inputs {
    return .{
        .warm_percent = 60,
        .auto_percent = 80,
        .request_tokens = 70_000,
        .warm_at_tokens = 60_000,
        .host_supported = true,
        .subagent = false,
        .cancelled = false,
        .prompt_waiting = false,
        .mirror_mode = false,
        .compacted_this_turn = false,
        .has_history = true,
    };
}

test "warm compaction runs once a finished turn reaches the warm threshold" {
    try std.testing.expectEqual(Decision.run, decide(baseInputs()));
    var at = baseInputs();
    at.request_tokens = 60_000;
    try std.testing.expectEqual(Decision.run, decide(at));
    var below = baseInputs();
    below.request_tokens = 59_999;
    try std.testing.expectEqual(Decision{ .skip = .below_threshold }, decide(below));
}

test "warm compaction is off at zero and when it does not sit below the automatic percent" {
    var off = baseInputs();
    off.warm_percent = 0;
    try std.testing.expectEqual(Decision{ .skip = .disabled }, decide(off));
    var equal = baseInputs();
    equal.warm_percent = 80;
    try std.testing.expectEqual(Decision{ .skip = .disabled }, decide(equal));
    var above = baseInputs();
    above.warm_percent = 90;
    try std.testing.expectEqual(Decision{ .skip = .disabled }, decide(above));
}

test "warm compaction skips every condition that would race or repeat work" {
    const Case = struct { field: []const u8, expected: Skip };
    inline for ([_]Case{
        .{ .field = "host_supported", .expected = .unsupported_host },
        .{ .field = "subagent", .expected = .subagent },
        .{ .field = "cancelled", .expected = .cancelled },
        .{ .field = "prompt_waiting", .expected = .prompt_waiting },
        .{ .field = "mirror_mode", .expected = .mirror_mode },
        .{ .field = "compacted_this_turn", .expected = .compacted_this_turn },
        .{ .field = "has_history", .expected = .no_history },
    }) |case| {
        var inputs = baseInputs();
        @field(inputs, case.field) = !@field(inputs, case.field);
        try std.testing.expectEqual(Decision{ .skip = case.expected }, decide(inputs));
    }
    var unknown_window = baseInputs();
    unknown_window.warm_at_tokens = null;
    try std.testing.expectEqual(Decision{ .skip = .unknown_size }, decide(unknown_window));
    var unknown_request = baseInputs();
    unknown_request.request_tokens = null;
    try std.testing.expectEqual(Decision{ .skip = .unknown_size }, decide(unknown_request));
}

test "a waiting prompt abandons warm compaction only after the deadline" {
    try std.testing.expect(!shouldAbandon(0, fallback_deadline_ms, false, false));
    try std.testing.expect(!shouldAbandon(fallback_deadline_ms * 10, fallback_deadline_ms, false, false));
    try std.testing.expect(!shouldAbandon(fallback_deadline_ms - 1, fallback_deadline_ms, true, false));
    try std.testing.expect(shouldAbandon(fallback_deadline_ms, fallback_deadline_ms, true, false));
    try std.testing.expect(shouldAbandon(0, fallback_deadline_ms, false, true));
}
