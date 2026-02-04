/// ![image](Examples-plots.png)
pub fn plots() void {
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        dvui.label(@src(), "Simple", .{}, .{});

        const xs: []const f64 = &.{ 0, 1, 2, 3, 4, 5 };
        const ys: []const f64 = &.{ 0, 4, 2, 6, 5, 9 };
        dvui.plotXY(@src(), .{ .xs = xs, .ys = ys }, .{});
    }

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        dvui.label(@src(), "Color and Thick", .{}, .{});

        const xs: []const f64 = &.{ 0, 1, 2, 3, 4, 5 };
        const ys: []const f64 = &.{ 9, 5, 6, 2, 4, 0 };
        dvui.plotXY(@src(), .{ .thick = 2, .xs = xs, .ys = ys, .color = dvui.themeGet().err.fill orelse .red }, .{});
    }

    var save: ?enum { png, jpg } = null;
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();
        if (dvui.button(@src(), "Save png", .{}, .{})) {
            save = .png;
        }
        if (dvui.button(@src(), "Save jpg", .{}, .{})) {
            save = .jpg;
        }
    }

    {
        var vbox = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 300, .h = 100 }, .expand = .ratio });
        defer vbox.deinit();

        var pic: ?dvui.Picture = null;
        if (save != null) {
            pic = dvui.Picture.start(vbox.data().contentRectScale().r);
        }

        const Static = struct {
            var xaxis: dvui.PlotWidget.Axis = .{
                .name = "X Axis",
                .min = 0.05,
                .max = 0.95,
                .ticks = .{
                    .side = .left_or_top,
                    .subticks = true,
                },
                .gridline_color = gridline_color,
            };

            var yaxis: dvui.PlotWidget.Axis = .{
                .name = "Y Axis",
                // let plot figure out min
                .max = 0.8,
                .ticks = .{
                    .side = .both,
                },
                .gridline_color = gridline_color,
            };
        };

        var plot = dvui.plot(@src(), .{
            .title = "Plot Title",
            .x_axis = &Static.xaxis,
            .y_axis = &Static.yaxis,
            .border_thick = 1.0,
            .mouse_hover = true,
            .legend_enabled = true,
        }, .{ .expand = .both });
        defer plot.deinit();

        var s1 = plot.line("Sine Wave");
        defer s1.deinit();

        const points: usize = 1000;
        const freq: f32 = 5;
        for (0..points + 1) |i| {
            const fval: f64 = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(points)) * freq);
            s1.point(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(points)), fval);
        }
        s1.stroke(1, dvui.themeGet().focus);

        if (pic) |*p| {
            // `save` is not null because `pic` is not null
            p.stop();
            defer p.deinit();

            const filename: []const u8 = switch (save.?) {
                .png => "plot.png",
                .jpg => "plot.jpg",
            };

            if (dvui.backend.kind == .web) blk: {
                const min_buffer_size = @max(dvui.PNGEncoder.min_buffer_size, dvui.JPGEncoder.min_buffer_size);
                var writer = std.Io.Writer.Allocating.initCapacity(dvui.currentWindow().arena(), min_buffer_size) catch |err| {
                    dvui.logError(@src(), err, "Failed to init writer for plot {t} image", .{save.?});
                    break :blk;
                };
                defer writer.deinit();
                (switch (save.?) {
                    .png => p.png(&writer.writer),
                    .jpg => p.jpg(&writer.writer),
                }) catch |err| {
                    dvui.logError(@src(), err, "Failed to write plot {t} image", .{save.?});
                    break :blk;
                };
                // No need to call `writer.flush` because `Allocating` doesn't drain it's buffer anywhere
                dvui.backend.downloadData(filename, writer.written()) catch |err| {
                    dvui.logError(@src(), err, "Could not download {s}", .{filename});
                };
            } else if (!dvui.useTinyFileDialogs) {
                dvui.toast(@src(), .{ .message = "Tiny File Dilaogs disabled" });
            } else {
                const maybe_path = dvui.dialogNativeFileSave(dvui.currentWindow().lifo(), .{ .path = filename }) catch null;
                if (maybe_path) |path| blk: {
                    defer dvui.currentWindow().lifo().free(path);

                    var file = std.fs.createFileAbsoluteZ(path, .{}) catch |err| {
                        dvui.log.debug("Failed to create file {s}, got {any}", .{ path, err });
                        dvui.toast(@src(), .{ .message = "Failed to create file" });
                        break :blk;
                    };
                    defer file.close();

                    var buffer: [256]u8 = undefined;
                    var writer = file.writer(&buffer);

                    (switch (save.?) {
                        .png => p.png(&writer.interface),
                        .jpg => p.jpg(&writer.interface),
                    }) catch |err| {
                        dvui.logError(@src(), err, "Failed to write plot {t} to file {s}", .{ save.?, path });
                    };
                    // End writing to file and potentially truncate any additional preexisting data
                    writer.end() catch |err| {
                        dvui.logError(@src(), err, "Failed to end file write for {s}", .{path});
                    };
                }
            }
        }
    }

    {
        const S = struct {
            var resistance: f64 = 159;
            var capacitance: f64 = 1e-6;

            var xaxis: dvui.PlotWidget.Axis = .{
                .name = "Frequency",
                .scale = .{ .log = .{} },
                .ticks = .{
                    .format = .{
                        .custom = formatFrequency,
                    },
                    .subticks = true,
                },
                .gridline_color = gridline_color,
                .subtick_gridline_color = subtick_gridline_color,
            };

            var yaxis: dvui.PlotWidget.Axis = .{
                .name = "Amplitude (dB)",
                .max = 10,
                .ticks = .{
                    .locations = .{
                        .auto = .{ .tick_num_suggestion = 10 },
                    },
                },
                .gridline_color = gridline_color,
            };
        };

        dvui.label(@src(), "Resistance (Ohm)", .{}, .{});
        const r_res = dvui.textEntryNumber(@src(), f64, .{
            .value = &S.resistance,
            .min = std.math.floatMin(f64),
        }, .{});

        dvui.label(@src(), "Capacitance (Farad)", .{}, .{});
        const c_res = dvui.textEntryNumber(@src(), f64, .{
            .value = &S.capacitance,
            .min = std.math.floatMin(f64),
        }, .{});

        const valid = r_res.value == .Valid and c_res.value == .Valid;

        const cutoff_angular_freq = 1 / (S.resistance * S.capacitance);

        dvui.label(@src(), "Cutoff frequency: {:.2} Hz", .{cutoff_angular_freq / (2 * std.math.pi)}, .{});

        var vbox = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 300, .h = 100 }, .expand = .ratio });
        defer vbox.deinit();

        var plot = dvui.plot(@src(), .{
            .title = "RC low-pass filter",
            .x_axis = &S.xaxis,
            .y_axis = &S.yaxis,
            .border_thick = 2.0,
            .mouse_hover = true,
            .legend_enabled = true,
        }, .{ .expand = .both });
        defer plot.deinit();

        var s1 = plot.line("Amplitude");
        defer s1.deinit();

        const start_exp: f64 = 0;
        const end_exp: f64 = 8;
        const points: usize = 1000;
        const step: f64 = (end_exp - start_exp) / @as(f64, @floatFromInt(points));

        for (0..points) |i| {
            const exp = start_exp + step * @as(f64, @floatFromInt(i));

            const freq: f64 = std.math.pow(f64, 10, exp);
            const angular_freq: f64 = 2 * std.math.pi * freq;

            const tmp = angular_freq * S.resistance * S.capacitance;
            const amplitude = std.math.sqrt(1 / (1 + tmp * tmp));
            const amplitude_db: f64 = 20 * @log10(amplitude);
            s1.point(freq, amplitude_db);
        }
        s1.stroke(1, if (valid) dvui.themeGet().focus else dvui.Color.red);
    }

    {
        const S = struct {
            var stddev: f64 = 1.0;
            var mean: f64 = 0;
            var prng_seed: u64 = 2807233815221062137;
            var npoints: u32 = 64;
        };

        const Static = struct {
            var xaxis: dvui.PlotWidget.Axis = .{
                .name = "Value",
                .ticks = .{
                    .locations = .{
                        .auto = .{ .tick_num_suggestion = 9 },
                    },
                },
                .min = -2,
                .max = 2,
            };

            var yaxis: dvui.PlotWidget.Axis = .{
                .name = "Count",
                .ticks = .{
                    .locations = .{
                        .auto = .{ .tick_num_suggestion = 6 },
                    },
                },
                .max = 0,
            };
        };

        dvui.label(@src(), "Standard Deviation", .{}, .{});
        const s_res = dvui.textEntryNumber(@src(), f64, .{
            .value = &S.stddev,
        }, .{});

        dvui.label(@src(), "Mean", .{}, .{});
        const m_res = dvui.textEntryNumber(@src(), f64, .{
            .value = &S.mean,
        }, .{});

        dvui.label(@src(), "PRNG Seed", .{}, .{});
        const seed_res = dvui.textEntryNumber(@src(), u64, .{
            .value = &S.prng_seed,
        }, .{});

        dvui.label(@src(), "Number of Points", .{}, .{});
        const npoints_res = dvui.textEntryNumber(@src(), u32, .{
            .value = &S.npoints,
            .min = 1,
            .max = 100_000,
        }, .{});

        const valid = s_res.value == .Valid and m_res.value == .Valid and seed_res.value == .Valid and npoints_res.value == .Valid;

        var vbox = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 300, .h = 100 }, .expand = .ratio });
        defer vbox.deinit();

        var default_prng: std.Random.DefaultPrng = .init(S.prng_seed);
        const prng = default_prng.random();

        var histogram: [64]f64 = undefined;
        @memset(histogram[0..], 0);

        Static.yaxis.max.? = 0;

        const scalar = @as(f64, @floatFromInt(histogram.len)) / (Static.xaxis.max.? - Static.xaxis.min.?);
        for (0..S.npoints) |_| {
            const val = prng.floatNorm(f64) * S.stddev + S.mean;
            if (val < Static.xaxis.min.? or val >= Static.xaxis.max.?) continue;

            const bin: usize = @intFromFloat((val - Static.xaxis.min.?) * scalar);
            histogram[bin] += 1;
            Static.yaxis.max.? = @max(Static.yaxis.max.?, histogram[bin]);
        }

        var plot = dvui.plot(@src(), .{
            .title = "Random Normal Values",
            .x_axis = &Static.xaxis,
            .y_axis = &Static.yaxis,
            .border_thick = 2.0,
            .mouse_hover = true,
            .legend_enabled = true,
        }, .{ .expand = .both });
        defer plot.deinit();

        const bar_width = (Static.xaxis.max.? - Static.xaxis.min.?) / @as(f64, @floatFromInt(histogram.len));
        for (histogram, 0..) |count, i| {
            const val = Static.xaxis.min.? + @as(f64, @floatFromInt(i)) * bar_width;
            plot.bar(.{
                .x = val,
                .y = 0,
                .w = bar_width,
                .h = count,
                .color = if (valid) dvui.themeGet().focus else dvui.Color.red,
            });
        }
    }

    // Scatter plot example
    {
        const Static = struct {
            var xaxis: dvui.PlotWidget.Axis = .{ .name = "X" };
            var yaxis: dvui.PlotWidget.Axis = .{ .name = "Y" };
        };

        var vbox = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 300, .h = 100 }, .expand = .ratio });
        defer vbox.deinit();

        var plot = dvui.plot(@src(), .{
            .title = "Scatter Plot",
            .x_axis = &Static.xaxis,
            .y_axis = &Static.yaxis,
            .border_thick = 1.0,
            .mouse_hover = true,
            .legend_enabled = true,
        }, .{ .expand = .both });
        defer plot.deinit();

        var scatter = plot.scatter("Random Points");
        defer scatter.deinit();

        // Generate random scatter points
        var default_prng: std.Random.DefaultPrng = .init(42);
        const prng = default_prng.random();

        for (0..50) |i| {
            const x = @as(f64, @floatFromInt(i)) / 49.0;
            const y = prng.floatNorm(f64) * 0.2 + x * x;
            scatter.point(x, y);
        }

        scatter.draw(3, dvui.themeGet().focus);
    }

    // Area plot example
    {
        const Static = struct {
            var xaxis: dvui.PlotWidget.Axis = .{ .name = "X" };
            var yaxis: dvui.PlotWidget.Axis = .{ .name = "Y" };
        };

        var vbox = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 300, .h = 100 }, .expand = .ratio });
        defer vbox.deinit();

        var plot = dvui.plot(@src(), .{
            .title = "Area Plot",
            .x_axis = &Static.xaxis,
            .y_axis = &Static.yaxis,
            .border_thick = 1.0,
            .mouse_hover = true,
            .legend_enabled = true,
        }, .{ .expand = .both });
        defer plot.deinit();

        var area = plot.area("Sine Wave");
        defer area.deinit();

        // Generate sine wave data
        const points: usize = 100;
        for (0..points) |i| {
            const x = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(points - 1));
            const y = 0.5 * @sin(2.0 * std.math.pi * x * 3) + 0.5;
            area.point(x, y);
        }

        // Set base to 0 and fill
        const area_color = dvui.Color.fromHSLuv(200, 80, 60, 50);
        const area_border_color = dvui.Color.fromHSLuv(200, 80, 60, 100);
        area.setBase(0);
        area.fill(area_color);
        area.stroke(1, area_border_color);
    }

    // Multi-series plot with legend
    {
        const Static = struct {
            var xaxis: dvui.PlotWidget.Axis = .{ .name = "X" };
            var yaxis: dvui.PlotWidget.Axis = .{ .name = "Y" };
        };

        var vbox = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 300, .h = 100 }, .expand = .ratio });
        defer vbox.deinit();

        var plot = dvui.plot(@src(), .{
            .title = "Multi-series Plot",
            .x_axis = &Static.xaxis,
            .y_axis = &Static.yaxis,
            .border_thick = 1.0,
            .mouse_hover = true,
            .legend_enabled = true,
        }, .{ .expand = .both });
        defer plot.deinit();

        // Add sine wave
        var sine_line = plot.line("Sine");
        defer sine_line.deinit();
        const sine_color = dvui.Color.fromHSLuv(0, 80, 60, 100);

        const points: usize = 100;
        for (0..points) |i| {
            const x = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(points - 1)) * 10;
            const y = @sin(x);
            sine_line.point(x, y);
        }
        sine_line.stroke(2, sine_color);

        // Add cosine wave
        var cosine_line = plot.line("Cosine");
        defer cosine_line.deinit();
        const cosine_color = dvui.Color.fromHSLuv(200, 80, 60, 100);

        for (0..points) |i| {
            const x = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(points - 1)) * 10;
            const y = @cos(x);
            cosine_line.point(x, y);
        }
        cosine_line.stroke(2, cosine_color);
    }
}

fn formatFrequency(gpa: std.mem.Allocator, freq: f64) ![]const u8 {
    const exp = @log10(freq);
    const rounded_exp = std.math.round(exp);

    const val = std.math.pow(f64, 10, rounded_exp);

    if (rounded_exp < 3) {
        return try std.fmt.allocPrint(gpa, "{d:.0} Hz", .{val});
    } else if (rounded_exp < 6) {
        return try std.fmt.allocPrint(gpa, "{d:.0} kHz", .{val / 1e3});
    } else if (rounded_exp < 9) {
        return try std.fmt.allocPrint(gpa, "{d:.0} MHz", .{val / 1e6});
    } else {
        return try std.fmt.allocPrint(gpa, "{d:.0} GHz", .{val / 1e9});
    }
}

const gridline_color = dvui.Color.fromHSLuv(0, 0, 50, 90);
const subtick_gridline_color = dvui.Color.fromHSLuv(0, 0, 30, 70);

test {
    @import("std").testing.refAllDecls(@This());
}

test "DOCIMG plots" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 500, .h = 300 } });
    defer t.deinit();

    const frame = struct {
        fn frame() !dvui.App.Result {
            var box = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .style = .window });
            defer box.deinit();
            plots();
            return .ok;
        }
    }.frame;

    try dvui.testing.settle(frame);
    try t.saveImage(frame, null, "Examples-plots.png");
}

const std = @import("std");
const dvui = @import("../dvui.zig");
