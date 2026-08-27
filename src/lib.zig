//! z7z — cleanroom 7z archive format implementation.
//!
//! Architecture: pure Zig core (no I/O), exposed via C FFI.

pub const crc32 = @import("crc32.zig");
pub const varint = @import("varint.zig");
pub const header = @import("header.zig");
pub const nid = @import("nid.zig");
pub const reader = @import("reader.zig");
pub const writer = @import("writer.zig");
pub const metadata = @import("metadata.zig");
pub const encoder = @import("encoder.zig");
pub const codec = @import("codec.zig");
pub const lzma2_encoder = @import("lzma2_encoder.zig");
pub const aes_crypt = @import("aes_crypt.zig");
pub const progress = @import("progress.zig");
pub const range_source = @import("range_source.zig");
pub const archive = @import("archive.zig");
pub const ffi = @import("ffi.zig");
pub const interop_test = @import("interop_test.zig");

// Force analysis of C FFI module so export symbols are emitted.
comptime {
    _ = @import("ffi.zig");
}

test {
    _ = crc32;
    _ = varint;
    _ = header;
    _ = nid;
    _ = reader;
    _ = writer;
    _ = metadata;
    _ = encoder;
    _ = codec;
    _ = lzma2_encoder;
    _ = aes_crypt;
    _ = progress;
    _ = range_source;
    _ = archive;
    _ = ffi;
    _ = interop_test;
}
