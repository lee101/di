const std = @import("std");

const Allocator = std.mem.Allocator;

/// Longest accepted task content. Task text is a short human phrase echoed in
/// every rendered summary line, so a few hundred bytes covers any real item
/// while keeping one tool result bounded.
pub const max_task_content_bytes: usize = 200;
/// Longest accepted phase name. Shorter than task content because a phase is a
/// short noun phrase rendered as a list header.
pub const max_phase_name_bytes: usize = 80;
/// Longest accepted blocker note. A note rides on one rendered checklist line,
/// so it stays a single short line.
pub const max_blocker_bytes: usize = 200;
/// Most phases one list may hold. Phases are section headers, not a data store.
pub const max_phases: usize = 32;
/// Most tasks across every phase. Bounds the total rendered size of one call.
pub const max_tasks: usize = 256;

/// Phase name for `init` given a flat `items` list with no explicit `phase`.
const default_init_phase = "Tasks";

pub const Operation = enum {
    init,
    start,
    done,
    rm,
    drop,
    block,
    unblock,
    append,
    view,

    pub fn parse(text: []const u8) ?Operation {
        for (operation_names, 0..) |name, index| {
            if (std.mem.eql(u8, name, text)) return @enumFromInt(index);
        }
        return null;
    }
};

pub const operation_names = deriveNames(Operation);

const Status = enum {
    pending,
    in_progress,
    completed,
    abandoned,
    blocked,
};

/// Model-facing spelling of every status. The renderer prints the tag name
/// directly, so this is the vocabulary a task list is written back in.
const status_names = [_][]const u8{
    @tagName(Status.pending),
    @tagName(Status.in_progress),
    @tagName(Status.completed),
    @tagName(Status.abandoned),
    @tagName(Status.blocked),
};

fn deriveNames(comptime E: type) [std.meta.fields(E).len][]const u8 {
    var names: [std.meta.fields(E).len][]const u8 = undefined;
    for (std.meta.fields(E), 0..) |field, index| names[index] = field.name;
    return names;
}

const Task = struct {
    content: []u8,
    status: Status = .pending,
    /// Set only while `status` is `.blocked`: what the task waits for.
    blocker: ?[]u8 = null,
};

const Phase = struct {
    name: []u8,
    tasks: std.ArrayList(Task) = .empty,
};

/// One borrowed `init` list entry: a phase name and the task contents that
/// open in it.
pub const InitEntry = struct {
    phase: []const u8,
    items: []const []const u8,
};

/// One decoded todo call. Every field borrows the decoded arguments. A null `op`
/// asks for inference from the remaining fields.
pub const Request = struct {
    op: ?Operation = null,
    list: ?[]const InitEntry = null,
    task: ?[]const u8 = null,
    phase: ?[]const u8 = null,
    items: ?[]const []const u8 = null,
    reason: ?[]const u8 = null,
};

/// Result of applying one request: the next list, the operation that produced
/// it, and any validation errors. A request that produced errors is never
/// committed by the caller.
const Outcome = struct {
    op: Operation,
    next: List,
    errors: []const []const u8,

    fn ok(self: Outcome) bool {
        return self.errors.len == 0;
    }
};

const TaskIndex = struct { phase: usize, task: usize };

/// The phases of one todo list. No phases means no list has been created yet.
const List = struct {
    phases: std.ArrayList(Phase) = .empty,

    fn deinit(self: *List, alloc: Allocator) void {
        for (self.phases.items) |*phase| deinitPhase(alloc, phase);
        self.phases.deinit(alloc);
        self.* = .{};
    }

    fn taskCount(self: List) usize {
        var total: usize = 0;
        for (self.phases.items) |phase| total += phase.tasks.items.len;
        return total;
    }

    fn findTask(self: List, content: []const u8) ?TaskIndex {
        for (self.phases.items, 0..) |phase, phase_index| {
            for (phase.tasks.items, 0..) |task, task_index| {
                if (std.mem.eql(u8, task.content, content)) {
                    return .{ .phase = phase_index, .task = task_index };
                }
            }
        }
        return null;
    }

    fn findPhase(self: List, name: []const u8) ?usize {
        for (self.phases.items, 0..) |phase, index| {
            if (std.mem.eql(u8, phase.name, name)) return index;
        }
        return null;
    }
};

fn deinitPhase(alloc: Allocator, phase: *Phase) void {
    for (phase.tasks.items) |task| deinitTask(alloc, task);
    phase.tasks.deinit(alloc);
    alloc.free(phase.name);
    phase.* = undefined;
}

fn deinitTask(alloc: Allocator, task: Task) void {
    if (task.blocker) |blocker| alloc.free(blocker);
    alloc.free(task.content);
}

fn cloneList(alloc: Allocator, source: List) !List {
    var copy: List = .{};
    errdefer copy.deinit(alloc);
    try copy.phases.ensureTotalCapacity(alloc, source.phases.items.len);
    for (source.phases.items) |phase| {
        try copy.phases.append(alloc, .{
            .name = try alloc.dupe(u8, phase.name),
            .tasks = try cloneTasks(alloc, phase.tasks.items),
        });
    }
    return copy;
}

fn cloneTasks(alloc: Allocator, source: []const Task) !std.ArrayList(Task) {
    var tasks: std.ArrayList(Task) = .empty;
    errdefer deinitTasks(alloc, &tasks);
    try tasks.ensureTotalCapacity(alloc, source.len);
    for (source) |task| {
        try tasks.append(alloc, .{
            .content = try alloc.dupe(u8, task.content),
            .status = task.status,
            .blocker = if (task.blocker) |blocker| try alloc.dupe(u8, blocker) else null,
        });
    }
    return tasks;
}

fn deinitTasks(alloc: Allocator, tasks: *std.ArrayList(Task)) void {
    for (tasks.items) |task| deinitTask(alloc, task);
    tasks.deinit(alloc);
}

/// Releases the tasks but leaves a usable empty list, which is what removing a
/// task or clearing a phase means. `deinit` would poison the list instead.
fn clearTasks(alloc: Allocator, tasks: *std.ArrayList(Task)) void {
    for (tasks.items) |task| deinitTask(alloc, task);
    tasks.clearRetainingCapacity();
}

/// Infers a missing `op` from the argument shape. Only unambiguous shapes are
/// inferred:
/// - a non-empty `list` means `init` (list is init-only)
/// - non-empty `items` with a non-empty `phase` means `append` (append lazily
///   creates the phase, so an empty list still ends up with one phase)
/// - non-empty `items` with no existing list means `init` (there is nothing to
///   overwrite, and nothing to append to)
/// Targeting arguments alone map to several operations and stay an error.
fn inferOperation(
    list: ?[]const InitEntry,
    items: ?[]const []const u8,
    phase: ?[]const u8,
    has_existing_phases: bool,
) ?Operation {
    if (list) |entries| {
        if (entries.len > 0) return .init;
    }
    if (items) |values| {
        if (values.len > 0) {
            if (phase) |name| {
                if (name.len > 0) return .append;
            }
            if (!has_existing_phases) return .init;
        }
    }
    return null;
}

/// Applies one request to a deep copy of `current`, resolving an omitted `op`
/// against the list as it stands. Returns null when the arguments name no
/// single operation. The caller commits `next` only when it carries no errors,
/// so a rejected request leaves the previous list exactly as it was, and owns
/// the returned `next` and `errors`.
fn applyOperation(alloc: Allocator, current: List, request: Request) !?Outcome {
    const op = request.op orelse
        (inferOperation(request.list, request.items, request.phase, current.phases.items.len > 0) orelse return null);
    var next = try cloneList(alloc, current);
    errdefer next.deinit(alloc);

    var errors: std.ArrayList([]const u8) = .empty;
    defer {
        for (errors.items) |message| alloc.free(message);
        errors.deinit(alloc);
    }
    try applyRequest(alloc, &next, op, request, &errors);
    normalizeInProgress(&next);
    return .{ .op = op, .next = next, .errors = try errors.toOwnedSlice(alloc) };
}

fn applyRequest(
    alloc: Allocator,
    list: *List,
    op: Operation,
    request: Request,
    errors: *std.ArrayList([]const u8),
) !void {
    switch (op) {
        .init => try initPhases(alloc, list, request, errors),
        .start => try startTask(alloc, list, request, errors),
        .done => try setTargets(alloc, list, request, errors, .completed),
        .drop => try setTargets(alloc, list, request, errors, .abandoned),
        .block => try blockTargets(alloc, list, request, errors),
        .unblock => try unblockTargets(alloc, list, request, errors),
        .rm => try removeTasks(alloc, list, request, errors),
        .append => try appendItems(alloc, list, request, errors),
        .view => {},
    }
}

fn appendError(
    alloc: Allocator,
    errors: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try errors.append(alloc, try std.fmt.allocPrint(alloc, fmt, args));
}

fn initPhases(
    alloc: Allocator,
    list: *List,
    request: Request,
    errors: *std.ArrayList([]const u8),
) !void {
    // Models routinely flatten a single-phase init into `{op:"init", items:[...]}`
    // with an optional bare `phase`. Accept that shape by synthesizing a
    // one-phase list so a common, recoverable mistake is not a hard error.
    var synthesized: [1]InitEntry = undefined;
    const entries: []const InitEntry = if (request.list) |provided| provided else blk: {
        const items = request.items orelse &.{};
        if (items.len == 0) {
            try appendError(alloc, errors, "Missing list for init operation", .{});
            return;
        }
        synthesized[0] = .{ .phase = request.phase orelse default_init_phase, .items = items };
        break :blk synthesized[0..];
    };

    // Duplicate phase names and task contents would be permanently
    // unaddressable, because every targeting operation resolves the first match.
    if (!try validateEntries(alloc, entries, errors)) return;

    var replacement: List = .{};
    errdefer replacement.deinit(alloc);
    for (entries) |entry| {
        try replacement.phases.append(alloc, .{
            .name = try alloc.dupe(u8, entry.phase),
            .tasks = try copyTasks(alloc, entry.items),
        });
    }
    list.deinit(alloc);
    list.* = replacement;
}

fn copyTasks(alloc: Allocator, contents: []const []const u8) !std.ArrayList(Task) {
    var tasks: std.ArrayList(Task) = .empty;
    errdefer deinitTasks(alloc, &tasks);
    try tasks.ensureTotalCapacity(alloc, contents.len);
    for (contents) |content| {
        try tasks.append(alloc, .{ .content = try alloc.dupe(u8, content) });
    }
    return tasks;
}

/// Reports every bound and duplicate violation in an `init` list. Returns true
/// when the list is well formed.
fn validateEntries(
    alloc: Allocator,
    entries: []const InitEntry,
    errors: *std.ArrayList([]const u8),
) !bool {
    if (entries.len > max_phases) {
        try appendError(alloc, errors, "Init list holds {d} phases, at most {d} are allowed", .{ entries.len, max_phases });
    }
    var total: usize = 0;
    for (entries) |entry| {
        if (entry.phase.len == 0) {
            try appendError(alloc, errors, "Phase name must not be empty", .{});
        } else if (entry.phase.len > max_phase_name_bytes) {
            try appendError(alloc, errors, "Phase \"{s}\" is {d} bytes, at most {d} are allowed", .{ entry.phase, entry.phase.len, max_phase_name_bytes });
        }
        if (entry.items.len == 0) {
            try appendError(alloc, errors, "Phase \"{s}\" has no tasks", .{entry.phase});
        }
        for (entry.items) |content| {
            total += 1;
            if (content.len > max_task_content_bytes) {
                try appendError(alloc, errors, "Task content is {d} bytes, at most {d} are allowed", .{ content.len, max_task_content_bytes });
            }
        }
    }
    if (total > max_tasks) {
        try appendError(alloc, errors, "Init list holds {d} tasks, at most {d} are allowed", .{ total, max_tasks });
    }
    for (entries, 0..) |entry, index| {
        for (entries[index + 1 ..]) |other| {
            if (!std.mem.eql(u8, entry.phase, other.phase)) continue;
            try appendError(alloc, errors, "Duplicate phase \"{s}\" in init list", .{entry.phase});
            break;
        }
    }
    for (entries, 0..) |entry, entry_index| {
        for (entry.items, 0..) |content, item_index| {
            var repeated = false;
            for (entry.items[0..item_index]) |earlier| {
                if (std.mem.eql(u8, earlier, content)) repeated = true;
            }
            for (entries[entry_index + 1 ..]) |other| {
                if (containsContent(other.items, content)) repeated = true;
            }
            if (repeated) try appendError(alloc, errors, "Duplicate task \"{s}\" in init list", .{content});
        }
    }
    return errors.items.len == 0;
}

fn containsContent(items: []const []const u8, content: []const u8) bool {
    for (items) |candidate| {
        if (std.mem.eql(u8, candidate, content)) return true;
    }
    return false;
}

fn startTask(
    alloc: Allocator,
    list: *List,
    request: Request,
    errors: *std.ArrayList([]const u8),
) !void {
    const index = (try resolveTask(alloc, list, request.task, errors)) orelse return;
    for (list.phases.items, 0..) |*phase, phase_index| {
        for (phase.tasks.items, 0..) |*candidate, task_index| {
            const is_target = phase_index == index.phase and task_index == index.task;
            if (!is_target and candidate.status == .in_progress) candidate.status = .pending;
        }
    }
    list.phases.items[index.phase].tasks.items[index.task].status = .in_progress;
}

fn setTargets(
    alloc: Allocator,
    list: *List,
    request: Request,
    errors: *std.ArrayList([]const u8),
    status: Status,
) !void {
    const targets = try collectTargets(alloc, list, request, errors);
    defer alloc.free(targets);
    for (targets) |target| {
        list.phases.items[target.phase].tasks.items[target.task].status = status;
    }
}

fn blockTargets(
    alloc: Allocator,
    list: *List,
    request: Request,
    errors: *std.ArrayList([]const u8),
) !void {
    if (request.task == null and request.phase == null) {
        try appendError(alloc, errors, "block requires a task or phase target", .{});
        return;
    }
    // A blocker note rides on one rendered checklist line, so collapse
    // whitespace runs (including newlines from a pasted external error) to
    // single spaces and keep every consumer one-line safe.
    const reason = request.reason orelse "";
    if (reason.len > max_blocker_bytes) {
        try appendError(alloc, errors, "Blocker reason is {d} bytes, at most {d} are allowed", .{ reason.len, max_blocker_bytes });
        return;
    }
    const normalized = try collapseSpaces(alloc, reason);
    defer alloc.free(normalized);

    const targets = try collectTargets(alloc, list, request, errors);
    defer alloc.free(targets);
    for (targets) |target| {
        const task = &list.phases.items[target.phase].tasks.items[target.task];
        // Only actionable open work can be blocked: blocking a phase must not
        // reopen settled tasks or erase finished progress. An already blocked
        // task stays eligible so a later block can refine its note.
        if (task.status != .pending and task.status != .in_progress and task.status != .blocked) continue;
        task.status = .blocked;
        try setBlocker(alloc, task, if (normalized.len == 0) null else normalized);
    }
}

fn unblockTargets(
    alloc: Allocator,
    list: *List,
    request: Request,
    errors: *std.ArrayList([]const u8),
) !void {
    if (request.task == null and request.phase == null) {
        try appendError(alloc, errors, "unblock requires a task or phase target", .{});
        return;
    }
    const targets = try collectTargets(alloc, list, request, errors);
    defer alloc.free(targets);
    for (targets) |target| {
        const task = &list.phases.items[target.phase].tasks.items[target.task];
        if (task.status != .blocked) continue;
        task.status = .pending;
        try setBlocker(alloc, task, null);
    }
}

fn setBlocker(alloc: Allocator, task: *Task, reason: ?[]const u8) !void {
    if (task.blocker) |existing| alloc.free(existing);
    task.blocker = if (reason) |text| try alloc.dupe(u8, text) else null;
}

fn collapseSpaces(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pending_space = false;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = out.items.len > 0;
            continue;
        }
        if (pending_space) {
            try out.append(alloc, ' ');
            pending_space = false;
        }
        try out.append(alloc, byte);
    }
    return out.toOwnedSlice(alloc);
}

fn removeTasks(
    alloc: Allocator,
    list: *List,
    request: Request,
    errors: *std.ArrayList([]const u8),
) !void {
    if (request.task != null) {
        const index = (try resolveTask(alloc, list, request.task, errors)) orelse return;
        const removed = list.phases.items[index.phase].tasks.orderedRemove(index.task);
        deinitTask(alloc, removed);
        return;
    }
    if (request.phase != null) {
        const index = (try resolvePhase(alloc, list, request.phase, errors)) orelse return;
        clearTasks(alloc, &list.phases.items[index].tasks);
        return;
    }
    for (list.phases.items) |*phase| clearTasks(alloc, &phase.tasks);
}

fn appendItems(
    alloc: Allocator,
    list: *List,
    request: Request,
    errors: *std.ArrayList([]const u8),
) !void {
    if (isBlank(request.phase)) {
        try appendError(alloc, errors, "Missing phase name for append operation", .{});
        return;
    }
    const name = request.phase.?;
    const items = request.items orelse &.{};
    if (items.len == 0) {
        try appendError(alloc, errors, "Missing items for append operation", .{});
        return;
    }
    if (name.len > max_phase_name_bytes) {
        try appendError(alloc, errors, "Phase \"{s}\" is {d} bytes, at most {d} are allowed", .{ name, name.len, max_phase_name_bytes });
    }

    // Validate the whole batch before mutating, so a failing request reports
    // every duplicate and leaves nothing half applied.
    for (items, 0..) |content, index| {
        if (content.len > max_task_content_bytes) {
            try appendError(alloc, errors, "Task content is {d} bytes, at most {d} are allowed", .{ content.len, max_task_content_bytes });
            continue;
        }
        var repeated = list.findTask(content) != null;
        for (items[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, content)) repeated = true;
        }
        if (repeated) try appendError(alloc, errors, "Task \"{s}\" already exists", .{content});
    }
    if (list.findPhase(name) == null and list.phases.items.len + 1 > max_phases) {
        try appendError(alloc, errors, "Todo list would hold {d} phases, at most {d} are allowed", .{ list.phases.items.len + 1, max_phases });
    }
    if (list.taskCount() + items.len > max_tasks) {
        try appendError(alloc, errors, "Todo list would hold {d} tasks, at most {d} are allowed", .{ list.taskCount() + items.len, max_tasks });
    }
    if (errors.items.len > 0) return;

    const phase_index = list.findPhase(name) orelse blk: {
        try list.phases.append(alloc, .{ .name = try alloc.dupe(u8, name) });
        break :blk list.phases.items.len - 1;
    };
    const phase = &list.phases.items[phase_index];
    for (items) |content| {
        try phase.tasks.append(alloc, .{ .content = try alloc.dupe(u8, content) });
    }
}

fn collectTargets(
    alloc: Allocator,
    list: *const List,
    request: Request,
    errors: *std.ArrayList([]const u8),
) ![]TaskIndex {
    if (request.task != null) {
        const index = try resolveTask(alloc, list, request.task, errors);
        if (index == null) return alloc.alloc(TaskIndex, 0);
        const owned = try alloc.alloc(TaskIndex, 1);
        owned[0] = index.?;
        return owned;
    }
    if (request.phase != null) {
        const index = try resolvePhase(alloc, list, request.phase, errors);
        if (index == null) return alloc.alloc(TaskIndex, 0);
        const tasks = list.phases.items[index.?].tasks.items.len;
        const owned = try alloc.alloc(TaskIndex, tasks);
        for (owned, 0..) |*target, task_index| {
            target.* = .{ .phase = index.?, .task = task_index };
        }
        return owned;
    }
    const owned = try alloc.alloc(TaskIndex, list.taskCount());
    var written: usize = 0;
    for (list.phases.items, 0..) |phase, phase_index| {
        for (phase.tasks.items, 0..) |_, task_index| {
            owned[written] = .{ .phase = phase_index, .task = task_index };
            written += 1;
        }
    }
    return owned;
}

fn resolveTask(
    alloc: Allocator,
    list: *const List,
    content: ?[]const u8,
    errors: *std.ArrayList([]const u8),
) !?TaskIndex {
    if (isBlank(content)) {
        try appendError(alloc, errors, "Missing task content", .{});
        return null;
    }
    if (list.findTask(content.?)) |found| return found;
    if (looksLikeGeneratedId(content.?)) {
        try appendError(alloc, errors, "Task \"{s}\" not found. Tasks are referenced by content, not by IDs — pass the task's full text from the previous result.", .{content.?});
    } else if (list.taskCount() == 0) {
        try appendError(alloc, errors, "Task \"{s}\" not found (todo list is empty — was it replaced or not yet created?)", .{content.?});
    } else {
        try appendError(alloc, errors, "Task \"{s}\" not found", .{content.?});
    }
    return null;
}

fn resolvePhase(
    alloc: Allocator,
    list: *const List,
    name: ?[]const u8,
    errors: *std.ArrayList([]const u8),
) !?usize {
    if (isBlank(name)) {
        try appendError(alloc, errors, "Missing phase name", .{});
        return null;
    }
    const found = list.findPhase(name.?);
    if (found == null) try appendError(alloc, errors, "Phase \"{s}\" not found", .{name.?});
    return found;
}

fn isBlank(text: ?[]const u8) bool {
    const value = text orelse return true;
    return value.len == 0;
}

/// Matches the synthetic `task-N` identifiers a model reaches for instead of
/// echoing the real content text.
fn looksLikeGeneratedId(content: []const u8) bool {
    const prefix = "task-";
    if (!std.mem.startsWith(u8, content, prefix)) return false;
    const digits = content[prefix.len..];
    if (digits.len == 0) return false;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

/// Enforces the single in-progress invariant: with several in progress only the
/// first survives, and with none the earliest pending task auto-promotes. This
/// runs after every mutating operation so the pointer auto-advances on
/// completion and can move back when work finished out of order.
fn normalizeInProgress(list: *List) void {
    var in_progress: usize = 0;
    for (list.phases.items) |*phase| {
        for (phase.tasks.items) |*task| {
            if (task.status != .in_progress) continue;
            in_progress += 1;
            if (in_progress > 1) task.status = .pending;
        }
    }
    if (in_progress > 0) return;
    for (list.phases.items) |*phase| {
        for (phase.tasks.items) |*task| {
            if (task.status != .pending) continue;
            task.status = .in_progress;
            return;
        }
    }
}

/// Renders the one summary every todo call returns: the error line when there
/// is one, the open items, the overall counters, the active phase, and every
/// phase's full checklist. The caller owns the returned text.
fn formatSummary(
    alloc: Allocator,
    list: List,
    errors: []const []const u8,
    read_only: bool,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    renderSummary(&out.writer, list, errors, read_only) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

fn renderSummary(
    writer: *std.Io.Writer,
    list: List,
    errors: []const []const u8,
    read_only: bool,
) !void {
    const total = list.taskCount();
    if (total == 0) {
        if (errors.len > 0) {
            try writeErrorLine(writer, errors);
            return;
        }
        try writer.writeAll(if (read_only) "Todo list is empty." else "Todo list cleared.");
        return;
    }

    var open: usize = 0;
    var closed: usize = 0;
    var blocked: usize = 0;
    for (list.phases.items) |phase| {
        for (phase.tasks.items) |task| {
            switch (task.status) {
                .pending, .in_progress => open += 1,
                .completed, .abandoned => closed += 1,
                .blocked => blocked += 1,
            }
        }
    }

    // The active phase is the earliest one still holding open work, so the
    // in-progress pointer can sit in a phase whose successors already hold
    // closed tasks. Detect that worked-ahead case to explain the otherwise
    // surprising backward pointer.
    var current_index: usize = 0;
    var found_current = false;
    for (list.phases.items, 0..) |phase, index| {
        if (!phaseHasOpenWork(phase)) continue;
        current_index = index;
        found_current = true;
        break;
    }
    if (!found_current) current_index = list.phases.items.len - 1;
    const current = list.phases.items[current_index];
    const worked_ahead = blk: {
        for (list.phases.items, 0..) |phase, index| {
            if (index > current_index and phaseClosedCount(phase) > 0) break :blk true;
        }
        break :blk false;
    };

    if (errors.len > 0) {
        try writeErrorLine(writer, errors);
        try writer.writeByte('\n');
    }
    if (open == 0) {
        try writer.writeAll("Remaining items: none.");
    } else {
        try writer.print("Remaining items ({d}):", .{open});
        for (list.phases.items) |phase| {
            for (phase.tasks.items) |task| {
                if (task.status != .pending and task.status != .in_progress) continue;
                try writer.print("\n  - {s} [{s}] ({s})", .{ task.content, @tagName(task.status), phase.name });
            }
        }
    }
    try writer.print("\nOverall: {d}/{d} done, {d} open", .{ closed, total, open });
    if (blocked > 0) try writer.print(", {d} blocked", .{blocked});
    try writer.writeByte('.');
    try writer.print("\nActive phase {d}/{d} \"{s}\" ({d}/{d})", .{
        current_index + 1,
        list.phases.items.len,
        current.name,
        phaseClosedCount(current),
        current.tasks.items.len,
    });
    if (worked_ahead) {
        try writer.writeAll(" — earliest phase with open tasks; the in-progress pointer auto-advances to the earliest open task on each completion, so it can sit behind out-of-order work (nothing was un-completed).");
    } else {
        try writer.writeByte('.');
    }
    for (list.phases.items) |phase| {
        try writer.print("\n  {s}:", .{phase.name});
        for (phase.tasks.items) |task| {
            const checkbox = if (task.status == .completed) "[X]" else "[ ]";
            try writer.print("\n    - {s} {s}", .{ checkbox, task.content });
            switch (task.status) {
                .in_progress => try writer.writeAll(" (in progress)"),
                .abandoned => try writer.writeAll(" (dropped)"),
                .blocked => {
                    if (task.blocker) |blocker| {
                        try writer.print(" (blocked: {s})", .{blocker});
                    } else {
                        try writer.writeAll(" (blocked)");
                    }
                },
                .pending, .completed => {},
            }
        }
    }
}

fn writeErrorLine(writer: *std.Io.Writer, errors: []const []const u8) !void {
    try writer.writeAll("Errors: ");
    for (errors, 0..) |message, index| {
        if (index > 0) try writer.writeAll("; ");
        try writer.writeAll(message);
    }
}

fn phaseHasOpenWork(phase: Phase) bool {
    for (phase.tasks.items) |task| {
        if (task.status == .pending or task.status == .in_progress) return true;
    }
    return false;
}

fn phaseClosedCount(phase: Phase) usize {
    var closed: usize = 0;
    for (phase.tasks.items) |task| {
        if (task.status == .completed or task.status == .abandoned) closed += 1;
    }
    return closed;
}

/// Session-scoped todo state: the phase list plus the lock every read and write
/// takes. The lock lives beside the list so one call can read, resolve, mutate,
/// render, and publish without a caller holding the mutex.
pub const Session = struct {
    lock: std.Io.Mutex = .init,
    list: List = .{},

    /// Result of one applied call. `ambiguous_operation` means `op` was omitted
    /// and the remaining arguments do not name exactly one operation.
    pub const Applied = union(enum) {
        rendered: []u8,
        ambiguous_operation,
    };

    /// Applies one request and returns the rendered summary. A rejected request
    /// is discarded wholesale, so the stored list and the rendered summary stay
    /// at the previous state together.
    ///
    /// `state_alloc` owns the list and must be the allocator this session was
    /// deinitialized with; a tool call's per-call arena does not outlive the
    /// list. `result_alloc` owns the rendered text and may be that arena. The
    /// caller owns the returned bytes.
    pub fn apply(
        self: *Session,
        state_alloc: Allocator,
        result_alloc: Allocator,
        io: std.Io,
        request: Request,
    ) !Applied {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        var outcome = (try applyOperation(state_alloc, self.list, request)) orelse return .ambiguous_operation;
        const effective = if (outcome.ok()) blk: {
            self.list.deinit(state_alloc);
            self.list = outcome.next;
            break :blk self.list;
        } else blk: {
            outcome.next.deinit(state_alloc);
            break :blk self.list;
        };
        const rendered = try formatSummary(result_alloc, effective, outcome.errors, outcome.op == .view);
        for (outcome.errors) |message| state_alloc.free(message);
        state_alloc.free(outcome.errors);
        return .{ .rendered = rendered };
    }

    pub fn clear(self: *Session, alloc: Allocator, io: std.Io) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.list.deinit(alloc);
        self.list = .{};
    }

    pub fn deinit(self: *Session, alloc: Allocator, io: std.Io) void {
        self.clear(alloc, io);
    }
};

const foundation_and_verification: []const InitEntry = &.{
    .{ .phase = "Foundation", .items = &.{ "Scaffold crate", "Wire workspace" } },
    .{ .phase = "Verification", .items = &.{"Run tests"} },
};

const single_phase: []const InitEntry = &.{
    .{ .phase = "Implementation", .items = &.{ "Apply fix", "Run tests" } },
};

/// A task with an explicit status, for states the public operations cannot
/// produce, such as a list that already holds several tasks in progress.
const TaskSpec = struct { content: []const u8, status: Status };

const PhaseSpec = struct {
    phase: []const u8,
    items: []const TaskSpec,
};

/// Builds a list without running the in-progress normalizer, so a test can
/// start from a state the public operations would never leave behind.
fn listFromSpecs(alloc: Allocator, specs: []const PhaseSpec) !List {
    var list: List = .{};
    errdefer list.deinit(alloc);
    try list.phases.ensureTotalCapacity(alloc, specs.len);
    for (specs) |spec| {
        var tasks: std.ArrayList(Task) = .empty;
        errdefer deinitTasks(alloc, &tasks);
        try tasks.ensureTotalCapacity(alloc, spec.items.len);
        for (spec.items) |item| {
            try tasks.append(alloc, .{ .content = try alloc.dupe(u8, item.content), .status = item.status });
        }
        try list.phases.append(alloc, .{ .name = try alloc.dupe(u8, spec.phase), .tasks = tasks });
    }
    return list;
}

/// Runs one request against a deep copy of `current` and unwraps the outcome,
/// which fails the test when the arguments name no single operation.
fn applyTo(alloc: Allocator, current: List, request: Request) !Outcome {
    return (try applyOperation(alloc, current, request)).?;
}

/// Releases an outcome the caller no longer inspects. `List.deinit` needs a
/// mutable binding, so tests hand the outcome to this by value.
fn releaseOutcome(alloc: Allocator, outcome: Outcome) void {
    var released = outcome;
    for (released.errors) |message| alloc.free(message);
    alloc.free(released.errors);
    released.next.deinit(alloc);
}

fn expectErrors(alloc: Allocator, current: List, request: Request, expected: []const []const u8) !void {
    const outcome = try applyTo(alloc, current, request);
    defer releaseOutcome(alloc, outcome);
    try std.testing.expectEqual(expected.len, outcome.errors.len);
    for (expected, outcome.errors) |want, got| try std.testing.expectEqualStrings(want, got);
}

/// Builds a seeded list through the real `init` path.
fn seeded(alloc: Allocator, spec: []const InitEntry) !List {
    const outcome = try applyTo(alloc, .{}, .{ .op = .init, .list = spec });
    try std.testing.expect(outcome.ok());
    return outcome.next;
}

/// Applies a request that only establishes state, without pinning its text.
fn seedSession(session: *Session, request: Request) !void {
    const alloc = std.testing.allocator;
    const applied = try session.apply(alloc, alloc, std.testing.io, request);
    const rendered = switch (applied) {
        .rendered => |text| text,
        .ambiguous_operation => return error.TestExpectedEqual,
    };
    alloc.free(rendered);
}

fn expectRendered(session: *Session, request: Request, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const applied = try session.apply(alloc, alloc, std.testing.io, request);
    const rendered = switch (applied) {
        .rendered => |text| text,
        .ambiguous_operation => return error.TestExpectedEqual,
    };
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(expected, rendered);
}

fn countOpen(list: List) usize {
    var open: usize = 0;
    for (list.phases.items) |phase| {
        for (phase.tasks.items) |task| {
            if (task.status == .pending or task.status == .in_progress) open += 1;
        }
    }
    return open;
}

test "todo operation names cover every enum member and reject unknown input" {
    try std.testing.expectEqual(@as(usize, 9), operation_names.len);
    inline for (std.meta.fields(Operation), 0..) |field, index| {
        try std.testing.expectEqualStrings(field.name, operation_names[index]);
        try std.testing.expectEqual(@as(Operation, @enumFromInt(index)), Operation.parse(field.name));
    }
    try std.testing.expect(Operation.parse("complete") == null);
    try std.testing.expect(Operation.parse("") == null);
    try std.testing.expect(Operation.parse("INIT") == null);
}

test "todo status names stay the model-facing vocabulary" {
    const expected = [_][]const u8{ "pending", "in_progress", "completed", "abandoned", "blocked" };
    try std.testing.expectEqualSlices([]const u8, &expected, &status_names);
}

test "todo operation inference accepts only unambiguous payloads" {
    const items: []const []const u8 = &.{"a"};
    try std.testing.expectEqual(@as(?Operation, .init), inferOperation(foundation_and_verification, null, null, true));
    try std.testing.expectEqual(@as(?Operation, .init), inferOperation(&.{}, items, null, false));
    try std.testing.expectEqual(@as(?Operation, .append), inferOperation(null, items, "Auth", false));
    try std.testing.expectEqual(@as(?Operation, .append), inferOperation(null, items, "Auth", true));
    // An existing list plus bare items could be an append or a replacement, so
    // it stays an error.
    try std.testing.expect(inferOperation(null, items, null, true) == null);
    // Targeting arguments alone name several operations.
    try std.testing.expect(inferOperation(null, null, "Auth", false) == null);
    try std.testing.expect(inferOperation(null, &.{}, null, false) == null);
    try std.testing.expect(inferOperation(&.{}, null, "", false) == null);
    // An empty phase name carries no target, so an empty list still infers init.
    try std.testing.expectEqual(@as(?Operation, .init), inferOperation(null, items, "", false));
}

test "todo init opens one phase per list entry and starts the first task" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), list.phases.items.len);
    try std.testing.expectEqualStrings("Foundation", list.phases.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), list.phases.items[0].tasks.items.len);
    try std.testing.expectEqualStrings("Run tests", list.phases.items[1].tasks.items[0].content);
    try std.testing.expectEqual(Status.in_progress, list.phases.items[0].tasks.items[0].status);
    try std.testing.expectEqual(Status.pending, list.phases.items[0].tasks.items[1].status);
    try std.testing.expectEqual(Status.pending, list.phases.items[1].tasks.items[0].status);
}

test "todo init accepts a flattened items list under one phase" {
    const alloc = std.testing.allocator;
    const outcome = try applyTo(alloc, .{}, .{ .op = .init, .items = &.{ "Wire output", "Port callers" } });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqual(@as(usize, 1), outcome.next.phases.items.len);
    try std.testing.expectEqualStrings(default_init_phase, outcome.next.phases.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), outcome.next.phases.items[0].tasks.items.len);
    try std.testing.expectEqual(Status.in_progress, outcome.next.phases.items[0].tasks.items[0].status);
}

test "todo init uses the supplied phase name for a flattened items list" {
    const alloc = std.testing.allocator;
    const outcome = try applyTo(alloc, .{}, .{ .op = .init, .phase = "Auth", .items = &.{"Port credential store"} });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqualStrings("Auth", outcome.next.phases.items[0].name);
}

test "todo init rejects a missing list" {
    const alloc = std.testing.allocator;
    try expectErrors(alloc, .{}, .{ .op = .init }, &.{"Missing list for init operation"});
    try expectErrors(alloc, .{}, .{ .op = .init, .items = &.{} }, &.{"Missing list for init operation"});
}

test "todo init rejects duplicate phases and duplicate task content" {
    const alloc = std.testing.allocator;
    try expectErrors(alloc, .{}, .{ .op = .init, .list = &.{
        .{ .phase = "Auth", .items = &.{"Wire OAuth"} },
        .{ .phase = "Auth", .items = &.{"Port credential store"} },
    } }, &.{"Duplicate phase \"Auth\" in init list"});
    try expectErrors(alloc, .{}, .{ .op = .init, .list = &.{
        .{ .phase = "Auth", .items = &.{ "Wire OAuth", "Wire OAuth" } },
    } }, &.{"Duplicate task \"Wire OAuth\" in init list"});
    try expectErrors(alloc, .{}, .{ .op = .init, .list = &.{
        .{ .phase = "Auth", .items = &.{"Wire OAuth"} },
        .{ .phase = "Verification", .items = &.{"Wire OAuth"} },
    } }, &.{"Duplicate task \"Wire OAuth\" in init list"});
}

test "todo init rejects an empty phase name and an empty phase" {
    const alloc = std.testing.allocator;
    try expectErrors(alloc, .{}, .{ .op = .init, .list = &.{
        .{ .phase = "", .items = &.{"Wire OAuth"} },
    } }, &.{"Phase name must not be empty"});
    try expectErrors(alloc, .{}, .{ .op = .init, .list = &.{
        .{ .phase = "Auth", .items = &.{} },
    } }, &.{"Phase \"Auth\" has no tasks"});
}

test "todo init bounds phase names, task content, phase count, and task count" {
    const alloc = std.testing.allocator;
    const long_name = "p" ** (max_phase_name_bytes + 1);
    try expectErrors(alloc, .{}, .{ .op = .init, .list = &.{
        .{ .phase = long_name, .items = &.{"Wire OAuth"} },
    } }, &.{std.fmt.comptimePrint("Phase \"{s}\" is {d} bytes, at most {d} are allowed", .{ long_name, long_name.len, max_phase_name_bytes })});

    const long_content = "t" ** (max_task_content_bytes + 1);
    try expectErrors(alloc, .{}, .{ .op = .init, .list = &.{
        .{ .phase = "Auth", .items = &.{long_content} },
    } }, &.{std.fmt.comptimePrint("Task content is {d} bytes, at most {d} are allowed", .{ long_content.len, max_task_content_bytes })});

    const too_many_phases = try alloc.alloc(InitEntry, max_phases + 1);
    defer alloc.free(too_many_phases);
    const names = try alloc.alloc([]u8, 2 * (max_phases + 1));
    defer {
        for (names) |name| alloc.free(name);
        alloc.free(names);
    }
    for (too_many_phases, 0..) |*entry, index| {
        names[2 * index] = try std.fmt.allocPrint(alloc, "Phase {d}", .{index});
        names[2 * index + 1] = try std.fmt.allocPrint(alloc, "Wire OAuth {d}", .{index});
        entry.* = .{ .phase = names[2 * index], .items = names[2 * index + 1 .. 2 * index + 2] };
    }
    try expectErrors(alloc, .{}, .{ .op = .init, .list = too_many_phases }, &.{
        std.fmt.comptimePrint("Init list holds {d} phases, at most {d} are allowed", .{ max_phases + 1, max_phases }),
    });

    const overflow: [max_tasks + 1][]const u8 = blk: {
        var items: [max_tasks + 1][]const u8 = undefined;
        inline for (&items, 0..) |*item, index| item.* = std.fmt.comptimePrint("Wire OAuth {d}", .{index});
        break :blk items;
    };
    try expectErrors(alloc, .{}, .{ .op = .init, .list = &.{
        .{ .phase = "Auth", .items = &overflow },
    } }, &.{std.fmt.comptimePrint("Init list holds {d} tasks, at most {d} are allowed", .{ max_tasks + 1, max_tasks })});
}

test "todo start moves the in-progress pointer and demotes the previous task" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .start, .task = "Wire workspace" });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqual(Status.pending, outcome.next.phases.items[0].tasks.items[0].status);
    try std.testing.expectEqual(Status.in_progress, outcome.next.phases.items[0].tasks.items[1].status);
}

test "todo start reports an unknown task" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    try expectErrors(alloc, list, .{ .op = .start, .task = "Wire oauth" }, &.{"Task \"Wire oauth\" not found"});
    try expectErrors(alloc, list, .{ .op = .start }, &.{"Missing task content"});
}

test "todo done closes one task, a whole phase, or everything" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);

    const one = try applyTo(alloc, list, .{ .op = .done, .task = "Wire workspace" });
    defer releaseOutcome(alloc, one);
    try std.testing.expectEqual(Status.completed, one.next.phases.items[0].tasks.items[1].status);
    try std.testing.expectEqual(Status.pending, one.next.phases.items[1].tasks.items[0].status);

    const phase = try applyTo(alloc, one.next, .{ .op = .done, .phase = "Foundation" });
    defer releaseOutcome(alloc, phase);
    try std.testing.expectEqual(Status.completed, phase.next.phases.items[0].tasks.items[0].status);
    try std.testing.expectEqual(Status.completed, phase.next.phases.items[0].tasks.items[1].status);
    // Auto-advance promotes the earliest still-open task across phases.
    try std.testing.expectEqual(Status.in_progress, phase.next.phases.items[1].tasks.items[0].status);

    const all = try applyTo(alloc, phase.next, .{ .op = .done });
    defer releaseOutcome(alloc, all);
    try std.testing.expectEqual(@as(usize, 0), countOpen(all.next));
}

test "todo done reports an unknown task or phase" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    try expectErrors(alloc, list, .{ .op = .done, .task = "task-2" }, &.{
        "Task \"task-2\" not found. Tasks are referenced by content, not by IDs — pass the task's full text from the previous result.",
    });
    try expectErrors(alloc, list, .{ .op = .done, .task = "Wire oauth" }, &.{"Task \"Wire oauth\" not found"});
    try expectErrors(alloc, list, .{ .op = .done, .task = "" }, &.{"Missing task content"});
    try expectErrors(alloc, list, .{ .op = .start, .task = "" }, &.{"Missing task content"});
    try expectErrors(alloc, list, .{ .op = .done, .phase = "Nope" }, &.{"Phase \"Nope\" not found"});
    try expectErrors(alloc, list, .{ .op = .done, .phase = "" }, &.{"Missing phase name"});
}

test "todo done without a target closes every open task" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .done });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expectEqual(@as(usize, 0), countOpen(outcome.next));
}

test "todo reports an unknown task against an empty list" {
    const alloc = std.testing.allocator;
    try expectErrors(alloc, .{}, .{ .op = .done, .task = "Run tests" }, &.{
        "Task \"Run tests\" not found (todo list is empty — was it replaced or not yet created?)",
    });
}

test "todo drop marks a task abandoned without erasing the rest" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .drop, .phase = "Verification" });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqual(Status.abandoned, outcome.next.phases.items[1].tasks.items[0].status);
    try std.testing.expectEqual(Status.in_progress, outcome.next.phases.items[0].tasks.items[0].status);
    try std.testing.expectEqual(Status.pending, outcome.next.phases.items[0].tasks.items[1].status);
}

test "todo block records a normalized blocker note on open work" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{
        .op = .block,
        .phase = "Verification",
        .reason = "waiting on\n  the  user ",
    });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expect(outcome.ok());
    const blocked = outcome.next.phases.items[1].tasks.items[0];
    try std.testing.expectEqual(Status.blocked, blocked.status);
    try std.testing.expectEqualStrings("waiting on the user", blocked.blocker.?);
    // The earliest open task is still promoted, so blocking does not strand the
    // in-progress pointer.
    try std.testing.expectEqual(Status.in_progress, outcome.next.phases.items[0].tasks.items[0].status);
}

test "todo block without a reason leaves the note unset and never reopens closed work" {
    const alloc = std.testing.allocator;
    var list = try listFromSpecs(alloc, &.{
        .{ .phase = "Foundation", .items = &.{
            .{ .content = "Scaffold crate", .status = .completed },
            .{ .content = "Wire workspace", .status = .in_progress },
        } },
    });
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .block, .phase = "Foundation", .reason = "   " });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqual(Status.completed, outcome.next.phases.items[0].tasks.items[0].status);
    try std.testing.expectEqual(Status.blocked, outcome.next.phases.items[0].tasks.items[1].status);
    try std.testing.expect(outcome.next.phases.items[0].tasks.items[1].blocker == null);
}

test "todo block and unblock require a target" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    try expectErrors(alloc, list, .{ .op = .block }, &.{"block requires a task or phase target"});
    try expectErrors(alloc, list, .{ .op = .unblock }, &.{"unblock requires a task or phase target"});
    try expectErrors(alloc, list, .{ .op = .block, .task = "" }, &.{"Missing task content"});
    try expectErrors(alloc, list, .{ .op = .unblock, .phase = "" }, &.{"Missing phase name"});
}

test "todo block rejects an over-long reason" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const reason = "r" ** (max_blocker_bytes + 1);
    try expectErrors(alloc, list, .{ .op = .block, .task = "Scaffold crate", .reason = reason }, &.{
        std.fmt.comptimePrint("Blocker reason is {d} bytes, at most {d} are allowed", .{ reason.len, max_blocker_bytes }),
    });
}

test "todo unblock returns a blocked task to pending and clears the note" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const blocked = try applyTo(alloc, list, .{ .op = .block, .task = "Run tests", .reason = "awaiting review" });
    defer releaseOutcome(alloc, blocked);

    const unblocked = try applyTo(alloc, blocked.next, .{ .op = .unblock, .task = "Run tests" });
    defer releaseOutcome(alloc, unblocked);
    try std.testing.expect(unblocked.ok());
    const task = unblocked.next.phases.items[1].tasks.items[0];
    try std.testing.expectEqual(Status.pending, task.status);
    try std.testing.expect(task.blocker == null);
}

test "todo unblock leaves tasks that were never blocked alone" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .unblock, .task = "Scaffold crate" });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqual(Status.in_progress, outcome.next.phases.items[0].tasks.items[0].status);
}

test "todo rm removes one task, clears one phase, and clears the list" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);

    const one = try applyTo(alloc, list, .{ .op = .rm, .task = "Wire workspace" });
    defer releaseOutcome(alloc, one);
    try std.testing.expectEqual(@as(usize, 1), one.next.phases.items[0].tasks.items.len);
    try std.testing.expectEqualStrings("Scaffold crate", one.next.phases.items[0].tasks.items[0].content);

    const phase = try applyTo(alloc, one.next, .{ .op = .rm, .phase = "Verification" });
    defer releaseOutcome(alloc, phase);
    try std.testing.expectEqual(@as(usize, 0), phase.next.phases.items[1].tasks.items.len);

    const all = try applyTo(alloc, phase.next, .{ .op = .rm });
    defer releaseOutcome(alloc, all);
    try std.testing.expectEqual(@as(usize, 2), all.next.phases.items.len);
    try std.testing.expectEqual(@as(usize, 0), all.next.taskCount());
}

test "todo rm reports an unknown task or phase and changes nothing" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    try expectErrors(alloc, list, .{ .op = .rm, .task = "task-1" }, &.{
        "Task \"task-1\" not found. Tasks are referenced by content, not by IDs — pass the task's full text from the previous result.",
    });
    try expectErrors(alloc, list, .{ .op = .rm, .phase = "Auth" }, &.{"Phase \"Auth\" not found"});
}

test "todo append adds to an existing phase" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .append, .phase = "Verification", .items = &.{ "Handle retries", "Log retries" } });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqual(@as(usize, 2), outcome.next.phases.items.len);
    try std.testing.expectEqual(@as(usize, 3), outcome.next.phases.items[1].tasks.items.len);
    try std.testing.expectEqualStrings("Log retries", outcome.next.phases.items[1].tasks.items[2].content);
    try std.testing.expectEqual(Status.pending, outcome.next.phases.items[1].tasks.items[2].status);
}

test "todo append creates a missing phase lazily" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .append, .phase = "Auth", .items = &.{"Port credential store"} });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expectEqual(@as(usize, 3), outcome.next.phases.items.len);
    try std.testing.expectEqualStrings("Auth", outcome.next.phases.items[2].name);
}

test "todo append reports a missing phase, missing items, and duplicates" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    try expectErrors(alloc, list, .{ .op = .append, .items = &.{"Wire output"} }, &.{"Missing phase name for append operation"});
    try expectErrors(alloc, list, .{ .op = .append, .phase = "Auth" }, &.{"Missing items for append operation"});
    try expectErrors(alloc, list, .{ .op = .append, .phase = "Auth", .items = &.{} }, &.{"Missing items for append operation"});
    try expectErrors(alloc, list, .{ .op = .append, .phase = "Auth", .items = &.{"Run tests"} }, &.{"Task \"Run tests\" already exists"});
    try expectErrors(alloc, list, .{ .op = .append, .phase = "Auth", .items = &.{ "Fresh", "Fresh" } }, &.{"Task \"Fresh\" already exists"});
}

test "todo append bounds the phase name, task content, and total task count" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const long_name = "p" ** (max_phase_name_bytes + 1);
    try expectErrors(alloc, list, .{ .op = .append, .phase = long_name, .items = &.{"Wire output"} }, &.{
        std.fmt.comptimePrint("Phase \"{s}\" is {d} bytes, at most {d} are allowed", .{ long_name, long_name.len, max_phase_name_bytes }),
    });
    const long_content = "t" ** (max_task_content_bytes + 1);
    try expectErrors(alloc, list, .{ .op = .append, .phase = "Auth", .items = &.{long_content} }, &.{
        std.fmt.comptimePrint("Task content is {d} bytes, at most {d} are allowed", .{ long_content.len, max_task_content_bytes }),
    });
    const many = try alloc.alloc([]u8, max_tasks);
    defer {
        for (many) |item| alloc.free(item);
        alloc.free(many);
    }
    for (many, 0..) |*item, index| item.* = try std.fmt.allocPrint(alloc, "Task {d}", .{index});
    try expectErrors(alloc, list, .{ .op = .append, .phase = "Auth", .items = many }, &.{
        std.fmt.comptimePrint("Todo list would hold {d} tasks, at most {d} are allowed", .{ max_tasks + 3, max_tasks }),
    });
}

test "todo append bounds the phase count" {
    const alloc = std.testing.allocator;
    const phases = try alloc.alloc(InitEntry, max_phases);
    defer alloc.free(phases);
    const names = try alloc.alloc([]u8, 2 * max_phases);
    defer {
        for (names) |name| alloc.free(name);
        alloc.free(names);
    }
    for (phases, 0..) |*entry, index| {
        names[2 * index] = try std.fmt.allocPrint(alloc, "Phase {d}", .{index});
        names[2 * index + 1] = try std.fmt.allocPrint(alloc, "Task {d}", .{index});
        entry.* = .{ .phase = names[2 * index], .items = names[2 * index + 1 .. 2 * index + 2] };
    }
    var list = try seeded(alloc, phases);
    defer list.deinit(alloc);
    try std.testing.expectEqual(max_phases, list.phases.items.len);
    try expectErrors(alloc, list, .{ .op = .append, .phase = "Extra", .items = &.{"Wire output"} }, &.{
        std.fmt.comptimePrint("Todo list would hold {d} phases, at most {d} are allowed", .{ max_phases + 1, max_phases }),
    });
}

test "todo view leaves the list untouched" {
    const alloc = std.testing.allocator;
    var list = try seeded(alloc, foundation_and_verification);
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .view });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqual(Operation.view, outcome.op);
    try std.testing.expectEqual(@as(usize, 3), outcome.next.taskCount());
    try std.testing.expectEqual(Status.in_progress, outcome.next.phases.items[0].tasks.items[0].status);
}

test "todo keeps at most one task in progress" {
    const alloc = std.testing.allocator;
    var list = try listFromSpecs(alloc, &.{
        .{ .phase = "Foundation", .items = &.{
            .{ .content = "Scaffold crate", .status = .in_progress },
            .{ .content = "Wire workspace", .status = .in_progress },
            .{ .content = "Run tests", .status = .pending },
        } },
    });
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .view });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expectEqual(Status.in_progress, outcome.next.phases.items[0].tasks.items[0].status);
    try std.testing.expectEqual(Status.pending, outcome.next.phases.items[0].tasks.items[1].status);
    try std.testing.expectEqual(Status.pending, outcome.next.phases.items[0].tasks.items[2].status);
}

test "todo promotes the earliest pending task when none is in progress" {
    const alloc = std.testing.allocator;
    var list = try listFromSpecs(alloc, &.{
        .{ .phase = "Foundation", .items = &.{
            .{ .content = "Scaffold crate", .status = .blocked },
            .{ .content = "Wire workspace", .status = .pending },
        } },
        .{ .phase = "Verification", .items = &.{
            .{ .content = "Run tests", .status = .pending },
        } },
    });
    defer list.deinit(alloc);
    const outcome = try applyTo(alloc, list, .{ .op = .view });
    defer releaseOutcome(alloc, outcome);
    try std.testing.expectEqual(Status.blocked, outcome.next.phases.items[0].tasks.items[0].status);
    try std.testing.expectEqual(Status.in_progress, outcome.next.phases.items[0].tasks.items[1].status);
    try std.testing.expectEqual(Status.pending, outcome.next.phases.items[1].tasks.items[0].status);
}

test "todo summary renders init, done, and the auto-advanced active phase" {
    const alloc = std.testing.allocator;
    var session: Session = .{};
    defer session.deinit(alloc, std.testing.io);

    try expectRendered(&session, .{ .op = .init, .list = foundation_and_verification },
        \\Remaining items (3):
        \\  - Scaffold crate [in_progress] (Foundation)
        \\  - Wire workspace [pending] (Foundation)
        \\  - Run tests [pending] (Verification)
        \\Overall: 0/3 done, 3 open.
        \\Active phase 1/2 "Foundation" (0/2).
        \\  Foundation:
        \\    - [ ] Scaffold crate (in progress)
        \\    - [ ] Wire workspace
        \\  Verification:
        \\    - [ ] Run tests
    );
    try expectRendered(&session, .{ .op = .done, .task = "Wire workspace" },
        \\Remaining items (2):
        \\  - Scaffold crate [in_progress] (Foundation)
        \\  - Run tests [pending] (Verification)
        \\Overall: 1/3 done, 2 open.
        \\Active phase 1/2 "Foundation" (1/2).
        \\  Foundation:
        \\    - [ ] Scaffold crate (in progress)
        \\    - [X] Wire workspace
        \\  Verification:
        \\    - [ ] Run tests
    );
    try expectRendered(&session, .{ .op = .done, .task = "Scaffold crate" },
        \\Remaining items (1):
        \\  - Run tests [in_progress] (Verification)
        \\Overall: 2/3 done, 1 open.
        \\Active phase 2/2 "Verification" (0/1).
        \\  Foundation:
        \\    - [X] Scaffold crate
        \\    - [X] Wire workspace
        \\  Verification:
        \\    - [ ] Run tests (in progress)
    );
}

test "todo summary explains a pointer that sits behind out-of-order work" {
    const alloc = std.testing.allocator;
    var session: Session = .{};
    defer session.deinit(alloc, std.testing.io);
    try seedSession(&session, .{ .op = .init, .list = foundation_and_verification });
    try expectRendered(&session, .{ .op = .done, .task = "Run tests" },
        \\Remaining items (2):
        \\  - Scaffold crate [in_progress] (Foundation)
        \\  - Wire workspace [pending] (Foundation)
        \\Overall: 1/3 done, 2 open.
        \\Active phase 1/2 "Foundation" (0/2) — earliest phase with open tasks; the in-progress pointer auto-advances to the earliest open task on each completion, so it can sit behind out-of-order work (nothing was un-completed).
        \\  Foundation:
        \\    - [ ] Scaffold crate (in progress)
        \\    - [ ] Wire workspace
        \\  Verification:
        \\    - [X] Run tests
    );
}

test "todo summary marks dropped, blocked, and closed work" {
    const alloc = std.testing.allocator;
    var list = try listFromSpecs(alloc, &.{
        .{ .phase = "Foundation", .items = &.{
            .{ .content = "Scaffold crate", .status = .completed },
            .{ .content = "Wire workspace", .status = .abandoned },
        } },
        .{ .phase = "Verification", .items = &.{
            .{ .content = "Run tests", .status = .blocked },
        } },
    });
    defer list.deinit(alloc);
    const rendered = try formatSummary(alloc, list, &.{}, false);
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(
        \\Remaining items: none.
        \\Overall: 2/3 done, 0 open, 1 blocked.
        \\Active phase 2/2 "Verification" (0/1).
        \\  Foundation:
        \\    - [X] Scaffold crate
        \\    - [ ] Wire workspace (dropped)
        \\  Verification:
        \\    - [ ] Run tests (blocked)
    , rendered);
}

test "todo summary reports a blocker note inline" {
    const alloc = std.testing.allocator;
    var session: Session = .{};
    defer session.deinit(alloc, std.testing.io);
    try seedSession(&session, .{ .op = .init, .list = single_phase });
    try expectRendered(&session, .{ .op = .block, .task = "Apply fix", .reason = "awaiting upstream merge" },
        \\Remaining items (1):
        \\  - Run tests [in_progress] (Implementation)
        \\Overall: 0/2 done, 1 open, 1 blocked.
        \\Active phase 1/1 "Implementation" (0/2).
        \\  Implementation:
        \\    - [ ] Apply fix (blocked: awaiting upstream merge)
        \\    - [ ] Run tests (in progress)
    );
}

test "todo summary distinguishes an empty read from an empty mutation" {
    const alloc = std.testing.allocator;
    var session: Session = .{};
    defer session.deinit(alloc, std.testing.io);
    try expectRendered(&session, .{ .op = .view }, "Todo list is empty.");
    try expectRendered(&session, .{ .op = .rm }, "Todo list cleared.");
    try seedSession(&session, .{ .op = .init, .list = single_phase });
    try expectRendered(&session, .{ .op = .rm }, "Todo list cleared.");
    try expectRendered(&session, .{ .op = .view }, "Todo list is empty.");
}

test "todo summary reports errors above the unchanged previous list" {
    const alloc = std.testing.allocator;
    var session: Session = .{};
    defer session.deinit(alloc, std.testing.io);
    try seedSession(&session, .{ .op = .init, .list = single_phase });
    try expectRendered(&session, .{ .op = .append, .phase = "Implementation", .items = &.{"Apply fix"} },
        \\Errors: Task "Apply fix" already exists
        \\Remaining items (2):
        \\  - Apply fix [in_progress] (Implementation)
        \\  - Run tests [pending] (Implementation)
        \\Overall: 0/2 done, 2 open.
        \\Active phase 1/1 "Implementation" (0/2).
        \\  Implementation:
        \\    - [ ] Apply fix (in progress)
        \\    - [ ] Run tests
    );
}

test "todo summary reports every error of a rejected request at once" {
    const alloc = std.testing.allocator;
    var session: Session = .{};
    defer session.deinit(alloc, std.testing.io);
    try seedSession(&session, .{ .op = .init, .list = single_phase });
    try expectRendered(&session, .{ .op = .append, .phase = "Implementation", .items = &.{ "Apply fix", "Run tests" } },
        \\Errors: Task "Apply fix" already exists; Task "Run tests" already exists
        \\Remaining items (2):
        \\  - Apply fix [in_progress] (Implementation)
        \\  - Run tests [pending] (Implementation)
        \\Overall: 0/2 done, 2 open.
        \\Active phase 1/1 "Implementation" (0/2).
        \\  Implementation:
        \\    - [ ] Apply fix (in progress)
        \\    - [ ] Run tests
    );
}

test "todo session keeps the list across calls and clears it on demand" {
    const alloc = std.testing.allocator;
    var session: Session = .{};
    defer session.deinit(alloc, std.testing.io);
    try seedSession(&session, .{ .op = .init, .list = single_phase });

    const view = (try session.apply(alloc, alloc, std.testing.io, .{ .op = .view })).rendered;
    defer alloc.free(view);
    try std.testing.expect(std.mem.indexOf(u8, view, "Active phase 1/1 \"Implementation\"") != null);

    session.clear(alloc, std.testing.io);
    const cleared = (try session.apply(alloc, alloc, std.testing.io, .{ .op = .view })).rendered;
    defer alloc.free(cleared);
    try std.testing.expectEqualStrings("Todo list is empty.", cleared);
}

test "todo session refuses to guess an operation from ambiguous arguments" {
    const alloc = std.testing.allocator;
    var session: Session = .{};
    defer session.deinit(alloc, std.testing.io);
    const applied = try session.apply(alloc, alloc, std.testing.io, .{ .task = "Scaffold crate" });
    try std.testing.expect(applied == .ambiguous_operation);
    try seedSession(&session, .{ .op = .init, .list = single_phase });
    const with_existing_list = try session.apply(alloc, alloc, std.testing.io, .{ .items = &.{"Wire output"} });
    try std.testing.expect(with_existing_list == .ambiguous_operation);
}

test "todo session resolves an omitted operation from the payload" {
    const alloc = std.testing.allocator;
    var session: Session = .{};
    defer session.deinit(alloc, std.testing.io);
    try seedSession(&session, .{ .list = single_phase });
    try expectRendered(&session, .{ .phase = "Implementation", .items = &.{"Log retries"} },
        \\Remaining items (3):
        \\  - Apply fix [in_progress] (Implementation)
        \\  - Run tests [pending] (Implementation)
        \\  - Log retries [pending] (Implementation)
        \\Overall: 0/3 done, 3 open.
        \\Active phase 1/1 "Implementation" (0/3).
        \\  Implementation:
        \\    - [ ] Apply fix (in progress)
        \\    - [ ] Run tests
        \\    - [ ] Log retries
    );
}
