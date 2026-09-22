const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const configured_provider = @import("configured_provider.zig");

pub const ProviderId = union(enum) {
    openpaths,
    gateway,
    codex,
    grok,
    configured: struct {
        bytes: [configured_provider.max_id_bytes]u8 = @splat(0),
        len: u8,
        binding: ?[32]u8 = null,
    },

    /// Borrows the inline name; built-in names have static storage.
    pub fn label(self: *const ProviderId) []const u8 {
        return switch (self.*) {
            .openpaths => "openpaths",
            .gateway => "gateway",
            .codex => "codex",
            .grok => "grok",
            .configured => |*value| value.bytes[0..value.len],
        };
    }

    pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ProviderId {
        const value = try std.json.innerParse(std.json.Value, alloc, source, options);
        return parse_saved(value) catch return error.UnexpectedToken;
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !ProviderId {
        return parse_saved(value) catch return error.UnexpectedToken;
    }

    pub fn jsonStringify(self: ProviderId, writer: anytype) !void {
        if (self == .configured) {
            const binding = self.configured.binding orelse return error.WriteFailed;
            const encoded = std.fmt.bytesToHex(binding, .lower);
            try writer.write(.{ .name = self.label(), .binding = encoded[0..] });
        } else try writer.write(self.label());
    }

    pub fn eql(self: ProviderId, other: ProviderId) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        if (self != .configured) return true;
        return std.mem.eql(
            u8,
            self.configured.bytes[0..self.configured.len],
            other.configured.bytes[0..other.configured.len],
        );
    }

    pub fn bind(self: ProviderId, registry: configured_provider.Registry) error{ UnknownConfiguredProvider, ConfiguredProviderChanged }!ProviderId {
        if (self != .configured) return self;
        const definition = registry.get(self.label()) orelse return error.UnknownConfiguredProvider;
        const binding = definition.binding_identity();
        if (self.configured.binding) |expected| {
            if (!std.mem.eql(u8, &binding, &expected)) return error.ConfiguredProviderChanged;
        }
        var bound = self;
        bound.configured.binding = binding;
        return bound;
    }

    pub fn same_authority(self: ProviderId, other: ProviderId) bool {
        if (!self.eql(other)) return false;
        if (self != .configured) return true;
        const first = self.configured.binding orelse return false;
        const second = other.configured.binding orelse return false;
        return std.mem.eql(u8, &first, &second);
    }
};

/// Name-only key for provider-keyed stores whose lookups never inspect
/// binding identity. Narrower than ProviderId so bounded maps copy less.
pub const NameKey = struct {
    bytes: [configured_provider.max_id_bytes]u8 = @splat(0),
    len: u8 = 0,

    pub fn fromProvider(provider: ProviderId) NameKey {
        var key: NameKey = .{};
        const name = provider.label();
        key.len = @intCast(name.len);
        @memcpy(key.bytes[0..name.len], name);
        return key;
    }

    pub fn label(self: *const NameKey) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eqlName(self: *const NameKey, name: []const u8) bool {
        return self.len == name.len and std.mem.eql(u8, self.bytes[0..self.len], name);
    }

    pub fn eqlProvider(self: *const NameKey, provider: ProviderId) bool {
        return self.eqlName(provider.label());
    }
};

/// Default model served when the OpenPaths provider is active and the user has
/// not chosen one. Verified against the OpenPaths catalog.
pub const openpaths_default_model = "openpaths/stealth/ox-alpha";

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn parse(value: []const u8) ?ProviderId {
    if (std.ascii.eqlIgnoreCase(value, "openpaths")) return .openpaths;
    if (std.ascii.eqlIgnoreCase(value, "openrouter")) return .openpaths;
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    configured_provider.validate_id(value) catch return null;
    var result: ProviderId = .{ .configured = .{ .len = @intCast(value.len) } };
    @memcpy(result.configured.bytes[0..value.len], value);
    return result;
}

pub fn parse_saved(value: std.json.Value) error{InvalidProviderBinding}!ProviderId {
    if (value == .string) {
        const provider = parse(value.string) orelse return error.InvalidProviderBinding;
        if (provider == .configured) return error.InvalidProviderBinding;
        return provider;
    }
    if (value != .object or value.object.count() != 2) return error.InvalidProviderBinding;
    const name = value.object.get("name") orelse return error.InvalidProviderBinding;
    const encoded = value.object.get("binding") orelse return error.InvalidProviderBinding;
    if (name != .string or encoded != .string or encoded.string.len != 64) return error.InvalidProviderBinding;
    var provider = parse(name.string) orelse return error.InvalidProviderBinding;
    if (provider != .configured) return error.InvalidProviderBinding;
    var binding: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&binding, encoded.string) catch return error.InvalidProviderBinding;
    provider.configured.binding = binding;
    return provider;
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    if (selected == .host_managed) return true;
    return switch (provider) {
        .openpaths => selected == .openpaths_api_key or selected == .openrouter_api_key,
        .gateway => selected != .chatgpt_subscription and selected != .grok_subscription and selected != .configured and
            selected != .openpaths_api_key and selected != .openrouter_api_key,
        .configured => selected == .configured,
        .codex => selected == .chatgpt_subscription,
        .grok => selected == .grok_subscription,
    };
}

/// Whether a subscription provider's authenticated catalog can plausibly serve
/// `model`. Codex only serves OpenAI ids and Grok only serves xAI ids, so a
/// third-party id persisted under one of those providers (for example a
/// failover to a DeepSeek model) must be routed through an API-key provider.
pub fn subscriptionCanServe(provider: ProviderId, model: []const u8) bool {
    const id = if (std.mem.lastIndexOfScalar(u8, model, '/')) |slash| model[slash + 1 ..] else model;
    const vendor = if (std.mem.lastIndexOfScalar(u8, model, '/')) |slash| model[0..slash] else "";
    return switch (provider) {
        .openpaths, .gateway, .configured => true,
        .codex => (vendor.len == 0 or std.mem.eql(u8, vendor, "openai")) and
            (std.mem.startsWith(u8, id, "gpt") or std.mem.startsWith(u8, id, "o1") or
                std.mem.startsWith(u8, id, "o3") or std.mem.startsWith(u8, id, "o4") or
                std.mem.startsWith(u8, id, "codex") or std.mem.startsWith(u8, id, "chatgpt")),
        .grok => (vendor.len == 0 or std.mem.eql(u8, vendor, "xai") or std.mem.eql(u8, vendor, "x-ai")) and
            std.mem.startsWith(u8, id, "grok"),
    };
}

/// Reroutes a persisted subscription selection whose model that subscription
/// cannot serve onto OpenPaths when an OpenPaths/OpenRouter key is available.
/// Keeps the user's model choice; only the credential and transport change.
pub fn rerouteUnservableSelection(selection: ProviderSelection) ProviderSelection {
    if (subscriptionCanServe(selection.provider, selection.model)) return selection;
    if (!(hasNonEmptyEnv("OPENPATHS_API_KEY") or hasNonEmptyEnv("OPENROUTER_API_KEY"))) return selection;
    return .{ .provider = .openpaths, .model = selection.model };
}

test "subscription providers only claim their own vendor ids" {
    try std.testing.expect(subscriptionCanServe(.codex, "gpt-5.6"));
    try std.testing.expect(subscriptionCanServe(.codex, "openai/gpt-5-codex"));
    try std.testing.expect(subscriptionCanServe(.codex, "o4-mini"));
    try std.testing.expect(!subscriptionCanServe(.codex, "deepseek-v4-flash-vision-exp"));
    try std.testing.expect(!subscriptionCanServe(.codex, "deepseek/deepseek-v4-flash-vision-exp"));
    try std.testing.expect(!subscriptionCanServe(.codex, "muse-spark-1.3"));
    try std.testing.expect(subscriptionCanServe(.grok, "grok-4"));
    try std.testing.expect(subscriptionCanServe(.grok, "xai/grok-4-fast"));
    try std.testing.expect(!subscriptionCanServe(.grok, "gpt-5.6"));
    try std.testing.expect(subscriptionCanServe(.openpaths, "anything/at-all"));
    try std.testing.expect(subscriptionCanServe(.gateway, "anything/at-all"));
}

pub fn usesGatewayAuxiliaries(provider: ProviderId) bool {
    return provider == .gateway;
}

/// Compiled-default provider. OpenPaths wins automatically whenever one of its
/// API keys is present in the environment so a fresh install works with zero
/// setup commands.
pub fn defaultId() ProviderId {
    if (hasNonEmptyEnv("OPENPATHS_API_KEY") or hasNonEmptyEnv("OPENROUTER_API_KEY")) {
        return .openpaths;
    }
    return .gateway;
}

fn hasNonEmptyEnv(name: []const u8) bool {
    const value = io_mod.getenv(name) orelse return false;
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}
test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key));
    try std.testing.expect(authorizesCredential(.gateway, .fx_login));
    try std.testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription));
    try std.testing.expect(authorizesCredential(.codex, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.codex, null));
    try std.testing.expect(authorizesCredential(.grok, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.grok, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.gateway, .grok_subscription));
}

test "configured provider identity serializes its binding and rejects rebinding" {
    const alloc = std.testing.allocator;
    var registry = try configured_provider.Registry.parse_json(alloc, "{\"local\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"http://localhost:11434/v1\",\"auth\":{\"type\":\"none\"}}}");
    defer registry.deinit(alloc);
    const unbound = parse("local").?;
    const bound = try unbound.bind(registry);
    try std.testing.expect(!unbound.same_authority(bound));
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try std.json.Stringify.value(bound, .{}, &output.writer);
    var decoded = try std.json.parseFromSlice(ProviderId, alloc, output.written(), .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings("local", decoded.value.label());
    try std.testing.expect(decoded.value.same_authority(bound));
    var changed = bound;
    changed.configured.binding.?[0] ^= 1;
    try std.testing.expectError(error.ConfiguredProviderChanged, changed.bind(registry));
    try std.testing.expectError(error.UnknownConfiguredProvider, bound.bind(.{}));
    try std.testing.expectError(error.InvalidProviderBinding, parse_saved(.{ .string = "local" }));
    try std.testing.expect(!authorizesCredential(.gateway, .configured));
    try std.testing.expect(!authorizesCredential(bound, .ai_gateway_api_key));
}

test "provider equality compares tags before names and name keys stay name-only" {
    const gateway = parse("gateway").?;
    const codex = parse("codex").?;
    try std.testing.expect(gateway.eql(parse("gateway").?));
    try std.testing.expect(!gateway.eql(codex));
    try std.testing.expect(!gateway.eql(parse("local").?));
    const local = parse("local").?;
    try std.testing.expect(local.eql(parse("local").?));
    try std.testing.expect(!local.eql(parse("remote").?));
    const key = NameKey.fromProvider(local);
    try std.testing.expectEqualStrings("local", key.label());
    try std.testing.expect(key.eqlName("local"));
    try std.testing.expect(!key.eqlName("remote"));
    try std.testing.expect(key.eqlProvider(local));
    try std.testing.expect(!key.eqlProvider(parse("remote").?));
    const builtin_key = NameKey.fromProvider(gateway);
    try std.testing.expect(builtin_key.eqlName("gateway"));
    try std.testing.expect(builtin_key.eqlProvider(gateway));
}

test "provider parsing recognizes builtins and validated configured names" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expect(parse("openai-codex").? == .configured);
    try std.testing.expect(parse("bad/name") == null);
    try std.testing.expect(parse("") == null);
}
