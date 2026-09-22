const std = @import("std");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_catalog = @import("model_catalog.zig");
const types = @import("../shared/types.zig");

fn optionalPositiveU32(value: u32) ?u32 {
    return if (value == 0) null else value;
}

pub fn fromCatalogEntry(entry: model_catalog.ModelCatalogEntry) model_capabilities.GatewayMetadata {
    return .{
        .supports_reasoning = entry.has_reasoning,
        .reasoning_efforts = .fromSlice(entry.reasoning_efforts.items),
        .supports_fast_mode = entry.supports_fast_mode,
        .supports_tool_use = entry.has_tool_use,
        .supports_vision = entry.has_vision,
        .supports_file_input = entry.has_file_input,
        .image_input_claim = entry.image_input_claim,
        .supports_web_search = entry.has_web_search,
        .supports_explicit_caching = entry.has_explicit_caching,
        .supports_implicit_caching = entry.has_implicit_caching,
        .context_window = optionalPositiveU32(entry.context_window),
        .max_output_tokens = optionalPositiveU32(entry.max_tokens),
    };
}

test "fromCatalogEntry preserves catalog capability metadata" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("future-tier"),
    };
    const metadata = fromCatalogEntry(.{
        .id = @constCast("provider/model"),
        .model_type = @constCast("language"),
        .has_reasoning = true,
        .reasoning_efforts = .{ .items = @constCast(efforts[0..]), .capacity = efforts.len },
        .supports_fast_mode = true,
        .has_tool_use = true,
        .has_vision = true,
        .has_file_input = true,
        .image_input_claim = true,
        .has_web_search = true,
        .has_explicit_caching = true,
        .has_implicit_caching = true,
        .context_window = 256_000,
        .max_tokens = 32_000,
    });

    try std.testing.expect(metadata.supports_reasoning);
    try std.testing.expectEqualStrings("future-tier", metadata.reasoning_efforts.values[0].label());
    try std.testing.expect(metadata.supports_fast_mode);
    try std.testing.expect(metadata.supports_tool_use);
    try std.testing.expect(metadata.supports_vision);
    try std.testing.expect(metadata.supports_file_input);
    try std.testing.expectEqual(@as(?bool, true), metadata.image_input_claim);
    try std.testing.expect(metadata.supports_web_search);
    try std.testing.expect(metadata.supports_explicit_caching);
    try std.testing.expect(metadata.supports_implicit_caching);
    try std.testing.expectEqual(@as(?u32, 256_000), metadata.context_window);
    try std.testing.expectEqual(@as(?u32, 32_000), metadata.max_output_tokens);

    const unknown_limits = fromCatalogEntry(.{
        .id = @constCast("provider/model"),
        .model_type = @constCast("language"),
    });
    try std.testing.expectEqual(@as(?u32, null), unknown_limits.context_window);
    try std.testing.expectEqual(@as(?u32, null), unknown_limits.max_output_tokens);
    try std.testing.expectEqual(@as(?bool, null), unknown_limits.image_input_claim);
}

test "catalog image input claim projects native image capability" {
    const claimed = fromCatalogEntry(.{
        .id = @constCast("xiaomi/mimo-v2.6-pro"),
        .model_type = @constCast("language"),
        .has_tool_use = true,
        .image_input_claim = true,
    });
    try std.testing.expectEqual(@as(?bool, true), claimed.image_input_claim);
    try std.testing.expectEqual(
        model_capabilities.ImageInputSupport.native,
        model_capabilities.resolveCapabilities("xiaomi/mimo-v2.6-pro", claimed).image_input_support,
    );

    const conservative = model_capabilities.resolveCapabilities(
        "provider/text-only",
        fromCatalogEntry(.{
            .id = @constCast("provider/text-only"),
            .model_type = @constCast("language"),
            .image_input_claim = false,
        }),
    );
    try std.testing.expectEqual(
        model_capabilities.ImageInputSupport.non_native,
        conservative.image_input_support,
    );
}

test "catalog entries without modalities defer to the provider image default" {
    const unclaimed = fromCatalogEntry(.{
        .id = @constCast("xiaomi/mimo-v2.6-pro"),
        .model_type = @constCast("language"),
    });
    try std.testing.expectEqual(@as(?bool, null), unclaimed.image_input_claim);
    try std.testing.expectEqual(
        model_capabilities.ImageInputSupport.native,
        model_capabilities.mergeCapabilities(
            .{ .image_input_support = .native },
            unclaimed,
        ).image_input_support,
    );
    try std.testing.expectEqual(
        model_capabilities.ImageInputSupport.non_native,
        model_capabilities.mergeCapabilities(
            .{ .image_input_support = .native },
            fromCatalogEntry(.{
                .id = @constCast("xiaomi/mimo-v2.6-pro"),
                .model_type = @constCast("language"),
                .image_input_claim = false,
            }),
        ).image_input_support,
    );
}
