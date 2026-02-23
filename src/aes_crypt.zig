//! 7zAES encryption/decryption module.
//!
//! Implements the 7z AES-256-CBC encryption scheme:
//! - Custom SHA-256 iterative KDF for key derivation from password
//! - AES-256-CBC decryption/encryption
//! - Coder property parsing (cycles power, salt, IV)
//!
//! Method ID: 06 F1 07 01

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Aes256 = std.crypto.core.aes.Aes256;

pub const AesError = error{
	InvalidProperties,
	DecryptFailed,
	OutOfMemory,
	PasswordRequired,
};

/// Parsed 7zAES coder properties.
pub const AesProperties = struct {
	num_cycles_power: u6,
	salt: [16]u8,
	salt_size: u5,
	iv: [16]u8,
	iv_size: u5,
};

/// Parse 7zAES coder properties from the raw property bytes.
pub fn parseProperties(data: []const u8) AesError!AesProperties {
	if (data.len < 1) return AesError.InvalidProperties;

	var result = AesProperties{
		.num_cycles_power = 0,
		.salt = [_]u8{0} ** 16,
		.salt_size = 0,
		.iv = [_]u8{0} ** 16,
		.iv_size = 0,
	};

	const b0 = data[0];
	result.num_cycles_power = @truncate(b0 & 0x3F);

	const salt_flag: u1 = @truncate(b0 >> 7);
	const iv_flag: u1 = @truncate((b0 >> 6) & 1);

	if (salt_flag == 0 and iv_flag == 0) {
		return result;
	}

	if (data.len < 2) return AesError.InvalidProperties;
	const b1 = data[1];
	const salt_size: u5 = @intCast(@as(u8, salt_flag) + @as(u8, @truncate(b1 >> 4)));
	const iv_size: u5 = @intCast(@as(u8, iv_flag) + @as(u8, @truncate(b1 & 0x0F)));

	result.salt_size = salt_size;
	result.iv_size = iv_size;

	const need = @as(usize, 2) + salt_size + iv_size;
	if (data.len < need) return AesError.InvalidProperties;

	if (salt_size > 0) {
		@memcpy(result.salt[0..salt_size], data[2 .. 2 + salt_size]);
	}
	if (iv_size > 0) {
		const iv_start = @as(usize, 2) + salt_size;
		@memcpy(result.iv[0..iv_size], data[iv_start .. iv_start + iv_size]);
	}

	return result;
}

/// Derive AES-256 key from password using the 7z SHA-256 iterative KDF.
/// Password is UTF-8; it will be converted to UTF-16LE internally.
pub fn deriveKey(password: []const u8, props: AesProperties) [32]u8 {
	if (props.num_cycles_power == 0x3F) {
		// Raw key mode: salt + password_utf16le, zero-padded to 32 bytes
		var key = [_]u8{0} ** 32;
		var pos: usize = 0;
		const salt_len = @as(usize, props.salt_size);
		if (salt_len > 0 and salt_len <= 32) {
			const copy_len = @min(salt_len, 32);
			@memcpy(key[0..copy_len], props.salt[0..copy_len]);
			pos = copy_len;
		}
		// Convert password to UTF-16LE and append
		if (pos < 32) {
			var utf16_buf: [256]u16 = undefined;
			const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, password) catch 0;
			const utf16_bytes = std.mem.sliceAsBytes(utf16_buf[0..utf16_len]);
			const copy_len = @min(utf16_bytes.len, 32 - pos);
			@memcpy(key[pos .. pos + copy_len], utf16_bytes[0..copy_len]);
		}
		return key;
	}

	// Convert password to UTF-16LE
	var utf16_buf: [512]u16 = undefined;
	const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, password) catch 0;
	const pw_bytes = std.mem.sliceAsBytes(utf16_buf[0..utf16_len]);

	const salt_len = @as(usize, props.salt_size);
	const num_rounds: u64 = @as(u64, 1) << props.num_cycles_power;

	// SHA-256 iterative KDF:
	// One continuous hash: init, then for each round update(salt + password_utf16le + counter_le64)
	var hasher = Sha256.init(.{});

	var counter_buf: [8]u8 = undefined;
	var i: u64 = 0;
	while (i < num_rounds) : (i += 1) {
		if (salt_len > 0) {
			hasher.update(props.salt[0..salt_len]);
		}
		hasher.update(pw_bytes);
		std.mem.writeInt(u64, &counter_buf, i, .little);
		hasher.update(&counter_buf);
	}

	return hasher.finalResult();
}

/// Decrypt data using AES-256-CBC. Operates in-place on a mutable buffer.
/// Buffer length must be a multiple of 16.
pub fn decryptCbc(data: []u8, key: [32]u8, iv: [16]u8) AesError!void {
	if (data.len % 16 != 0) return AesError.DecryptFailed;
	if (data.len == 0) return;

	const ctx = Aes256.initDec(key);
	var prev = iv;

	var offset: usize = 0;
	while (offset < data.len) : (offset += 16) {
		const block = data[offset..][0..16];
		const cipher_copy = block.*;
		var decrypted: [16]u8 = undefined;
		ctx.decrypt(&decrypted, block);
		// XOR with previous ciphertext (or IV)
		for (&decrypted, prev) |*d, p| {
			d.* ^= p;
		}
		@memcpy(block, &decrypted);
		prev = cipher_copy;
	}
}

/// Encrypt data using AES-256-CBC. Operates in-place on a mutable buffer.
/// Buffer length must be a multiple of 16 (caller must pad if needed).
pub fn encryptCbc(data: []u8, key: [32]u8, iv: [16]u8) AesError!void {
	if (data.len % 16 != 0) return AesError.DecryptFailed;
	if (data.len == 0) return;

	const ctx = Aes256.initEnc(key);
	var prev = iv;

	var offset: usize = 0;
	while (offset < data.len) : (offset += 16) {
		const block = data[offset..][0..16];
		// XOR plaintext with previous ciphertext (or IV)
		for (block, prev) |*b, p| {
			b.* ^= p;
		}
		var encrypted: [16]u8 = undefined;
		ctx.encrypt(&encrypted, block);
		@memcpy(block, &encrypted);
		prev = encrypted;
	}
}

/// Full 7zAES decrypt: parse properties, derive key, CBC decrypt.
/// Returns owned slice trimmed to unpack_size.
pub fn decrypt7zAes(
	ciphertext: []const u8,
	properties: []const u8,
	password: []const u8,
	unpack_size: u64,
	allocator: std.mem.Allocator,
) AesError![]u8 {
	const props = try parseProperties(properties);

	const key = deriveKey(password, props);

	// Pad IV to 16 bytes (already zero-padded in AesProperties)
	const iv = props.iv;

	// Copy ciphertext to mutable buffer (AES-CBC works on 16-byte aligned blocks)
	const aligned_len = (ciphertext.len + 15) & ~@as(usize, 15);
	const buf = allocator.alloc(u8, aligned_len) catch return AesError.OutOfMemory;
	errdefer allocator.free(buf);
	@memcpy(buf[0..ciphertext.len], ciphertext);
	if (aligned_len > ciphertext.len) {
		@memset(buf[ciphertext.len..], 0);
	}

	try decryptCbc(buf, key, iv);

	// Trim to unpack_size
	const out_size: usize = @intCast(unpack_size);
	if (out_size > buf.len) {
		allocator.free(buf);
		return AesError.DecryptFailed;
	}

	if (out_size == buf.len) {
		return buf;
	}

	// Shrink: copy to right-sized buffer
	const result = allocator.alloc(u8, out_size) catch {
		allocator.free(buf);
		return AesError.OutOfMemory;
	};
	@memcpy(result, buf[0..out_size]);
	allocator.free(buf);
	return result;
}

/// Encode 7zAES coder properties.
pub fn encodeProperties(props: AesProperties) struct { data: [34]u8, len: u8 } {
	var buf = [_]u8{0} ** 34;

	var b0: u8 = props.num_cycles_power;
	if (props.salt_size > 0) b0 |= 0x80;
	if (props.iv_size > 0) b0 |= 0x40;
	buf[0] = b0;

	if (props.salt_size == 0 and props.iv_size == 0) {
		return .{ .data = buf, .len = 1 };
	}

	const salt_extra: u8 = if (props.salt_size > 0) props.salt_size - 1 else 0;
	const iv_extra: u8 = if (props.iv_size > 0) props.iv_size - 1 else 0;
	buf[1] = (salt_extra << 4) | iv_extra;

	var pos: usize = 2;
	if (props.salt_size > 0) {
		@memcpy(buf[pos .. pos + props.salt_size], props.salt[0..props.salt_size]);
		pos += props.salt_size;
	}
	if (props.iv_size > 0) {
		@memcpy(buf[pos .. pos + props.iv_size], props.iv[0..props.iv_size]);
		pos += props.iv_size;
	}

	return .{ .data = buf, .len = @intCast(pos) };
}

// ============================================================================
// Tests
// ============================================================================

test "aes_crypt: parse properties - no salt no iv" {
	const props = try parseProperties(&.{19}); // cycles=19, no salt, no iv
	try std.testing.expectEqual(@as(u6, 19), props.num_cycles_power);
	try std.testing.expectEqual(@as(u5, 0), props.salt_size);
	try std.testing.expectEqual(@as(u5, 0), props.iv_size);
}

test "aes_crypt: parse properties - with salt and iv" {
	// b0: cycles=19, salt_flag=1, iv_flag=1
	// b1: salt_extra=7 (total salt=8), iv_extra=15 (total iv=16)
	var data: [26]u8 = undefined;
	data[0] = 19 | 0x80 | 0x40; // cycles=19, salt=1, iv=1
	data[1] = (7 << 4) | 15; // salt_extra=7, iv_extra=15
	for (data[2..10], 0..) |*b, i| b.* = @intCast(0xA0 + i); // salt (8 bytes)
	for (data[10..26], 0..) |*b, i| b.* = @intCast(0xB0 + i); // iv (16 bytes)

	const props = try parseProperties(&data);
	try std.testing.expectEqual(@as(u6, 19), props.num_cycles_power);
	try std.testing.expectEqual(@as(u5, 8), props.salt_size);
	try std.testing.expectEqual(@as(u5, 16), props.iv_size);
	try std.testing.expectEqual(@as(u8, 0xA0), props.salt[0]);
	try std.testing.expectEqual(@as(u8, 0xB0), props.iv[0]);
}

test "aes_crypt: property encode/decode roundtrip" {
	const original = AesProperties{
		.num_cycles_power = 19,
		.salt = .{ 0x11, 0x22, 0x33, 0x44 } ++ .{0} ** 12,
		.salt_size = 4,
		.iv = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A },
		.iv_size = 16,
	};
	const encoded = encodeProperties(original);
	const decoded = try parseProperties(encoded.data[0..encoded.len]);
	try std.testing.expectEqual(original.num_cycles_power, decoded.num_cycles_power);
	try std.testing.expectEqual(original.salt_size, decoded.salt_size);
	try std.testing.expectEqual(original.iv_size, decoded.iv_size);
	try std.testing.expectEqualSlices(u8, original.salt[0..4], decoded.salt[0..4]);
	try std.testing.expectEqualSlices(u8, &original.iv, &decoded.iv);
}

test "aes_crypt: CBC encrypt/decrypt roundtrip" {
	const key = [_]u8{0x01} ** 32;
	const iv = [_]u8{0x02} ** 16;
	const plaintext = "Hello, 7zAES!!\x00\x00"; // 16 bytes exactly
	var buf: [16]u8 = plaintext.*;

	try encryptCbc(&buf, key, iv);
	// After encryption, should differ from plaintext
	try std.testing.expect(!std.mem.eql(u8, &buf, plaintext));

	try decryptCbc(&buf, key, iv);
	// After decryption, should match original
	try std.testing.expectEqualSlices(u8, plaintext, &buf);
}

test "aes_crypt: CBC multi-block roundtrip" {
	const key = [_]u8{0xAB} ** 32;
	const iv = [_]u8{0xCD} ** 16;
	var data: [64]u8 = undefined;
	for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);
	const original = data;

	try encryptCbc(&data, key, iv);
	try std.testing.expect(!std.mem.eql(u8, &data, &original));

	try decryptCbc(&data, key, iv);
	try std.testing.expectEqualSlices(u8, &original, &data);
}

test "aes_crypt: KDF produces deterministic key" {
	const props = AesProperties{
		.num_cycles_power = 0, // 2^0 = 1 round (fast for testing)
		.salt = [_]u8{0} ** 16,
		.salt_size = 0,
		.iv = [_]u8{0} ** 16,
		.iv_size = 0,
	};

	const key1 = deriveKey("test", props);
	const key2 = deriveKey("test", props);
	try std.testing.expectEqualSlices(u8, &key1, &key2);

	// Different password should produce different key
	const key3 = deriveKey("other", props);
	try std.testing.expect(!std.mem.eql(u8, &key1, &key3));
}

test "aes_crypt: full encrypt/decrypt roundtrip" {
	const allocator = std.testing.allocator;

	const password = "secret123";
	const plaintext = "This is secret 7z data that we want to encrypt and decrypt.";

	// Set up properties
	var props = AesProperties{
		.num_cycles_power = 1, // 2^1 = 2 rounds (fast for testing)
		.salt = [_]u8{0} ** 16,
		.salt_size = 8,
		.iv = [_]u8{0} ** 16,
		.iv_size = 16,
	};
	// Fill salt and IV with test values
	for (props.salt[0..8], 0..) |*b, i| b.* = @intCast(0x10 + i);
	for (&props.iv, 0..) |*b, i| b.* = @intCast(0x20 + i);

	const key = deriveKey(password, props);

	// Pad plaintext to 16-byte boundary
	const padded_len = (plaintext.len + 15) & ~@as(usize, 15);
	var cipher_buf = try allocator.alloc(u8, padded_len);
	defer allocator.free(cipher_buf);
	@memcpy(cipher_buf[0..plaintext.len], plaintext);
	@memset(cipher_buf[plaintext.len..], 0);

	// Encrypt
	try encryptCbc(cipher_buf, key, props.iv);

	// Decrypt with full pipeline
	const encoded_props = encodeProperties(props);
	const decrypted = try decrypt7zAes(
		cipher_buf,
		encoded_props.data[0..encoded_props.len],
		password,
		plaintext.len,
		allocator,
	);
	defer allocator.free(decrypted);

	try std.testing.expectEqualStrings(plaintext, decrypted);
}
