const std = @import("std");
//const stdout = @import("std").io.getStdOut().writer();
const pa = @import("pa.zig");
const c = @cImport({
    @cInclude("gtk/gtk.h");
});

const print = std.debug.print;

var TheGTK = GTK{};

pub const GTK = struct {
    err: [*c][*c]c.GError = null,
    pat: ?*c.cairo_pattern_t = null,
    window: [*c]c.GObject = null,
    butQuit: [*c]c.GObject = null,
    drawFFT: [*c]c.GObject = null,
    drawFall: [*c]c.GObject = null,
    cbtIn: [*c]c.GObject = null,
    cbtOut: [*c]c.GObject = null,
    butPlay: [*c]c.GObject = null,
    butStop: [*c]c.GObject = null,
    drawLOn: [*c]c.GObject = null,
    drawLOff: [*c]c.GObject = null,
    bLedOnState: bool = false,
    bLedOffState: bool = true,

    bEvKillThread: bool = false,
    bThreadRunning: bool = false,
    theThread: [*c]c.GThread = null,

    thePA: *pa.PA = undefined,
    DevPair: [2]i32 = .{ -1, -1 },
    DrawingDataRaw: [1024]f32 = .{0} ** 1024,
    DrawingDataMod: [1024]f32 = .{0.02} ** 1024,
    miEvent: std.Thread.ResetEvent = std.Thread.ResetEvent{},

    pub fn Init(paptr: *pa.PA) *GTK {
        c.gtk_init(0, null);

        const builderDecl = @embedFile("./pa1.glade");
        const bdp: [*c]const u8 = builderDecl;
        const builder: *c.GtkBuilder = c.gtk_builder_new();
        const err: [*c][*c]c.GError = null;
        if (c.gtk_builder_add_from_string(builder, bdp, builderDecl.len, err) == 0) {
            c.g_printerr("Error loading embedded builder: %s\n", err.*.*.message);
            TheGTK.err = err;
            return &TheGTK;
        }

        const pat = c.cairo_pattern_create_linear(0.0, 0.0, 0.0, 1.0);
        c.cairo_pattern_add_color_stop_rgb(pat, 0.2, 1, 0, 0);
        c.cairo_pattern_add_color_stop_rgb(pat, 0.35, 1, 1, 0);
        c.cairo_pattern_add_color_stop_rgb(pat, 0.65, 0, 1, 0);

        const window = c.gtk_builder_get_object(builder, "miWindow");
        const butQuit = c.gtk_builder_get_object(builder, "miQuit");
        const drawFFT = c.gtk_builder_get_object(builder, "miLienzoFFT");
        const drawFall = c.gtk_builder_get_object(builder, "miLienzoFall");
        const cbtIn = c.gtk_builder_get_object(builder, "miCBTIn");
        const cbtOut = c.gtk_builder_get_object(builder, "miCBTOut");
        const butPlay = c.gtk_builder_get_object(builder, "miPlay");
        const butStop = c.gtk_builder_get_object(builder, "miStop");
        const drawLOn = c.gtk_builder_get_object(builder, "miLedOn");
        const drawLOff = c.gtk_builder_get_object(builder, "miLedOff");

        TheGTK.err = err;
        TheGTK.pat = pat;
        TheGTK.window = window;
        TheGTK.butQuit = butQuit;
        TheGTK.drawFall = drawFall;
        TheGTK.drawFFT = drawFFT;
        TheGTK.cbtIn = cbtIn;
        TheGTK.cbtOut = cbtOut;
        TheGTK.butPlay = butPlay;
        TheGTK.butStop = butStop;
        TheGTK.drawLOn = drawLOn;
        TheGTK.drawLOff = drawLOff;

        TheGTK.thePA = paptr;
        return &TheGTK;
    }

    pub fn RunMain(self: *GTK) void {
        const negro: c.GdkColor = c.GdkColor{ .pixel = 0, .red = 0x0000, .green = 0x0000, .blue = 0x0000 };
        c.gtk_widget_modify_bg(@as(*c.GtkWidget, @ptrCast(self.window)), c.GTK_STATE_NORMAL, &negro);

        const theListDev = self.thePA.GetDevices();
        for (0..theListDev.len) |n| {
            const dev = theListDev.get(n);

            var ptr: [*c]c.GtkComboBoxText = @ptrCast(self.cbtIn);
            if (dev.maxInputChannels > 0) c.gtk_combo_box_text_append_text(ptr, dev.name);

            ptr = @ptrCast(self.cbtOut);
            if (dev.maxOutputChannels > 0) c.gtk_combo_box_text_append_text(ptr, dev.name);
        }

        const cssProvider: [*c]c.GtkCssProvider = c.gtk_css_provider_new();
        _ = c.gtk_css_provider_load_from_path(cssProvider, "theme.css", 0);
        const styleProvider: *c.GtkStyleProvider = @ptrCast(cssProvider);
        c.gtk_style_context_add_provider_for_screen(c.gdk_screen_get_default(), styleProvider, c.GTK_STYLE_PROVIDER_PRIORITY_USER);

        SignalConnect(self.window, "destroy", @ptrCast(&dlgCbTerminate), self);
        SignalConnect(self.butQuit, "clicked", @ptrCast(&butCbTerminate), self);
        SignalConnect(self.drawFFT, "draw", @ptrCast(&DrawFFT), self);
        SignalConnect(self.drawFall, "draw", @ptrCast(&DrawFall), self);
        SignalConnect(self.cbtIn, "changed", @ptrCast(&inoutCbChanged), self);
        SignalConnect(self.cbtOut, "changed", @ptrCast(&inoutCbChanged), self);
        SignalConnect(self.butPlay, "clicked", @ptrCast(&butCbPlay), self);
        SignalConnect(self.butStop, "clicked", @ptrCast(&butCbStop), self);
        SignalConnect(self.drawLOn, "draw", @ptrCast(&DrawLOn), self);
        SignalConnect(self.drawLOff, "draw", @ptrCast(&DrawLOff), self);

        c.gtk_widget_set_sensitive(@ptrCast(self.butPlay), 0);

        c.gtk_main();

        return;
    }

    fn SignalConnect(instance: [*c]c.GObject, detailed_signal: [*c]const c.gchar, c_handler: c.GCallback, data: c.gpointer) void {
        _ = c.g_signal_connect_data(instance, detailed_signal, c_handler, data, null, 0);

        return;
    }

    fn UpdatingThread(self: *GTK) void {
        c.g_usleep(50_100);
        self.bThreadRunning = true;
        c.g_print("bThreadRunning: %d\n", self.bThreadRunning);

        while (!self.bEvKillThread) {
            //c.g_usleep(70_000);
            //self.miEvent.timedWait(30_000_000) catch continue;
            self.miEvent.timedWait(10_000_000) catch continue;
            self.miEvent.reset();
            if (self.thePA.GetInputdata(&self.DrawingDataRaw, &self.DrawingDataMod)) {
                c.gtk_widget_queue_draw(@ptrCast(self.drawFFT));
                c.gtk_widget_queue_draw(@ptrCast(self.drawFall));
            } else self.miEvent.set();
        }

        self.DrawingDataRaw = .{0.0} ** 1024;
        self.DrawingDataMod = .{0.02} ** 1024;
        c.gtk_widget_queue_draw(@ptrCast(self.drawFFT));
        c.gtk_widget_queue_draw(@ptrCast(self.drawFall));

        c.g_print("bEvKillThread: %d\n", self.bEvKillThread);
        self.bThreadRunning = false;
        var zero: u8 = 0;
        c.g_thread_exit(@as(c.gpointer, &zero));
    }

    fn dlgCbTerminate(_: [*]c.GtkWidget, ptrSelf: c.gpointer) void {
        const self: *GTK = @ptrCast(@alignCast(ptrSelf));
        self.Terminate();
    }

    fn butCbTerminate(_: [*]c.GtkButton, ptrSelf: c.gpointer) void {
        const self: *GTK = @ptrCast(@alignCast(ptrSelf));
        self.Terminate();
    }

    fn Terminate(self: *GTK) void {
        if (self.bThreadRunning) {
            self.bEvKillThread = true;
            _ = c.g_thread_join(self.theThread);
        }
        _ = c.gtk_main_quit();

        return;
    }

    fn butCbPlay(_: [*]c.GtkButton, ptrSelf: c.gpointer) void {
        const self: *GTK = @ptrCast(@alignCast(ptrSelf));

        if (!self.bThreadRunning) {
            self.bEvKillThread = false;
            self.thePA.Start();
            self.theThread = c.g_thread_new("updating", @as(c.GThreadFunc, @ptrCast(&UpdatingThread)), self);
            self.miEvent.set();
            c.gtk_widget_set_sensitive(@ptrCast(self.butPlay), 0);
            c.gtk_widget_set_sensitive(@ptrCast(self.cbtIn), 0);
            c.gtk_widget_set_sensitive(@ptrCast(self.cbtOut), 0);
        }
        // ??
        //        c.gtk_widget_set_sensitive(@ptrCast(self.butPlay), 0);
        //        c.gtk_widget_set_sensitive(@ptrCast(self.cbtIn), 0);
        //        c.gtk_widget_set_sensitive(@ptrCast(self.cbtOut), 0);
    }

    fn butCbStop(_: [*]c.GtkButton, ptrSelf: c.gpointer) void {
        const self: *GTK = @ptrCast(@alignCast(ptrSelf));

        if (self.bThreadRunning) {
            self.bEvKillThread = true;
            _ = c.g_thread_join(self.theThread);
            self.thePA.Stop();
            self.miEvent.reset();
            c.gtk_widget_set_sensitive(@ptrCast(self.cbtIn), 1);
            c.gtk_widget_set_sensitive(@ptrCast(self.cbtOut), 1);
        }

        if (self.GetReadyToPlay()) {
            c.gtk_widget_set_sensitive(@ptrCast(self.butPlay), 1);
        }
    }

    fn DrawFall(widget: [*c]c.GtkWidget, cr: *c.cairo_t, ptrSelf: c.gpointer) c.gboolean {
        const width: f64 = @floatFromInt(c.gtk_widget_get_allocated_width(widget));
        const height: f64 = @floatFromInt(c.gtk_widget_get_allocated_height(widget));

        const context = c.gtk_widget_get_style_context(widget);
        c.gtk_render_background(context, cr, 0, 0, width, height);

        const self: *GTK = @ptrCast(@alignCast(ptrSelf));
        //        if (!self.bThreadRunning) return c.FALSE;

        c.cairo_scale(cr, width, height);
        c.cairo_set_source_rgba(cr, 0.4, 0.8, 0, 0.8);
        c.cairo_set_line_width(cr, 0.005);

        var i: f64 = 0;
        const DIVISIONES: f64 = 1024;
        const INC = 1 / DIVISIONES;

        const K: f64 = 1.8;
        const R: f64 = 0.15;
        var m: f64 = 0.0;
        var fi: f64 = 0.0;
        var x: f64 = R;
        var y: f64 = 0;

        c.cairo_translate(cr, 0.5, 0.5);
        c.cairo_move_to(cr, K * (x + self.DrawingDataRaw[0]), 0.0);

        var pos: usize = 0.0;
        i = 0;
        while (i < 1) : ({
            pos += 1;
            i += INC;
            fi = i * 2 * std.math.pi;
        }) {
            m = R + self.DrawingDataRaw[pos];
            x = K * m * std.math.cos(fi);
            y = -K * m * std.math.sin(fi);
            c.cairo_line_to(cr, x, y);
        }
        c.cairo_line_to(cr, K * (0.15 + self.DrawingDataRaw[0]), 0.0);
        c.cairo_stroke(cr);

        self.miEvent.set();

        return c.FALSE;
    }

    fn DrawFFT(widget: [*c]c.GtkWidget, cr: *c.cairo_t, ptrSelf: c.gpointer) c.gboolean {
        const width: f64 = @floatFromInt(c.gtk_widget_get_allocated_width(widget));
        const height: f64 = @floatFromInt(c.gtk_widget_get_allocated_height(widget));

        const context = c.gtk_widget_get_style_context(widget);
        c.gtk_render_background(context, cr, 0, 0, width, height);

        const self: *GTK = @ptrCast(@alignCast(ptrSelf));
        //        if (!self.bThreadRunning) return c.FALSE;

        c.cairo_scale(cr, width, height);

        c.cairo_set_source(cr, self.pat);

        var i: f64 = 0;
        const DIVISIONES: f64 = 64; // si quiero visualizar hasta 22Khz => max 512 divs, si quiero hasta 11KHz => max 256 divs, y asi
        const INC = 1 / DIVISIONES;
        const SEP_MIN: f64 = INC / 4;
        const ANCHO_MAX = INC - SEP_MIN;
        const ANCHO: f64 = if (ANCHO_MAX > 0.1) 0.1 else ANCHO_MAX;

        var pos: usize = 0;
        const POS_INC: usize = @intFromFloat(1024 / 16 / DIVISIONES); // 22 Khz => 1024/2,    si 11KHz => 1024/4
        while (i < 1) : ({
            //pos += 8;
            //i += INC * 2;
            pos += POS_INC;
            i += INC;
        }) {
            c.cairo_rectangle(cr, i, 1.0, ANCHO, -self.DrawingDataMod[pos]);
        }
        c.cairo_fill(cr);

        return c.FALSE;
    }

    fn DrawLOn(widget: [*c]c.GtkWidget, cr: *c.cairo_t, ptrSelf: c.gpointer) c.gboolean {
        const self: *GTK = @ptrCast(@alignCast(ptrSelf));

        DrawLed(widget, cr, false, self.bLedOnState);

        return c.FALSE;
    }

    fn DrawLOff(widget: [*c]c.GtkWidget, cr: *c.cairo_t, ptrSelf: c.gpointer) c.gboolean {
        const self: *GTK = @ptrCast(@alignCast(ptrSelf));

        DrawLed(widget, cr, true, self.bLedOffState);
        return c.FALSE;
    }

    fn DrawLed(widget: [*c]c.GtkWidget, cr: *c.cairo_t, red: bool, on: bool) void {
        const width: f64 = @floatFromInt(c.gtk_widget_get_allocated_width(widget));
        const height: f64 = @floatFromInt(c.gtk_widget_get_allocated_height(widget));

        c.cairo_scale(cr, width, height);

        //c.cairo_set_line_width(cr, 0.08);
        c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.3);
        c.cairo_arc(cr, 0.50, 0.50, 0.50, 0, 2 * c.G_PI);
        //c.cairo_stroke_preserve(cr);
        c.cairo_fill(cr);

        const intens: f64 = if (on) 1.0 else 0.25;
        const mired: f64 = if (red) intens else 0;
        const migreen: f64 = if (!red) 0.7 * intens else 0.05;
        c.cairo_set_source_rgb(cr, mired, migreen, 0.05);
        c.cairo_arc(cr, 0.50, 0.50, 0.35, 0, 2 * c.G_PI);
        c.cairo_fill(cr);

        c.cairo_translate(cr, 0.4, 0.4);
        c.cairo_rotate(cr, -c.G_PI / 4);
        c.cairo_scale(cr, 1.5, 1);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.25);
        c.cairo_arc(cr, 0, 0, 0.1, 0, 2 * c.G_PI);
        c.cairo_fill(cr);

        return;
    }

    fn inoutCbChanged(cbt: [*c]c.GtkComboBox, ptrSelf: c.gpointer) void {
        const self: *GTK = @ptrCast(@alignCast(ptrSelf));
        const in = self.getIndexFromCBT(cbt);

        const ptrW: [*c]c.GtkWidget = @ptrCast(cbt);
        const name: [*:0]u8 = @constCast(c.gtk_widget_get_name(ptrW));
        const result = std.mem.orderZ(u8, name, "In");
        if (result == .eq) self.DevPair[0] = in else self.DevPair[1] = in;

        if (self.GetReadyToPlay()) {
            c.gtk_widget_set_sensitive(@ptrCast(self.butPlay), 1);

            self.bLedOnState = true;
            self.bLedOffState = false;
            c.gtk_widget_queue_draw(@ptrCast(self.drawLOn));
            c.gtk_widget_queue_draw(@ptrCast(self.drawLOff));
        } else c.gtk_widget_set_sensitive(@ptrCast(self.butPlay), 0);
    }

    fn getIndexFromCBT(self: *GTK, cbt: [*c]c.GtkComboBox) i32 {
        const myPtr: [*c]c.GtkComboBoxText = @ptrCast(cbt);
        const text: [*:0]u8 = c.gtk_combo_box_text_get_active_text(myPtr);
        defer c.g_free(text);

        const theListDev = self.thePA.GetDevices();

        for (0..theListDev.len) |n| {
            const dev = theListDev.get(n);
            const result = std.mem.orderZ(u8, text, dev.name);
            if (result == .eq) return @intCast(n);
        }

        return -1;
    }

    fn GetReadyToPlay(self: *GTK) bool {
        if (self.DevPair[0] != -1 and self.DevPair[1] != -1) {
            return TheGTK.thePA.CheckCompatibility(self.DevPair[0], self.DevPair[1]);
        } else return false;
    }
};
