const std = @import("std");
const terminal = @import("../main.zig");
const Allocator = std.mem.Allocator;
const ImageStorage = terminal.kitty.graphics.ImageStorage;

const log = std.log.scoped(.kitty_gfx);

/// A render placement is a way to position a Kitty graphics image onto
/// the screen. It is broken down into the fields that make it easier to
/// position the image using a renderer.
pub const Placement = struct {
    /// The top-left corner of the image in grid coordinates.
    top_left: terminal.Pin,

    /// The offset in pixels from the top-left corner of the grid cell.
    offset_x: u32 = 0,
    offset_y: u32 = 0,

    /// The source rectangle of the image to render. This doesn't have to
    /// match the size the destination size and the renderer is expected
    /// to scale the image to fit the destination size.
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,

    /// The final width/height of the image in pixels.
    dest_width: u32 = 0,
    dest_height: u32 = 0,
};

pub const CellSize = struct {
    width: u32,
    height: u32,
};

pub const Fragment = struct {
    pub const Kind = enum { placement, virtual };

    kind: Kind,
    image_id: u32,
    /// Storage key of the placement that produced this fragment. For virtual
    /// fragments this is the definition resolved by ImageStorage.placeholderTarget.
    key: ImageStorage.PlacementKey,
    z: i32,
    /// Viewport cell origin; may be negative / beyond edges for ordinary placements (not clipped).
    x: i32,
    y: i32,
    offset_x: u32,
    offset_y: u32,
    width: u32,
    height: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};

/// True when the render list depends on cell contents and must be rebuilt
/// whenever cells change, even if the storage generation is unchanged.
pub fn dependsOnCells(storage: *const ImageStorage) bool {
    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.location) {
            .virtual => return true,
            .pin => {},
            .relative => |rel| {
                const chain = storage.resolveChain(rel) orelse continue;
                if (chain.root.location == .virtual) return true;
            },
        }
    }

    return false;
}

/// Clears `list` and appends renderable fragments for the active viewport.
///
/// Fragments use renderer draw order: z, image ID, placement tag (internal
/// before external), placement ID, viewport row, then viewport column.
pub fn collect(
    alloc: Allocator,
    t: *const terminal.Terminal,
    cell_size: CellSize,
    list: *std.ArrayListUnmanaged(Fragment),
) Allocator.Error!void {
    list.clearRetainingCapacity();
    defer std.mem.sort(Fragment, list.items, {}, fragmentLessThan);

    const screen = t.screens.active;
    const storage = &screen.kitty_images;
    const top = screen.pages.getTopLeft(.viewport);
    const bot = screen.pages.getBottomRight(.viewport) orelse return;
    const top_y = (screen.pages.pointFromPin(.screen, top) orelse return).screen.y;
    const bot_y = (screen.pages.pointFromPin(.screen, bot) orelse return).screen.y;

    const PendingRelative = struct {
        image_id: u32,
        key: ImageStorage.PlacementKey,
        p: ImageStorage.Placement,
        root_key: ImageStorage.PlacementKey,
        horizontal_offset: i32,
        vertical_offset: i32,
    };
    var pending_relative: std.ArrayListUnmanaged(PendingRelative) = .empty;
    defer pending_relative.deinit(alloc);

    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const p = entry.value_ptr;

        const origin: union(enum) {
            pin: *terminal.Pin,
            relative: struct {
                pin: *terminal.Pin,
                horizontal_offset: i32,
                vertical_offset: i32,
            },
        } = switch (p.location) {
            .pin => |pin| .{ .pin = pin },
            .virtual => continue,
            .relative => |rel| origin: {
                const chain = storage.resolveChain(rel) orelse continue;
                switch (chain.root.location) {
                    .pin => |pin| break :origin .{ .relative = .{
                        .pin = pin,
                        .horizontal_offset = chain.horizontal_offset,
                        .vertical_offset = chain.vertical_offset,
                    } },
                    .virtual => {
                        try pending_relative.append(alloc, .{
                            .image_id = key.image_id,
                            .key = key,
                            .p = p.*,
                            .root_key = chain.root_key,
                            .horizontal_offset = chain.horizontal_offset,
                            .vertical_offset = chain.vertical_offset,
                        });
                        continue;
                    },
                    .relative => unreachable,
                }
            },
        };

        const image = storage.imageById(key.image_id) orelse {
            log.warn("missing image for placement, ignoring image_id={}", .{key.image_id});
            continue;
        };
        if (image.data.isPending()) continue;

        const pin, const horizontal_offset, const vertical_offset = switch (origin) {
            .pin => |pin| .{ pin, @as(i32, 0), @as(i32, 0) },
            .relative => |value| .{ value.pin, value.horizontal_offset, value.vertical_offset },
        };
        if (pin.garbage) continue;

        const grid = p.gridSize(image, t);
        if (grid.cols == 0 or grid.rows == 0) continue;

        const pin_screen = screen.pages.pointFromPin(.screen, pin.*) orelse continue;
        const img_top_y: i64 = @as(i64, pin_screen.screen.y) + vertical_offset;
        const img_bot_y: i64 = img_top_y + grid.rows - 1;
        const img_left_x: i64 = @as(i64, pin.x) + horizontal_offset;
        const img_right_x: i64 = img_left_x + grid.cols - 1;
        if (img_top_y > bot_y or img_bot_y < top_y) continue;
        if (img_left_x >= t.cols or img_right_x < 0) continue;

        const x = std.math.cast(i32, img_left_x) orelse continue;
        const y = std.math.cast(i32, img_top_y - top_y) orelse continue;
        const dest = p.pixelSize(image, t);
        if (dest.width == 0 or dest.height == 0) continue;
        const offset = p.cellOffset(t);
        const source = p.sourceRect(image);
        try list.append(alloc, .{
            .kind = .placement,
            .image_id = image.id,
            .key = key,
            .z = p.z,
            .x = x,
            .y = y,
            .offset_x = offset.x,
            .offset_y = offset.y,
            .width = dest.width,
            .height = dest.height,
            .source_x = source.x,
            .source_y = source.y,
            .source_width = source.width,
            .source_height = source.height,
        });
    }

    if (dependsOnCells(storage) and cell_size.width > 0 and cell_size.height > 0) {
        var virtual_origins: std.AutoHashMapUnmanaged(
            ImageStorage.PlacementKey,
            struct { x: u32, y: u32 },
        ) = .empty;
        defer virtual_origins.deinit(alloc);

        var virtual_it = terminal.kitty.graphics.unicode.placementIterator(top, bot);
        while (virtual_it.next()) |virtual_p| {
            const target = storage.placeholderTarget(
                virtual_p.image_id,
                virtual_p.placement_id,
            );
            if (pending_relative.items.len > 0) fold: {
                const resolved_target = target orelse break :fold;
                const viewport = screen.pages.pointFromPin(.viewport, virtual_p.pin) orelse break :fold;
                const gop = try virtual_origins.getOrPut(alloc, resolved_target.key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .x = viewport.viewport.x, .y = viewport.viewport.y };
                } else {
                    gop.value_ptr.x = @min(gop.value_ptr.x, viewport.viewport.x);
                    gop.value_ptr.y = @min(gop.value_ptr.y, viewport.viewport.y);
                }
            }

            const image = storage.imageById(virtual_p.image_id) orelse {
                log.warn(
                    "missing image for virtual placement, ignoring image_id={}",
                    .{virtual_p.image_id},
                );
                continue;
            };
            if (image.data.isPending()) continue;

            const rp = virtual_p.renderPlacement(
                storage,
                &image,
                cell_size.width,
                cell_size.height,
            ) catch |err| {
                log.warn("error rendering virtual placement err={}", .{err});
                continue;
            };
            if (rp.dest_width == 0 or rp.dest_height == 0) continue;

            const resolved_target = target orelse continue;
            const viewport = screen.pages.pointFromPin(.viewport, rp.top_left) orelse continue;
            try list.append(alloc, .{
                .kind = .virtual,
                .image_id = image.id,
                .key = resolved_target.key,
                .z = -1,
                .x = rp.top_left.x,
                .y = @intCast(viewport.viewport.y),
                .offset_x = rp.offset_x,
                .offset_y = rp.offset_y,
                .width = rp.dest_width,
                .height = rp.dest_height,
                .source_x = rp.source_x,
                .source_y = rp.source_y,
                .source_width = rp.source_width,
                .source_height = rp.source_height,
            });
        }

        for (pending_relative.items) |relative| {
            const origin = virtual_origins.get(relative.root_key) orelse continue;
            const image = storage.imageById(relative.image_id) orelse continue;
            if (image.data.isPending()) continue;

            const grid = relative.p.gridSize(image, t);
            if (grid.cols == 0 or grid.rows == 0) continue;
            const x: i64 = @as(i64, origin.x) + relative.horizontal_offset;
            const y: i64 = @as(i64, origin.y) + relative.vertical_offset;
            if (y >= t.rows or y + grid.rows - 1 < 0) continue;
            if (x >= t.cols or x + grid.cols - 1 < 0) continue;

            const x_pos = std.math.cast(i32, x) orelse continue;
            const y_pos = std.math.cast(i32, y) orelse continue;
            const dest = relative.p.pixelSize(image, t);
            if (dest.width == 0 or dest.height == 0) continue;
            const offset = relative.p.cellOffset(t);
            const source = relative.p.sourceRect(image);
            try list.append(alloc, .{
                .kind = .placement,
                .image_id = image.id,
                .key = relative.key,
                .z = relative.p.z,
                .x = x_pos,
                .y = y_pos,
                .offset_x = offset.x,
                .offset_y = offset.y,
                .width = dest.width,
                .height = dest.height,
                .source_x = source.x,
                .source_y = source.y,
                .source_width = source.width,
                .source_height = source.height,
            });
        }
    }
}

fn fragmentLessThan(_: void, lhs: Fragment, rhs: Fragment) bool {
    if (lhs.z != rhs.z) return lhs.z < rhs.z;
    if (lhs.image_id != rhs.image_id) return lhs.image_id < rhs.image_id;
    const lhs_tag = @intFromEnum(lhs.key.placement_id.tag);
    const rhs_tag = @intFromEnum(rhs.key.placement_id.tag);
    if (lhs_tag != rhs_tag) return lhs_tag < rhs_tag;
    if (lhs.key.placement_id.id != rhs.key.placement_id.id) {
        return lhs.key.placement_id.id < rhs.key.placement_id.id;
    }
    if (lhs.y != rhs.y) return lhs.y < rhs.y;
    return lhs.x < rhs.x;
}
