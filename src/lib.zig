//! z7z — cleanroom 7z archive format implementation.
//!
//! Architecture: pure Zig core (no I/O), exposed via C FFI.

pub const crc32 = @import("crc32.zig");
pub const varint = @import("varint.zig");
pub const header = @import("header.zig");
pub const nid = @import("nid.zig");
pub const reader = @import("reader.zig");
pub const metadata = @import("metadata.zig");

test {
    _ = crc32;
    _ = varint;
    _ = header;
    _ = nid;
    _ = reader;
    _ = metadata;
}
