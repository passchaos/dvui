pub const PlotWidget = @This();

src: std.builtin.SourceLocation,
opts: Options,
box: BoxWidget = undefined,
data_rs: RectScale = undefined,
old_clip: Rect.Physical = undefined,
init_options: InitOptions,
x_axis: *Axis = undefined,
x_axis_store: Axis = .{},
y_axis: *Axis = undefined,
y_axis_store: Axis = .{},
mouse_point: ?Point.Physical = null,
hover_data: ?HoverData = null,
data_min: Data = .{ .x = std.math.floatMax(f64), .y = std.math.floatMax(f64) },
data_max: Data = .{ .x = -std.math.floatMax(f64), .y = -std.math.floatMax(f64) },
items: ?std.array_list.Managed(PlotItem) = null,
legend_enabled: bool = false,

pub var defaults: Options = .{
    .name = "Plot",
    .role = .group,
    .label = .{ .text = "Plot" },
    .padding = Rect.all(6),
    .background = true,
    .min_size_content = .{ .w = 20, .h = 20 },
    .style = .content,
};

pub const InitOptions = struct {
    title: ?[]const u8 = null,
    x_axis: ?*Axis = null,
    y_axis: ?*Axis = null,
    border_thick: ?f32 = null,
    spine_color: ?dvui.Color = null,
    mouse_hover: bool = false,
    legend_enabled: bool = false,
    was_allocated_on_widget_stack: bool = false,
};

pub const Axis = struct {
    name: ?[]const u8 = null,
    min: ?f64 = null,
    max: ?f64 = null,

    scale: union(enum) {
        linear,
        log: struct {
            base: f64 = 10,
        },
    } = .linear,

    ticks: struct {
        locations: union(TickLocatorType) {
            none,
            auto: struct {
                tick_num_suggestion: usize = 5,
                tick_num_max: usize = 20,
            },
            custom: []const f64,
        } = .{ .auto = .{} },

        side: TicklinesSide = .both,

        // if null it uses the default for `scale`
        format: ?TickFormating = null,

        subticks: bool = false,
    } = .{},

    // only relevant if `ticks.locations` != none
    // if null the gridlines are not rendered
    gridline_color: ?dvui.Color = null,
    subtick_gridline_color: ?dvui.Color = null,

    pub const TicklinesSide = enum {
        none,
        left_or_top,
        right_or_bottom,
        both,
    };

    pub const TickLocatorType = enum {
        none,
        auto,
        custom,
    };

    pub const Ticks = struct {
        locator_type: TickLocatorType,
        values: []const f64,
        subticks: []const f64,

        fn deinit(self: *Ticks, gpa: std.mem.Allocator) void {
            switch (self.locator_type) {
                .auto => {
                    gpa.free(self.values);
                    gpa.free(self.subticks);
                },
                else => {},
            }
        }

        const empty = Ticks{
            .locator_type = .none,
            .values = &.{},
            .subticks = &.{},
        };
    };

    pub const TickFormating = union(enum) {
        normal: struct {
            precision: usize = 2,
        },
        scientific_notation: struct {
            precision: usize = 4,
        },
        custom: *const fn (gpa: std.mem.Allocator, tick: f64) std.mem.Allocator.Error![]const u8,
    };

    pub fn formatTick(self: *Axis, gpa: std.mem.Allocator, tick: f64) ![]const u8 {
        const tick_format = self.ticks.format orelse
            switch (self.scale) {
                .linear => TickFormating{ .normal = .{} },
                .log => TickFormating{ .scientific_notation = .{} },
            };

        switch (tick_format) {
            .normal => |cfg| {
                return try std.fmt.allocPrint(gpa, "{d:.[1]}", .{ tick, cfg.precision });
            },
            .scientific_notation => |cfg| {
                return try std.fmt.allocPrint(gpa, "{e:.[1]}", .{ tick, cfg.precision });
            },
            .custom => |func| {
                return func(gpa, tick);
            },
        }
    }

    pub fn fraction(self: *Axis, val: f64) f32 {
        if (self.min == null or self.max == null) return 0;

        const min = self.min.?;
        const max = self.max.?;

        switch (self.scale) {
            .linear => {
                return @floatCast((val - min) / (max - min));
            },
            .log => |log_data| {
                const val_exp = std.math.log(f64, log_data.base, val);
                const min_exp = std.math.log(f64, log_data.base, min);
                const max_exp = std.math.log(f64, log_data.base, max);
                return @floatCast((val_exp - min_exp) / (max_exp - min_exp));
            },
        }
    }

    // nice steps are 1, 2, 5, 10
    fn niceStep(approx_step: f64) f64 {
        const exp = std.math.floor(std.math.log10(approx_step));
        const multiplier = std.math.pow(f64, 10, exp);
        const mantissa = approx_step / multiplier;
        // mantissa is [0, 10)

        const nice_mantissa: f64 = if (mantissa < 1.5)
            1
        else if (mantissa < 3)
            2
        else if (mantissa < 7)
            5
        else
            10;

        return nice_mantissa * multiplier;
    }

    fn getTicksLinear(
        gpa: std.mem.Allocator,
        min: f64,
        max: f64,
        tick_num_suggestion: usize,
        tick_num_max: usize,
        calc_subticks: bool,
    ) !Ticks {
        if (tick_num_suggestion == 0 or tick_num_max == 0) return Ticks.empty;

        const approximate_step = (max - min) / @as(f64, @floatFromInt(tick_num_suggestion));
        const nice_step = niceStep(approximate_step);

        const first_tick = std.math.ceil(min / nice_step) * nice_step;
        const tick_count_best: usize = @intFromFloat(std.math.ceil((max - first_tick) / nice_step));

        const tick_count = @min(tick_num_max, tick_count_best);

        var ticks = try gpa.alloc(f64, tick_count);
        for (0..tick_count) |i| {
            const tick = first_tick + @as(f64, @floatFromInt(i)) * nice_step;
            ticks[i] = tick;
        }

        const subticks = blk: {
            if (calc_subticks) {
                const subtick_count: usize = 3;
                const subticks = try gpa.alloc(f64, (ticks.len + 1) * subtick_count);

                for (0..ticks.len + 1) |i| {
                    const tick = if (i == 0)
                        ticks[0] - nice_step
                    else
                        ticks[i - 1];

                    for (0..subtick_count) |j| {
                        const ratio = @as(f64, @floatFromInt(1 + j)) / @as(f64, @floatFromInt(subtick_count + 1));
                        const off: f64 = ratio * nice_step;
                        subticks[i * subtick_count + j] = tick + off;
                    }
                }
                break :blk subticks;
            } else {
                break :blk &.{};
            }
        };

        return Ticks{
            .locator_type = .auto,
            .values = ticks,
            .subticks = subticks,
        };
    }

    fn getTicksLog(
        gpa: std.mem.Allocator,
        base: f64,
        min: f64,
        max: f64,
        tick_num_suggestion: usize,
        tick_num_max: usize,
        calc_subticks: bool,
    ) !Ticks {
        const first_tick_exp = std.math.ceil(std.math.log(f64, base, min));
        const last_tick_exp = std.math.floor(std.math.log(f64, base, max));

        const exp_range = last_tick_exp - first_tick_exp;
        const step_raw = std.math.round(exp_range / @as(f64, @floatFromInt(tick_num_suggestion)));
        // the exponent step is clamped to a minimum of 1
        const step = @max(step_raw, 1);

        const tick_count = @min(
            tick_num_max,
            @as(usize, @intFromFloat(last_tick_exp - first_tick_exp)) + 1,
        );

        var ticks = try gpa.alloc(f64, tick_count);
        for (0..tick_count) |i| {
            const exp = first_tick_exp + @as(f64, @floatFromInt(i)) * step;
            const tick = std.math.pow(f64, base, exp);
            ticks[i] = tick;
        }

        const subticks = blk: {
            if (calc_subticks) {
                const subtick_count: usize = @intFromFloat(base - 2);
                const subticks = try gpa.alloc(f64, ticks.len * subtick_count);

                for (0.., ticks) |i, tick| {
                    for (0..subtick_count) |j| {
                        const multiplier: f64 = @floatFromInt(2 + j);
                        subticks[i * subtick_count + j] = tick * multiplier;
                    }
                }
                break :blk subticks;
            } else {
                break :blk &.{};
            }
        };

        return Ticks{
            .locator_type = .auto,
            .values = ticks,
            .subticks = subticks,
        };
    }

    pub fn getTicks(self: *Axis, gpa: std.mem.Allocator) !Ticks {
        switch (self.ticks.locations) {
            .none => return Ticks.empty,
            .auto => |auto_ticks| {
                const min = self.min orelse return Ticks.empty;
                const max = self.max orelse return Ticks.empty;

                return switch (self.scale) {
                    .linear => getTicksLinear(
                        gpa,
                        min,
                        max,
                        auto_ticks.tick_num_suggestion,
                        auto_ticks.tick_num_max,
                        self.ticks.subticks,
                    ),
                    .log => |log_scale| getTicksLog(
                        gpa,
                        log_scale.base,
                        min,
                        max,
                        auto_ticks.tick_num_suggestion,
                        auto_ticks.tick_num_max,
                        self.ticks.subticks,
                    ),
                };
            },
            .custom => |ticks| {
                return Ticks{
                    .locator_type = .custom,
                    .values = ticks,
                    .subticks = &.{},
                };
            },
        }
    }
};

pub const HoverData = union(enum) {
    point: Data,
    bar: struct {
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    },
};

pub const Data = struct {
    x: f64,
    y: f64,
};

pub const PlotItem = struct {
    name: []const u8,
    color: dvui.Color,
    item_type: ItemType,
    visible: bool = true,
    hovered: bool = false,

    pub const ItemType = enum {
        line,
        scatter,
        bar,
        area,
    };
};

pub const Line = struct {
    plot: *PlotWidget,
    path: dvui.Path.Builder,
    name: []const u8,
    color: dvui.Color,

    pub fn point(self: *Line, x: f64, y: f64) void {
        const data_point: Data = .{ .x = x, .y = y };
        self.plot.dataForRange(data_point);
        const screen_p = self.plot.dataToScreen(data_point);
        if (self.plot.mouse_point) |mp| {
            const dp = Point.Physical.diff(mp, screen_p);
            const dps = dp.toNatural();
            if (@abs(dps.x) <= 3 and @abs(dps.y) <= 3) {
                self.plot.hover_data = .{ .point = data_point };
            }
        }
        self.path.addPoint(screen_p);
    }

    pub fn stroke(self: *Line, thick: f32, color: dvui.Color) void {
        self.color = color;
        // Update color in plot's items list
        var is_visible = true;
        var is_hovered = false;
        if (self.plot.items) |items| {
            for (items.items) |*item| {
                if (std.mem.eql(u8, item.name, self.name)) {
                    item.color = color;
                    // Get visible state from data storage
                    const base_id = self.plot.box.data().id;
                    const legend_id = base_id.update("legend");
                    const item_id = legend_id.update(item.name);
                    is_visible = dvui.dataGet(null, item_id, "visible", bool) orelse true;
                    item.visible = is_visible;
                    // Check if mouse is hovering over this item's legend
                    is_hovered = self.plot.isLegendItemHovered(item.name);
                    item.hovered = is_hovered;
                    break;
                }
            }
        }
        // Only draw if visible
        if (is_visible) {
            // Increase thickness when hovered
            const hover_scale: f32 = if (is_hovered) 1.5 else 1.0;
            self.path.build().stroke(.{ .thickness = thick * self.plot.data_rs.s * hover_scale, .color = color });
        }
    }

    pub fn deinit(self: *Line) void {
        // The Line "widget" intentionally doesn't call `dvui.widgetFree` as it should always be created by `PlotWidget.line`
        defer self.* = undefined;
        self.path.deinit();
    }
};

pub const Scatter = struct {
    plot: *PlotWidget,
    points: std.array_list.Managed(Data),
    screen_points: std.array_list.Managed(Point.Physical),
    name: []const u8,
    color: dvui.Color,

    pub fn point(self: *Scatter, x: f64, y: f64) void {
        const data_point: Data = .{ .x = x, .y = y };
        self.plot.dataForRange(data_point);
        const screen_p = self.plot.dataToScreen(data_point);

        self.points.append(data_point) catch unreachable;
        self.screen_points.append(screen_p) catch unreachable;

        if (self.plot.mouse_point) |mp| {
            const dp = Point.Physical.diff(mp, screen_p);
            const dps = dp.toNatural();
            if (@abs(dps.x) <= 5 and @abs(dps.y) <= 5) {
                self.plot.hover_data = .{ .point = data_point };
            }
        }
    }

    pub fn draw(self: *Scatter, radius: f32, color: dvui.Color) void {
        self.color = color;
        // Update color in plot's items list
        var is_visible = true;
        var is_hovered = false;
        if (self.plot.items) |items| {
            for (items.items) |*item| {
                if (std.mem.eql(u8, item.name, self.name)) {
                    item.color = color;
                    // Get visible state from data storage
                    const base_id = self.plot.box.data().id;
                    const legend_id = base_id.update("legend");
                    const item_id = legend_id.update(item.name);
                    is_visible = dvui.dataGet(null, item_id, "visible", bool) orelse true;
                    item.visible = is_visible;
                    // Check if mouse is hovering over this item's legend
                    is_hovered = self.plot.isLegendItemHovered(item.name);
                    item.hovered = is_hovered;
                    break;
                }
            }
        }
        // Only draw if visible
        if (is_visible) {
            // Increase radius when hovered
            const hover_scale: f32 = if (is_hovered) 1.5 else 1.0;
            for (self.screen_points.items) |screen_p| {
                const r = radius * self.plot.data_rs.s * hover_scale;
                var circle_path = dvui.Path.Builder.init(dvui.currentWindow().lifo());
                defer circle_path.deinit();
                circle_path.addArc(screen_p, r, std.math.pi * 2, 0, false);
                circle_path.build().fillConvex(.{ .color = color });
            }
        }
    }

    pub fn deinit(self: *Scatter) void {
        // The Scatter "widget" intentionally doesn't call `dvui.widgetFree` as it should always be created by `PlotWidget.scatter`
        defer self.* = undefined;
        self.points.deinit();
        self.screen_points.deinit();
    }
};

pub const Area = struct {
    plot: *PlotWidget,
    path: dvui.Path.Builder,
    base_y: f64 = 0,
    name: []const u8,
    color: dvui.Color,

    pub fn point(self: *Area, x: f64, y: f64) void {
        const data_point: Data = .{ .x = x, .y = y };
        self.plot.dataForRange(data_point);
        const screen_p = self.plot.dataToScreen(data_point);
        if (self.plot.mouse_point) |mp| {
            const dp = Point.Physical.diff(mp, screen_p);
            const dps = dp.toNatural();
            if (@abs(dps.x) <= 3 and @abs(dps.y) <= 3) {
                self.plot.hover_data = .{ .point = data_point };
            }
        }
        self.path.addPoint(screen_p);
    }

    pub fn setBase(self: *Area, y: f64) void {
        self.base_y = y;
    }

    pub fn fill(self: *Area, color: dvui.Color) void {
        self.color = color;
        // Update color in plot's items list
        var is_visible = true;
        if (self.plot.items) |items| {
            for (items.items) |*item| {
                if (std.mem.eql(u8, item.name, self.name)) {
                    item.color = color;
                    // Get visible state from data storage
                    const base_id = self.plot.box.data().id;
                    const legend_id = base_id.update("legend");
                    const item_id = legend_id.update(item.name);
                    is_visible = dvui.dataGet(null, item_id, "visible", bool) orelse true;
                    item.visible = is_visible;
                    break;
                }
            }
        }
        // Only draw if visible
        if (is_visible) {
            if (self.path.points.items.len < 2) return;

            // Create a copy of the path and add the base line
            var area_path = dvui.Path.Builder.init(dvui.currentWindow().lifo());
            defer area_path.deinit();

            // Add all the points in order
            for (self.path.points.items) |p| {
                area_path.addPoint(p);
            }

            // Add the base line points in reverse order
            for (self.path.points.items) |p| {
                const data_p = self.plot.screenToData(p);
                const base_data_point: Data = .{ .x = data_p.x, .y = self.base_y };
                const base_screen_p = self.plot.dataToScreen(base_data_point);
                area_path.addPoint(base_screen_p);
            }

            // Close the path back to the first point
            if (self.path.points.items.len > 0) {
                area_path.addPoint(self.path.points.items[0]);
            }

            // Fill the area
            area_path.build().fillConvex(.{ .color = color });
        }
    }

    pub fn stroke(self: *Area, thick: f32, color: dvui.Color) void {
        self.color = color;
        // Update color in plot's items list
        var is_visible = true;
        var is_hovered = false;
        if (self.plot.items) |items| {
            for (items.items) |*item| {
                if (std.mem.eql(u8, item.name, self.name)) {
                    item.color = color;
                    // Get visible state from data storage
                    const base_id = self.plot.box.data().id;
                    const legend_id = base_id.update("legend");
                    const item_id = legend_id.update(item.name);
                    is_visible = dvui.dataGet(null, item_id, "visible", bool) orelse true;
                    item.visible = is_visible;
                    // Check if mouse is hovering over this item's legend
                    is_hovered = self.plot.isLegendItemHovered(item.name);
                    item.hovered = is_hovered;
                    break;
                }
            }
        }
        // Only draw if visible
        if (is_visible) {
            // Increase thickness when hovered
            const hover_scale: f32 = if (is_hovered) 1.5 else 1.0;
            self.path.build().stroke(.{ .thickness = thick * self.plot.data_rs.s * hover_scale, .color = color });
        }
    }

    pub fn deinit(self: *Area) void {
        // The Area "widget" intentionally doesn't call `dvui.widgetFree` as it should always be created by `PlotWidget.area`
        defer self.* = undefined;
        self.path.deinit();
    }
};

pub fn dataToScreen(self: *PlotWidget, data_point: Data) dvui.Point.Physical {
    const xfrac = self.x_axis.fraction(data_point.x);
    const yfrac = self.y_axis.fraction(data_point.y);
    return .{
        .x = self.data_rs.r.x + xfrac * self.data_rs.r.w,
        .y = self.data_rs.r.y + (1.0 - yfrac) * self.data_rs.r.h,
    };
}

pub fn screenToData(self: *PlotWidget, screen_point: Point.Physical) Data {
    const xfrac = (screen_point.x - self.data_rs.r.x) / self.data_rs.r.w;
    const yfrac = 1.0 - (screen_point.y - self.data_rs.r.y) / self.data_rs.r.h;

    const min_x = self.x_axis.min orelse self.data_min.x;
    const max_x = self.x_axis.max orelse self.data_max.x;
    const min_y = self.y_axis.min orelse self.data_min.y;
    const max_y = self.y_axis.max orelse self.data_max.y;

    const x = min_x + xfrac * (max_x - min_x);
    const y = min_y + yfrac * (max_y - min_y);

    return .{ .x = x, .y = y };
}

pub fn dataForRange(self: *PlotWidget, data_point: Data) void {
    self.data_min.x = @min(self.data_min.x, data_point.x);
    self.data_max.x = @max(self.data_max.x, data_point.x);
    self.data_min.y = @min(self.data_min.y, data_point.y);
    self.data_max.y = @max(self.data_max.y, data_point.y);
}

/// It's expected to call this when `self` is `undefined`
pub fn init(self: *PlotWidget, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) void {
    self.* = .{
        .src = src,
        .opts = opts,
        .init_options = init_opts,
        .items = std.array_list.Managed(PlotItem).init(dvui.currentWindow().lifo()),
        .legend_enabled = init_opts.legend_enabled,
    };

    self.box.init(self.src, .{ .dir = .vertical }, defaults.override(self.opts));
    if (self.init_options.x_axis) |xa| {
        self.x_axis = xa;
    } else {
        if (dvui.dataGet(null, self.box.data().id, "_x_axis", Axis)) |xaxis| {
            self.x_axis_store = xaxis;
        }
        self.x_axis = &self.x_axis_store;
    }

    if (self.init_options.y_axis) |ya| {
        self.y_axis = ya;
    } else {
        if (dvui.dataGet(null, self.box.data().id, "_y_axis", Axis)) |yaxis| {
            self.y_axis_store = yaxis;
        }
        self.y_axis = &self.y_axis_store;
    }

    self.box.drawBackground();

    if (self.init_options.title) |title| {
        dvui.label(@src(), "{s}", .{title}, .{ .gravity_x = 0.5, .font = opts.themeGet().font_title });
    }

    const tick_font = opts.themeGet().font_body.larger(-3);

    var yticks = self.y_axis.getTicks(dvui.currentWindow().lifo()) catch Axis.Ticks.empty;
    defer yticks.deinit(dvui.currentWindow().lifo());

    var xticks = self.x_axis.getTicks(dvui.currentWindow().lifo()) catch Axis.Ticks.empty;
    defer xticks.deinit(dvui.currentWindow().lifo());

    const y_axis_tick_width: f32 = blk: {
        if (self.y_axis.name == null) break :blk 0;
        var max_width: f32 = 0;

        for (yticks.values) |ytick| {
            const tick_str = self.y_axis.formatTick(dvui.currentWindow().lifo(), ytick) catch "";
            defer dvui.currentWindow().lifo().free(tick_str);
            max_width = @max(max_width, tick_font.textSize(tick_str).w);
        }

        break :blk max_width;
    };

    const x_axis_last_tick_width: f32 = blk: {
        if (xticks.values.len == 0) break :blk 0;
        const str = self.x_axis.formatTick(
            dvui.currentWindow().lifo(),
            xticks.values[xticks.values.len - 1],
        ) catch "";
        defer dvui.currentWindow().lifo().free(str);

        break :blk tick_font.sizeM(@as(f32, @floatFromInt(str.len)), 1).w;
    };

    var hbox1 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });

    // y axis label
    var yaxis = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .vertical,
        .min_size_content = .{ .w = y_axis_tick_width },
        .padding = dvui.Rect{ .w = y_axis_tick_width },
    });
    var yaxis_rect = yaxis.data().rect;
    if (self.y_axis.name) |yname| {
        if (yname.len > 0) {
            dvui.label(@src(), "{s}", .{yname}, .{ .gravity_y = 0.5, .rotation = std.math.pi * 1.5 });
        }
    }
    yaxis.deinit();

    // x axis padding
    if (self.x_axis.name) |_| {
        var xaxis_padding = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 1.0,
            .expand = .vertical,
            .min_size_content = .{ .w = x_axis_last_tick_width / 2 },
        });
        xaxis_padding.deinit();
    }

    // data area
    var data_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .role = .image,
        .label = .{ .text = self.init_options.title orelse "" },
    });

    // mouse hover
    if (self.init_options.mouse_hover) {
        const evts = dvui.events();
        for (evts) |*e| {
            if (!dvui.eventMatchSimple(e, data_box.data()))
                continue;

            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .position) {
                        dvui.cursorSet(.arrow);
                        self.mouse_point = me.p;
                    }
                },
                else => {},
            }
        }
    }

    yaxis_rect.h = data_box.data().rect.h;
    self.data_rs = data_box.data().contentRectScale();
    data_box.deinit();

    const bt: f32 = self.init_options.border_thick orelse 0.0;
    const bc: dvui.Color = self.init_options.spine_color orelse self.box.data().options.color(.text);

    const pad = 2 * self.data_rs.s;

    hbox1.deinit();

    var hbox2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });

    // bottom left corner under y axis
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(yaxis_rect.w), .expand = .vertical });

    var x_tick_height: f32 = 0;
    if (self.x_axis.name) |_| {
        if (self.x_axis.min != null or self.x_axis.max != null) {
            x_tick_height = tick_font.sizeM(1, 1).h;
        }
    }

    // x axis label
    var xaxis = dvui.box(@src(), .{}, .{
        .gravity_y = 1.0,
        .expand = .horizontal,
        .min_size_content = .{ .h = x_tick_height * 3 },
    });
    if (self.x_axis.name) |xname| {
        if (xname.len > 0) {
            dvui.label(@src(), "{s}", .{xname}, .{ .gravity_x = 0.5, .gravity_y = 1.0 });
        }
    }
    xaxis.deinit();

    _ = dvui.spacer(@src(), .{
        .min_size_content = .width(x_axis_last_tick_width / 2),
        .expand = .vertical,
    });

    hbox2.deinit();

    const tick_line_len = 5;
    const subtick_line_len = 3;

    // y axis ticks
    if (self.y_axis.name) |_| {
        for (yticks.values) |ytick| {
            const tick: Data = .{ .x = self.x_axis.min orelse 0, .y = ytick };
            const tick_str = self.y_axis.formatTick(dvui.currentWindow().lifo(), ytick) catch "";
            defer dvui.currentWindow().lifo().free(tick_str);
            const tick_str_size = tick_font.textSize(tick_str).scale(self.data_rs.s, Size.Physical);

            const tick_p = self.dataToScreen(tick);
            self.drawTickline(
                .vertical,
                tick_p,
                tick_line_len,
                self.y_axis.ticks.side,
                bc,
                self.y_axis.gridline_color,
            );

            var tick_label_p = tick_p;
            tick_label_p.x -= tick_str_size.w + pad;
            tick_label_p.y -= tick_str_size.h / 2;
            const tick_rs: RectScale = .{ .r = Rect.Physical.fromPoint(tick_label_p).toSize(tick_str_size), .s = self.data_rs.s };

            dvui.renderText(.{
                .font = tick_font,
                .text = tick_str,
                .rs = tick_rs,
                .color = self.box.data().options.color(.text),
            }) catch |err| {
                dvui.logError(@src(), err, "y axis tick text for {d}", .{ytick});
            };
        }

        for (yticks.subticks) |ytick| {
            const tick: Data = .{ .x = self.x_axis.min orelse 0, .y = ytick };
            const tick_p = self.dataToScreen(tick);
            self.drawTickline(
                .vertical,
                tick_p,
                subtick_line_len,
                self.y_axis.ticks.side,
                bc,
                self.y_axis.subtick_gridline_color,
            );
        }
    }

    // x axis ticks
    if (self.x_axis.name) |_| {
        for (xticks.values) |xtick| {
            const tick: Data = .{ .x = xtick, .y = self.y_axis.min orelse 0 };
            const tick_str = self.x_axis.formatTick(dvui.currentWindow().lifo(), xtick) catch "";
            defer dvui.currentWindow().lifo().free(tick_str);
            const tick_str_size = tick_font.textSize(tick_str).scale(self.data_rs.s, Size.Physical);

            const tick_p = self.dataToScreen(tick);
            self.drawTickline(
                .horizontal,
                tick_p,
                tick_line_len,
                self.x_axis.ticks.side,
                bc,
                self.x_axis.gridline_color,
            );

            var tick_label_p = tick_p;
            tick_label_p.x -= tick_str_size.w / 2;
            tick_label_p.y += pad;
            const tick_rs: RectScale = .{ .r = Rect.Physical.fromPoint(tick_label_p).toSize(tick_str_size), .s = self.data_rs.s };

            dvui.renderText(.{
                .font = tick_font,
                .text = tick_str,
                .rs = tick_rs,
                .color = self.box.data().options.color(.text),
            }) catch |err| {
                dvui.logError(@src(), err, "x axis tick text for {d}", .{xtick});
            };
        }

        for (xticks.subticks) |xtick| {
            const tick: Data = .{ .x = xtick, .y = self.y_axis.min orelse 0 };
            const tick_p = self.dataToScreen(tick);
            self.drawTickline(
                .horizontal,
                tick_p,
                subtick_line_len,
                self.x_axis.ticks.side,
                bc,
                self.x_axis.subtick_gridline_color,
            );
        }
    }

    if (bt > 0) {
        self.data_rs.r.stroke(.{}, .{ .thickness = bt * self.data_rs.s, .color = bc });
    }

    self.old_clip = dvui.clip(self.data_rs.r);
}

fn drawTickline(
    self: *PlotWidget,
    dir: dvui.enums.Direction,
    tick_p: dvui.Point.Physical,
    tick_line_len: f32,
    side: PlotWidget.Axis.TicklinesSide,
    tick_line_color: dvui.Color,
    gridline_color: ?dvui.Color,
) void {
    if (tick_p.x < self.data_rs.r.x or tick_p.x > self.data_rs.r.x + self.data_rs.r.w) return;
    if (tick_p.y < self.data_rs.r.y or tick_p.y > self.data_rs.r.y + self.data_rs.r.h) return;
    // these are the positions for ticks on the left or top
    const line_start, const line_end, const gridline_start, const gridline_end = switch (dir) {
        .horizontal => blk: {
            const start = dvui.Point.Physical{
                .x = tick_p.x,
                .y = self.data_rs.r.y + self.data_rs.r.h - tick_line_len,
            };
            const end = dvui.Point.Physical{
                .x = tick_p.x,
                .y = self.data_rs.r.y + self.data_rs.r.h,
            };

            const gridline_start = dvui.Point.Physical{
                .x = tick_p.x,
                .y = self.data_rs.r.y,
            };
            const gridline_end = dvui.Point.Physical{
                .x = tick_p.x,
                .y = self.data_rs.r.y + self.data_rs.r.h,
            };

            break :blk .{ start, end, gridline_start, gridline_end };
        },
        .vertical => blk: {
            const start = dvui.Point.Physical{
                .x = self.data_rs.r.x,
                .y = tick_p.y,
            };
            const end = dvui.Point.Physical{
                .x = self.data_rs.r.x + tick_line_len,
                .y = tick_p.y,
            };

            const gridline_start = dvui.Point.Physical{
                .x = self.data_rs.r.x,
                .y = tick_p.y,
            };
            const gridline_end = dvui.Point.Physical{
                .x = self.data_rs.r.x + self.data_rs.r.w,
                .y = tick_p.y,
            };

            break :blk .{ start, end, gridline_start, gridline_end };
        },
    };

    if (gridline_color) |col| {
        dvui.Path.stroke(.{
            .points = &.{ gridline_start, gridline_end },
        }, .{
            .color = col,
            .thickness = 1,
        });
    }

    const left_or_top_pts: []const dvui.Point.Physical = &.{ line_start, line_end };

    const off = switch (dir) {
        .horizontal => dvui.Point.Physical{ .x = 0, .y = -(self.data_rs.r.h - tick_line_len) },
        .vertical => dvui.Point.Physical{ .x = self.data_rs.r.w - tick_line_len, .y = 0 },
    };

    const right_or_bottom_pts: []const dvui.Point.Physical = &.{
        left_or_top_pts[0].plus(off),
        left_or_top_pts[1].plus(off),
    };

    switch (side) {
        .none => {},
        .left_or_top => {
            dvui.Path.stroke(.{ .points = left_or_top_pts }, .{
                .color = tick_line_color,
                .thickness = 1,
            });
        },
        .right_or_bottom => {
            dvui.Path.stroke(.{ .points = right_or_bottom_pts }, .{
                .color = tick_line_color,
                .thickness = 1,
            });
        },
        .both => {
            dvui.Path.stroke(.{ .points = left_or_top_pts }, .{
                .color = tick_line_color,
                .thickness = 1,
            });
            dvui.Path.stroke(.{ .points = right_or_bottom_pts }, .{
                .color = tick_line_color,
                .thickness = 1,
            });
        },
    }
}

pub fn line(self: *PlotWidget, name: []const u8) Line {
    // NOTE: Should not allocate Line as a stack widget. Line doesn't call `dvui.widgetFree`
    const result: Line = .{
        .plot = self,
        .path = dvui.Path.Builder.init(dvui.currentWindow().lifo()),
        .name = name,
        .color = dvui.Color.white,
    };
    self.items.?.append(.{ .name = name, .color = dvui.Color.white, .item_type = .line }) catch unreachable;
    return result;
}

pub fn scatter(self: *PlotWidget, name: []const u8) Scatter {
    // NOTE: Should not allocate Scatter as a stack widget. Scatter doesn't call `dvui.widgetFree`
    const result: Scatter = .{
        .plot = self,
        .points = std.array_list.Managed(Data).init(dvui.currentWindow().lifo()),
        .screen_points = std.array_list.Managed(dvui.Point.Physical).init(dvui.currentWindow().lifo()),
        .name = name,
        .color = dvui.Color.white,
    };
    self.items.?.append(.{ .name = name, .color = dvui.Color.white, .item_type = .scatter }) catch unreachable;
    return result;
}

pub fn area(self: *PlotWidget, name: []const u8) Area {
    // NOTE: Should not allocate Area as a stack widget. Area doesn't call `dvui.widgetFree`
    const result: Area = .{
        .plot = self,
        .path = dvui.Path.Builder.init(dvui.currentWindow().lifo()),
        .base_y = 0,
        .name = name,
        .color = dvui.Color.white,
    };
    self.items.?.append(.{ .name = name, .color = dvui.Color.white, .item_type = .area }) catch unreachable;
    return result;
}

pub fn legend(self: *PlotWidget) Legend {
    // NOTE: Should not allocate Legend as a stack widget. Legend doesn't call `dvui.widgetFree`
    return .{
        .plot = self,
        .items = std.array_list.Managed(Legend.LegendItem).init(dvui.currentWindow().lifo()),
    };
}

pub const BarOptions = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    name: []const u8 = "Bar",
    color: ?dvui.Color = null,
};

pub const Legend = struct {
    plot: *PlotWidget,
    items: std.array_list.Managed(LegendItem),

    pub const LegendItem = struct {
        label: []const u8,
        color: dvui.Color,
    };

    pub fn item(self: *Legend, label: []const u8, color: dvui.Color) void {
        self.items.append(.{ .label = label, .color = color }) catch unreachable;
    }

    pub fn draw(self: *Legend) void {
        // Auto-collect items from plot
        self.items.clearRetainingCapacity();
        if (self.plot.items) |plot_items| {
            for (plot_items.items) |plot_item| {
                self.items.append(.{ .label = plot_item.name, .color = plot_item.color }) catch unreachable;
            }
        }
        if (self.items.items.len == 0) return;

        const font = self.plot.box.data().options.fontGet();
        const text_color = self.plot.box.data().options.color(.text);
        const padding = dvui.Rect.all(8);
        const item_spacing = 4.0;
        const icon_size = dvui.Size.Natural{ .w = 16, .h = 12 };

        // Calculate legend size
        var max_width: f32 = 0;
        var total_height: f32 = 0;
        for (self.items.items) |legend_item| {
            const text_size = font.textSize(legend_item.label);
            max_width = @max(max_width, text_size.w + icon_size.w + 8);
            total_height += @max(text_size.h, icon_size.h) + item_spacing;
        }
        total_height -= item_spacing; // Remove last spacing

        // Position legend at top right of plot (physical coordinates)
        const legend_rect = dvui.Rect.Physical{
            .x = self.plot.data_rs.r.x + self.plot.data_rs.r.w - (max_width + padding.w + padding.x) * self.plot.data_rs.s,
            .y = self.plot.data_rs.r.y + (padding.y) * self.plot.data_rs.s,
            .w = (max_width + padding.w + padding.x) * self.plot.data_rs.s,
            .h = (total_height + padding.h + padding.y) * self.plot.data_rs.s,
        };

        // Draw background
        legend_rect.fill(dvui.Rect.Physical.all(0), .{ .color = self.plot.box.data().options.color(.fill) });
        legend_rect.stroke(.{}, .{ .thickness = 1 * self.plot.data_rs.s, .color = text_color });

        // Get mouse position
        const mouse_point = dvui.currentWindow().mouse_pt;

        // Draw items
        var current_y: f32 = legend_rect.y + (padding.y) * self.plot.data_rs.s;
        for (self.items.items, 0..) |legend_item, index| {
            const text_size = font.textSize(legend_item.label);
            const item_height = @max(text_size.h, icon_size.h) * self.plot.data_rs.s;

            // Calculate item rect for hover detection
            const item_rect = dvui.Rect.Physical{
                .x = legend_rect.x,
                .y = current_y,
                .w = legend_rect.w,
                .h = item_height + item_spacing * self.plot.data_rs.s,
            };

            // Check if mouse is hovering over this item
            const is_hovered = item_rect.contains(mouse_point);

            // Update hovered state in plot items
            if (self.plot.items) |plot_items| {
                if (index < plot_items.items.len) {
                    plot_items.items[index].hovered = is_hovered;
                }
            }

            // Generate unique ID for this legend item
            const base_id = self.plot.box.data().id;
            const legend_id = base_id.update("legend");
            const item_id = legend_id.update(legend_item.label);

            // Handle click events
            const evts = dvui.events();
            for (evts) |*e| {
                if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button == .left) {
                    if (item_rect.contains(e.evt.mouse.p)) {
                        // Get current visible state
                        const current_visible = dvui.dataGet(null, item_id, "visible", bool) orelse true;
                        // Toggle visible state
                        const new_visible = !current_visible;
                        // Save to data storage
                        dvui.dataSet(null, item_id, "visible", new_visible);
                    }
                }
            }

            // Get visible state from data storage
            const is_visible = dvui.dataGet(null, item_id, "visible", bool) orelse true;

            // Update plot item's visible state
            if (self.plot.items) |plot_items| {
                if (index < plot_items.items.len) {
                    plot_items.items[index].visible = is_visible;
                }
            }

            // Draw color icon
            const icon_scale: f32 = if (is_hovered) 1.2 else 1.0;
            const icon_rect = dvui.Rect.Physical{
                .x = legend_rect.x + (padding.x) * self.plot.data_rs.s,
                .y = current_y + (item_height - icon_size.h * self.plot.data_rs.s * icon_scale) / 2,
                .w = icon_size.w * self.plot.data_rs.s * icon_scale,
                .h = icon_size.h * self.plot.data_rs.s * icon_scale,
            };
            // Use gray color if item is not visible
            const icon_color = if (is_visible) legend_item.color else dvui.Color.gray;
            icon_rect.fill(dvui.Rect.Physical.all(0), .{ .color = icon_color });

            // Draw label
            const text_pos = dvui.Point.Physical{
                .x = icon_rect.x + icon_rect.w + 8 * self.plot.data_rs.s,
                .y = current_y + (item_height - text_size.h * self.plot.data_rs.s) / 2,
            };
            const text_rs = dvui.RectScale{
                .r = dvui.Rect.Physical.fromPoint(text_pos).toSize(text_size.scale(self.plot.data_rs.s, dvui.Size.Physical)),
                .s = self.plot.data_rs.s,
            };
            // Use gray color if item is not visible
            const label_color = if (is_visible) text_color else dvui.Color.gray;
            dvui.renderText(.{
                .font = font,
                .text = legend_item.label,
                .rs = text_rs,
                .color = label_color,
            }) catch |err| {
                dvui.logError(@src(), err, "Failed to render legend text", .{});
            };

            current_y += item_height + item_spacing * self.plot.data_rs.s;
        }
    }

    pub fn deinit(self: *Legend) void {
        self.items.deinit();
    }
};

pub fn isLegendItemHovered(self: *PlotWidget, item_name: []const u8) bool {
    // Get mouse position
    const mouse_point = dvui.currentWindow().mouse_pt;

    // Calculate legend position and size
    const font = self.box.data().options.fontGet();
    const padding = dvui.Rect.all(8);
    const item_spacing = 4.0;
    const icon_size = dvui.Size.Natural{ .w = 16, .h = 12 };

    // Calculate legend size
    var max_width: f32 = 0;
    var total_height: f32 = 0;
    if (self.items) |plot_items| {
        for (plot_items.items) |plot_item| {
            const text_size = font.textSize(plot_item.name);
            max_width = @max(max_width, text_size.w + icon_size.w + 8);
            total_height += @max(text_size.h, icon_size.h) + item_spacing;
        }
        total_height -= item_spacing; // Remove last spacing
    }

    // Position legend at top right of plot (physical coordinates)
    const legend_rect = dvui.Rect.Physical{
        .x = self.data_rs.r.x + self.data_rs.r.w - (max_width + padding.w + padding.x) * self.data_rs.s,
        .y = self.data_rs.r.y + (padding.y) * self.data_rs.s,
        .w = (max_width + padding.w + padding.x) * self.data_rs.s,
        .h = (total_height + padding.h + padding.y) * self.data_rs.s,
    };

    // Check if mouse is inside legend
    if (!legend_rect.contains(mouse_point)) {
        return false;
    }

    // Check which item is hovered
    var current_y: f32 = legend_rect.y + (padding.y) * self.data_rs.s;
    if (self.items) |plot_items| {
        for (plot_items.items) |plot_item| {
            const text_size = font.textSize(plot_item.name);
            const item_height = @max(text_size.h, icon_size.h) * self.data_rs.s;

            // Calculate item rect for hover detection
            const item_rect = dvui.Rect.Physical{
                .x = legend_rect.x,
                .y = current_y,
                .w = legend_rect.w,
                .h = item_height + item_spacing * self.data_rs.s,
            };

            // Check if mouse is hovering over this item
            if (item_rect.contains(mouse_point)) {
                // Check if this is the item we're looking for
                return std.mem.eql(u8, plot_item.name, item_name);
            }

            current_y += item_height + item_spacing * self.data_rs.s;
        }
    }

    return false;
}

pub fn bar(self: *PlotWidget, opts: BarOptions) void {
    const dp1 = Data{ .x = opts.x, .y = opts.y };
    const dp2 = Data{ .x = opts.x + opts.w, .y = opts.y + opts.h };

    self.dataForRange(dp1);
    self.dataForRange(dp2);

    const sp1 = self.dataToScreen(dp1);
    const sp2 = self.dataToScreen(dp2);

    if (self.mouse_point) |mp| {
        const smin: dvui.Point.Physical = .{ .x = @min(sp1.x, sp2.x), .y = @min(sp1.y, sp2.y) };
        const smax: dvui.Point.Physical = .{ .x = @max(sp1.x, sp2.x), .y = @max(sp1.y, sp2.y) };
        const srect = dvui.Rect.Physical{
            .x = smin.x,
            .y = smin.y,
            .w = smax.x - smin.x,
            .h = smax.y - smin.y,
        };
        if (srect.contains(mp)) {
            self.hover_data = .{ .bar = .{
                .x = opts.x,
                .y = opts.y,
                .w = opts.w,
                .h = opts.h,
            } };
        }
    }

    const color = opts.color orelse dvui.themeGet().focus;
    // Add bar to items if it's not already there, or update color if it exists
    var bar_exists = false;
    var is_visible = true;
    var is_hovered = false;
    if (self.items) |*items| {
        for (items.items) |*item| {
            if (std.mem.eql(u8, item.name, opts.name)) {
                item.color = color;
                // Get visible state from data storage
                const base_id = self.box.data().id;
                const legend_id = base_id.update("legend");
                const item_id = legend_id.update(opts.name);
                is_visible = dvui.dataGet(null, item_id, "visible", bool) orelse true;
                item.visible = is_visible;
                // Check if mouse is hovering over this item's legend
                is_hovered = self.isLegendItemHovered(opts.name);
                item.hovered = is_hovered;
                bar_exists = true;
                break;
            }
        }
        if (!bar_exists) {
            items.append(.{ .name = opts.name, .color = color, .item_type = .bar, .visible = true }) catch unreachable;
        }
    }

    // Only draw if visible
    if (is_visible) {
        // Increase size when hovered
        const hover_scale: f32 = if (is_hovered) 1.1 else 1.0;

        // Calculate center point
        const center_x = (sp1.x + sp2.x) / 2;
        const center_y = (sp1.y + sp2.y) / 2;

        // Calculate new points with hover scale
        const new_sp1 = dvui.Point.Physical{
            .x = center_x - (center_x - sp1.x) * hover_scale,
            .y = center_y - (center_y - sp1.y) * hover_scale,
        };
        const new_sp2 = dvui.Point.Physical{
            .x = center_x + (sp2.x - center_x) * hover_scale,
            .y = center_y + (sp2.y - center_y) * hover_scale,
        };

        dvui.Path.fillConvex(
            .{
                .points = &.{
                    new_sp1,
                    .{ .x = new_sp2.x, .y = new_sp1.y },
                    new_sp2,
                    .{ .x = new_sp1.x, .y = new_sp2.y },
                },
            },
            .{ .color = color },
        );
    }
}

pub fn deinit(self: *PlotWidget) void {
    const should_free = self.init_options.was_allocated_on_widget_stack;
    defer if (should_free) dvui.widgetFree(self);
    defer self.* = undefined;
    dvui.clipSet(self.old_clip);

    if (self.data_min.x == self.data_max.x) {
        self.data_min.x = self.data_min.x - 1;
        self.data_max.x = self.data_max.x + 1;
    }

    if (self.data_min.y == self.data_max.y) {
        self.data_min.y = self.data_min.y - 1;
        self.data_max.y = self.data_max.y + 1;
    }

    // maybe we got no data
    if (self.data_min.x == std.math.floatMax(f64)) {
        self.data_min = .{ .x = 0, .y = 0 };
        self.data_max = .{ .x = 10, .y = 10 };
    }

    if (self.init_options.x_axis) |x_axis| {
        if (x_axis.min == null) {
            x_axis.min = self.data_min.x;
        }
        if (x_axis.max == null) {
            x_axis.max = self.data_max.x;
        }
    } else {
        self.x_axis.min = self.data_min.x;
        self.x_axis.max = self.data_max.x;
        dvui.dataSet(null, self.box.data().id, "_x_axis", self.x_axis.*);
    }
    if (self.init_options.y_axis) |y_axis| {
        if (y_axis.min == null) {
            y_axis.min = self.data_min.y;
        }
        if (y_axis.max == null) {
            y_axis.max = self.data_max.y;
        }
    } else {
        self.y_axis.min = self.data_min.y;
        self.y_axis.max = self.data_max.y;
        dvui.dataSet(null, self.box.data().id, "_y_axis", self.y_axis.*);
    }

    if (self.hover_data) |hd| {
        switch (hd) {
            .point => |p| self.hoverLabel("{d}, {d}", .{ p.x, p.y }),
            .bar => |b| self.hoverLabel("{d} to {d}, {d} to {d}", .{ b.x, b.x + b.w, b.y, b.y + b.h }),
        }
    }

    // Draw legend if enabled
    if (self.legend_enabled and self.items != null and self.items.?.items.len > 0) {
        var l = self.legend();
        defer l.deinit();
        l.draw();
    }

    // Free items memory
    if (self.items) |*items| {
        items.deinit();
    }

    self.box.deinit();
}

fn hoverLabel(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    var p = self.box.data().contentRectScale().pointFromPhysical(self.mouse_point.?);
    const str = std.fmt.allocPrint(dvui.currentWindow().lifo(), fmt, args) catch "";
    // NOTE: Always calling free is safe because fallback is a 0 len slice, which is ignored
    defer dvui.currentWindow().lifo().free(str);
    const size: Size = (dvui.Options{}).fontGet().textSize(str);
    p.x -= size.w / 2;
    const padding = dvui.LabelWidget.defaults.paddingGet();
    p.y -= size.h + padding.y + padding.h + 8;
    dvui.label(@src(), fmt, args, .{ .rect = Rect.fromPoint(p), .background = true, .border = Rect.all(1), .margin = .{} });
}

const Options = dvui.Options;
const Point = dvui.Point;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Size = dvui.Size;

const BoxWidget = dvui.BoxWidget;

const std = @import("std");
const dvui = @import("../dvui.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
