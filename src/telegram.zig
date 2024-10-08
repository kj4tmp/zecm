const std = @import("std");
const lossyCast = std.math.lossyCast;
const assert = std.debug.assert;
const big = std.builtin.Endian.big;
const little = std.builtin.Endian.little;

const wire = @import("wire.zig");

/// EtherCAT command, present in the EtherCAT datagram header.
pub const Command = enum(u8) {
    /// No operation.
    /// The subdevice ignores the command.
    NOP = 0x00,
    /// Auto increment physical read.
    /// A subdevice increments the address.
    /// A subdevice writes the data it has read to the EtherCAT datagram
    /// if the address received is zero.
    APRD,
    /// Auto increment physical write.
    /// A subdevice increments the address.
    /// A subdevice writes data to a memory area if the address received is zero.
    APWR,
    /// Auto increment physical read write.
    /// A subdevice increments the address.
    /// A subdevice writes the data it has read to the EtherCAT datagram and writes
    /// the newly acquired data to the same memory area if the received address is zero.
    APRW,
    /// Configured address physical read.
    /// A subdevice writes the data it has read to the EtherCAT datagram if its subdevice
    /// address matches one of the addresses configured in the datagram.
    FPRD,
    /// Configured address physical write.
    /// A subdevice writes data to a memory area if its subdevice address matches one
    /// of the addresses configured in the datagram.
    FPWR,
    /// Configured address physical read write.
    /// A subdevice writes the data it has read to the EtherCAT datagram and writes
    /// the newly acquired data to the same memory area if its subdevice address matches
    /// one of the addresses configured in the datagram.
    FPRW,
    /// Broadcast read.
    /// All subdevices write a logical OR of the data from the memory area and the data
    /// from the EtherCAT datagram to the EtherCAT datagram. All subdevices increment the
    /// position field.
    BRD,
    /// Broadcast write.
    /// All subdevices write data to a memory area. All subdevices increment the position field.
    BWR,
    /// Broadcast read write.
    /// All subdevices write a logical OR of the data from the memory area and the data from the
    /// EtherCAT datagram to the EtherCAT datagram; all subdevices write data to the memory area.
    /// BRW is typically not used. All subdevices increment the position field.
    BRW,
    /// Logical memory read.
    /// A subdevice writes data it has read to the EtherCAT datagram if the address received
    /// matches one of the FMMU areas configured for reading.
    LRD,
    /// Logical memory write.
    /// SubDevices write data to their memory area if the address received matches one of
    /// the FMMU areas configured for writing.
    LWR,
    /// Logical memory read write.
    /// A subdevice writes data it has read to the EtherCAT datagram if the address received
    /// matches one of the FMMU areas configured for reading. SubDevices write data to their memory area
    /// if the address received matches one of the FMMU areas configured for writing.
    LRW,
    /// Auto increment physical read multiple write.
    /// A subdevice increments the address field. A subdevice writes data it has read to the EtherCAT
    /// datagram when the address received is zero, otherwise it writes data to the memory area.
    ARMW,
    /// Configured address physical read multiple write.
    FRMW,
};

/// Position Address (Auto Increment Address)
pub const PositionAddress = packed struct(u32) {
    /// Each subdevice increments this address. The subdevice is addressed if position=0.
    autoinc_address: u16,
    /// local register address or local memory address of the ESC
    offset: u16,
};

pub const StationAddress = packed struct(u32) {
    /// The subdevice is addressed if its address corresponds to the configured station address
    /// or the configured station alias (if enabled).
    station_address: u16,
    /// local register address or local memory address of the ESC
    offset: u16,
};

pub const LogicalAddress = u32;

/// Datagram Header
///
/// Ref: IEC 61158-4-12:2019 5.4.1.2
pub const DatagramHeader = packed struct(u80) {
    /// service command, APRD etc.
    command: Command,
    /// used my maindevice to identify duplicate or lost datagrams
    idx: u8,
    /// auto-increment, configured station, or logical address
    /// when position addressing
    address: u32,
    /// length of following data, in bytes, not including wkc
    length: u11,
    /// reserved, 0
    reserved: u3 = 0,
    /// true when frame has circulated at least once, else false
    circulating: bool,
    /// multiple datagrams, true when more datagrams follow, else false
    next: bool,
    /// EtherCAT event request register of all subdevices combined with
    /// a logical OR. Two byte bitmask (IEC 61131-3 WORD)
    irq: u16,
};

/// Datagram
///
/// The IEC standard specifies the different commands
/// as different structures. However, the structure are all
/// very similar to they are combined here as one datagram.
///
/// The ETG standards appear to do combine them all too.
///
/// The only difference between the different commands is the addressing
/// scheme. They all have the same size.
///
/// Ref: IEC 61158-4-12:2019 5.4.1.2
pub const Datagram = struct {
    header: DatagramHeader,
    data: []u8,
    /// Working counter.
    /// The working counter is incremented if an EtherCAT device was successfully addressed
    /// and a read operation, a write operation or a read/write operation was executed successfully.
    /// Each datagram can be assigned a value for the corking counter that is expected after the
    /// telegram has passed through all devices. The maindevice can check whether an EtherCAT datagram
    /// was processed successfully by comparing the value to be expected for the working counter
    /// with the actual value of the working counter after it has passed through all devices.
    ///
    /// For a read command: if successful wkc+=1.
    /// For a write command: if write command successful wkc+=1.
    /// For a read/write command: if read command successful wkc+=1, if write command successful wkc+=2. If both wkc+=3.
    wkc: u16,

    pub fn init(command: Command, idx: u8, address: u32, next: bool, data: []u8) Datagram {
        assert(data.len < max_data_length);
        return Datagram{
            .header = .{
                .command = command,
                .idx = idx,
                .address = address,
                .length = @intCast(data.len),
                .circulating = false,
                .next = next,
                .irq = 0,
            },
            .data = data,
            .wkc = 0,
        };
    }

    fn getLength(self: Datagram) usize {
        return self.header.length +
            @divExact(@bitSizeOf(DatagramHeader), 8) +
            @divExact(@bitSizeOf(u16), 8);
    }

    pub const max_data_length = EtherCATFrame.max_datagrams_length -
        @divExact(@bitSizeOf(DatagramHeader), 8) -
        @divExact(@bitSizeOf(u16), 8);
};

/// EtherCAT Header
///
/// Ref: IEC 61158-4-12:2019 5.3.3
pub const EtherCATHeader = packed struct(u16) {
    /// length of the following datagrams (not including this header)
    length: u11,
    reserved: u1 = 0,
    /// ESC's only support EtherCAT commands (0x1)
    type: u4 = 0x1,
};

// TODO: EtherCAT frame structure containing network variables. Ref: IEC 61158-4-12:2019 5.3.3

/// EtherCAT Frame.
/// Must be embedded inside an Ethernet Frame.
///
/// Ref: IEC 61158-4-12:2019 5.3.3
pub const EtherCATFrame = struct {
    header: EtherCATHeader,
    datagrams: []Datagram,

    pub fn init(datagrams: []Datagram) EtherCATFrame {
        assert(datagrams.len != 0); // no datagrams
        assert(datagrams.len <= 15); // too many datagrams

        var header_length: u11 = 0;

        for (datagrams) |datagram| {
            header_length += @intCast(datagram.getLength());
        }
        assert(header_length <= max_datagrams_length);

        const header = EtherCATHeader{
            .length = header_length,
        };
        return EtherCATFrame{
            .header = header,
            .datagrams = datagrams,
        };
    }

    fn getLength(self: EtherCATFrame) usize {
        return self.header.length + @divExact(@bitSizeOf(EtherCATHeader), 8);
    }

    const max_datagrams_length = max_frame_length -
        @divExact(@bitSizeOf(EthernetHeader), 8) -
        @divExact(@bitSizeOf(EtherCATHeader), 8);
};

pub const EtherType = enum(u16) {
    UDP_ETHERCAT = 0x8000,
    ETHERCAT = 0x88a4,
    _,
};

// TODO: EtherCAT in UDP Frame. Ref: IEC 61158-4-12:2019 5.3.2

/// Ethernet Header
///
/// Ref: IEC 61158-4-12:2019 5.3.1
pub const EthernetHeader = packed struct(u112) {
    dest_mac: u48,
    src_mac: u48,
    ether_type: EtherType,
};

const reusable_padding = std.mem.zeroes([46]u8);

/// Ethernet Frame
///
/// This is what is actually sent on the wire.
///
/// It is a standard ethernet frame with EtherCAT data in it.
///
/// Ref: IEC 61158-4-12:2019 5.3.1
pub const EthernetFrame = struct {
    header: EthernetHeader,
    ethercat_frame: EtherCATFrame,
    padding: []const u8,

    pub fn init(
        header: EthernetHeader,
        ethercat_frame: EtherCATFrame,
    ) EthernetFrame {
        const length: usize = @divExact(@bitSizeOf(EthernetHeader), 8) + ethercat_frame.getLength();
        const n_pad: usize = min_frame_length -| length;

        return EthernetFrame{
            .header = header,
            .ethercat_frame = ethercat_frame,
            .padding = reusable_padding[0..n_pad],
        };
    }

    /// calcuate the length of the frame in bytes
    /// without padding
    // pub fn getLengthWithoutPadding(self: EthernetFrame) u16 {
    //     var length: u16 = 0;
    //     length +|= @bitSizeOf(@TypeOf(self.header)) / 8;
    //     length +|= self.ethercat_frame.getLength();
    //     return length;
    // }

    // /// Get required number of padding bytes
    // /// for this frame.
    // /// Assumes no existing padding.
    // pub fn getRequiredPaddingLength(self: EthernetFrame) u16 {
    //     return @as(u16, min_frame_length) -| self.getLengthWithoutPadding();
    // }

    // pub fn getLengthWithPadding(self: EthernetFrame) u32 {
    //     var length: u32 = 0;
    //     length +|= @sizeOf(self.header);
    //     length +|= self.ethercat_frame.getLength();
    //     length +|= self.padding.len;
    //     return length;
    // }

    // /// write calcuated fields
    // pub fn calc(self: *EthernetFrame) void {
    //     self.ethercat_frame.calc();
    // }

    /// assign idx to first datagram for frame identification
    /// in nic
    pub fn assignIdx(self: *EthernetFrame, idx: u8) void {
        self.ethercat_frame.datagrams[0].header.idx = idx;
    }

    /// serialize this frame into the out buffer
    /// for tranmission on the line.
    ///
    /// Returns number of bytes written, or error.
    pub fn serialize(self: *const EthernetFrame, out: []u8) !usize {
        var fbs = std.io.fixedBufferStream(out);
        const writer = fbs.writer();
        try writer.writeInt(u48, self.header.dest_mac, big);
        try writer.writeInt(u48, self.header.src_mac, big);
        try writer.writeInt(u16, @intFromEnum(self.header.ether_type), big);
        try wire.eCatFromPackToWriter(self.ethercat_frame.header, writer);
        for (self.ethercat_frame.datagrams) |datagram| {
            try wire.eCatFromPackToWriter(datagram.header, writer);
            try writer.writeAll(datagram.data);
            try wire.eCatFromPackToWriter(datagram.wkc, writer);
        }
        try writer.writeAll(self.padding);
        return fbs.getWritten().len;
    }

    /// deserialze bytes into datagrams
    pub fn deserialize(
        received: []const u8,
        out: []Datagram,
    ) !void {
        var fbs_reading = std.io.fixedBufferStream(received);
        const reader = fbs_reading.reader();

        const ethernet_header = EthernetHeader{
            .dest_mac = try reader.readInt(u48, big),
            .src_mac = try reader.readInt(u48, big),
            .ether_type = @enumFromInt(try reader.readInt(u16, big)),
        };
        if (ethernet_header.ether_type != .ETHERCAT) {
            return error.NotAnEtherCATFrame;
        }
        const ethercat_header = try wire.packFromECatReader(EtherCATHeader, reader);
        const bytes_remaining = try fbs_reading.getEndPos() - try fbs_reading.getPos();
        const bytes_total = try fbs_reading.getEndPos();
        if (bytes_total < min_frame_length) {
            return error.InvalidFrameLengthTooSmall;
        }
        if (ethercat_header.length > bytes_remaining) {
            std.log.debug(
                "length field: {}, remaining: {}, end pos: {}",
                .{ ethercat_header.length, bytes_remaining, try fbs_reading.getEndPos() },
            );
            return error.InvalidEtherCATHeader;
        }

        for (out) |*out_datagram| {
            out_datagram.header = try wire.packFromECatReader(DatagramHeader, reader);
            std.log.debug("datagram header: {}", .{out_datagram.header});
            if (out_datagram.header.length != out_datagram.data.len) {
                return error.CurruptedFrame;
            }
            const n_bytes_read = try reader.readAll(out_datagram.data);
            if (n_bytes_read != out_datagram.data.len) {
                return error.CurruptedFrame;
            }
            out_datagram.wkc = try wire.packFromECatReader(u16, reader);
        }
    }

    pub fn identifyFromBuffer(buf: []const u8) !u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const reader = fbs.reader();
        const ethernet_header = EthernetHeader{
            .dest_mac = try reader.readInt(u48, big),
            .src_mac = try reader.readInt(u48, big),
            .ether_type = @enumFromInt(try reader.readInt(u16, big)),
        };
        if (ethernet_header.ether_type != .ETHERCAT) {
            return error.NotAnEtherCATFrame;
        }
        const ethercat_header = try wire.packFromECatReader(EtherCATHeader, reader);
        const bytes_remaining = try fbs.getEndPos() - try fbs.getPos();
        const bytes_total = try fbs.getEndPos();
        if (bytes_total < min_frame_length) {
            return error.InvalidFrameLengthTooSmall;
        }
        if (ethercat_header.length > bytes_remaining) {
            std.log.debug(
                "length field: {}, remaining: {}, end pos: {}",
                .{ ethercat_header.length, bytes_remaining, try fbs.getEndPos() },
            );
            return error.InvalidEtherCATHeader;
        }
        const datagram_header = try wire.packFromECatReader(DatagramHeader, reader);
        return datagram_header.idx;
    }
};

test "ethernet frame serialization" {
    var data: [4]u8 = .{ 0x01, 0x02, 0x03, 0x04 };
    var datagrams: [1]Datagram = .{
        Datagram.init(.BRD, 123, 0xABCDEF12, false, &data),
    };
    var frame = EthernetFrame.init(
        .{
            .dest_mac = 0x1122_3344_5566,
            .src_mac = 0xAABB_CCDD_EEFF,
            .ether_type = .ETHERCAT,
        },
        EtherCATFrame.init(&datagrams),
    );
    var out_buf: [max_frame_length]u8 = undefined;
    const serialized = out_buf[0..try frame.serialize(&out_buf)];
    const expected = [min_frame_length]u8{
        // zig fmt: off

        // ethernet header
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, // src mac
        0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, // dest mac
        0x88, 0xa4, // 0x88a4 big endian

        // ethercat header
        0x10, 0b0001_0_000, // length=16, reserved=0, type=1

        // datagram header
        0x07, // BRD
        123, // idx
        0x12, 0xEF, 0xCD, 0xAB, // address
        0x04, //length
        0x00, // reserved, circulating, next
        0x00, 0x00, // irq
        0x01, 0x02, 0x03, 0x04, // data
        // wkc
        0x00, 0x00,
        // padding (28 bytes since 32 bytes above)
        0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        // zig fmt: on
    };
    try std.testing.expectEqualSlices(u8, &expected, serialized);
}

test "ethernet frame serialization / deserialization" {

    var data: [4]u8 = .{ 0x01, 0x02, 0x03, 0x04 };
    var datagrams: [1]Datagram = .{
        Datagram.init(.BRD, 0, 0xABCD, false, &data,),
    };

    var frame = EthernetFrame.init(
        .{
            .dest_mac = 0xffff_ffff_ffff,
            .src_mac = 0xAAAA_AAAA_AAAA,
            .ether_type = .ETHERCAT,
        },
        EtherCATFrame.init(&datagrams),
    );

    var out_buf: [max_frame_length]u8 = undefined;
    const serialized = out_buf[0..try frame.serialize(&out_buf)];
    var allocator = std.testing.allocator;
    const serialize_copy = try allocator.dupe(u8, serialized);
    defer allocator.free(serialize_copy);

    var data2: [4]u8 = undefined;
    var datagrams2 = datagrams;
    datagrams2[0].data = &data2;

    try EthernetFrame.deserialize(serialize_copy, &datagrams2);

    try std.testing.expectEqualDeep(frame.ethercat_frame.datagrams, &datagrams2);
}

/// Max frame length
/// Includes header, but not FCS (intended to be the max allowable size to
/// give to a raw socket send().)
/// FCS is handled by hardware and not normally returned to user.
///
/// Constructed of 1500 payload and 14 byte header.
pub const max_frame_length = 1514;
comptime {
    assert(max_frame_length == @divExact(@bitSizeOf(EthernetHeader), 8) + 1500);
}
pub const min_frame_length = 60;

test {
    std.testing.refAllDecls(@This());
}
