const std = @import("std");
const assert = @import("std").debug.assert;

const fft = @import("fft.zig");

const stdout = @import("std").io.getStdOut().writer();
const c = @cImport({
    @cInclude("portaudio.h");
});

pub const DIList = std.MultiArrayList(c.PaDeviceInfo);
const SyncObj = struct {
    theMutex: std.Thread.Mutex = std.Thread.Mutex{},

    fn Block(self: *SyncObj) bool {
        return self.theMutex.tryLock();
    }

    fn Unblock(self: *SyncObj) void {
        self.theMutex.unlock();
    }

    fn Reset(self: *SyncObj) void {
        if (self.theMutex.tryLock()) self.theMutex.unlock();
    }
};

const SAMPLES: c_ulong = 1024;
const FRAMERATE = 44_100.0;
//const FRAMERATE = 32_000;
var ThePA = PA{};

pub const PA = struct {
    err: c.PaError = c.paNoError,
    numDevices: c.PaDeviceIndex = undefined,
    gpa: std.heap.GeneralPurposeAllocator(.{}) = std.heap.GeneralPurposeAllocator(.{}){},
    deviceInfoList: DIList = DIList{},
    inSP: c.PaStreamParameters = c.PaStreamParameters{},
    outSP: c.PaStreamParameters = c.PaStreamParameters{},
    miStream: ?*c.PaStream = null,
    RawAudio: [SAMPLES]f32 = .{0.0} ** SAMPLES,
    ModAudio: [SAMPLES]f32 = .{0.0} ** SAMPLES,
    theSync: SyncObj = SyncObj{},

    pub fn Init() *PA {
        ThePA.err = c.Pa_Initialize();
        if (ThePA.err == c.paNoError) ThePA.FillInfo();

        return &ThePA;
    }

    pub fn FillInfo(self: *PA) void {
        self.numDevices = c.Pa_GetDeviceCount();

        const b: u32 = @bitCast(self.numDevices);
        for (0..b) |ind| {
            const aux = @constCast(c.Pa_GetDeviceInfo(@intCast(ind)));
            self.deviceInfoList.append(self.gpa.allocator(), aux.*) catch return;

            stdout.print("Info for Device {d}: {s} - {d} - {d}\n", .{ ind, aux.*.name, aux.*.maxInputChannels, aux.*.maxOutputChannels }) catch return;
        }

        self.inSP.channelCount = 1;
        self.inSP.sampleFormat = c.paFloat32;
        self.inSP.suggestedLatency = 0.0;
        self.outSP.channelCount = 1;
        self.outSP.sampleFormat = c.paFloat32;
        self.outSP.suggestedLatency = 0.0;
    }

    pub fn Terminate(self: *PA) void {
        _ = c.Pa_Terminate();
        if (self.err != c.paNoError) {
            stdout.print("Error {d}! {s}\n", .{ self.err, c.Pa_GetErrorText(self.err) }) catch return;
        }
        self.deviceInfoList.deinit(self.gpa.allocator());
    }

    pub fn GetDevices(self: *PA) *DIList {
        return &self.deviceInfoList;
    }

    pub fn CheckCompatibility(self: *PA, x: c.PaDeviceIndex, y: c.PaDeviceIndex) bool {
        self.inSP.device = x;
        self.outSP.device = y;
        self.inSP.suggestedLatency = c.Pa_GetDeviceInfo(x).*.defaultLowInputLatency;
        self.outSP.suggestedLatency = c.Pa_GetDeviceInfo(y).*.defaultLowInputLatency;
        if (c.Pa_IsFormatSupported(&self.inSP, &self.outSP, 44_100.0) != c.paNoError)
            return false
        else
            return true;
    }

    pub fn Start(self: *PA) void {
        // self.theSync.Reset();
        _ = c.Pa_OpenStream(@alignCast(&self.miStream), &self.inSP, &self.outSP, FRAMERATE, SAMPLES, c.paNoFlag, &c_FuzzCallback, self);
        _ = c.Pa_StartStream(self.miStream);
    }

    pub fn Stop(self: *PA) void {
        _ = c.Pa_StopStream(self.miStream);
        _ = c.Pa_CloseStream(self.miStream);
        // self.theSync.Reset();
    }

    fn c_FuzzCallback(inputBuffer: ?*const anyopaque, outputBuffer: ?*anyopaque, _: c_ulong, _: [*c]const c.PaStreamCallbackTimeInfo, _: c.PaStreamCallbackFlags, ptr: ?*anyopaque) callconv(.C) c_int {
        const ptrIn: *[SAMPLES]f32 = @constCast(@ptrCast(@alignCast(inputBuffer)));
        const ptrOut: *[SAMPLES]f32 = @constCast(@ptrCast(@alignCast(outputBuffer)));

        const in: [SAMPLES]f32 = ptrIn.*;
        var vAmp: @Vector(SAMPLES, f32) = ptrIn.*;

        const K: @Vector(SAMPLES, f32) = @splat(2.2);
        vAmp = K * vAmp;

        var out: [SAMPLES]f32 = vAmp;
        @memcpy(ptrOut, &out);

        var zeros: [SAMPLES]f32 = .{0.0} ** SAMPLES;
        _ = fft.fft(f32, @constCast(&in), &zeros) catch 0;
        const real: @Vector(SAMPLES, f32) = in;
        const imag: @Vector(SAMPLES, f32) = zeros;

        const K2: @Vector(SAMPLES, f32) = @splat(0.05);
        const mod = @sqrt(real * real + imag * imag) * K2;
        out = mod;
        //const arg=imag/real;

        var self: *PA = @ptrCast(@alignCast(ptr));
        if (self.theSync.Block()) {
            @memcpy(&self.RawAudio, &ptrIn.*);
            @memcpy(&self.ModAudio, &out);
            self.theSync.Unblock();
        }

        return 0;
    }

    pub fn GetInputdata(self: *PA, dataRaw: *[SAMPLES]f32, dataMod: *[SAMPLES]f32) bool {
        if (self.theSync.Block()) {
            @memcpy(dataRaw, &self.RawAudio);
            @memcpy(dataMod, &self.ModAudio);
            self.theSync.Unblock();
            return true;
        }

        return false;
    }
};
