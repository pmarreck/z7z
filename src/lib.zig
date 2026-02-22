//! z7z — cleanroom 7z archive format implementation.
//!
//! Architecture: pure Zig core (no I/O), exposed via C FFI.

pub const crc32 = @import("crc32.zig");
pub const varint = @import("varint.zig");
pub const header = @import("header.zig");

test {
    _ = crc32;
    _ = varint;
    _ = header;
}
