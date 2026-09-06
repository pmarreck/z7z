#!/usr/bin/env node
// Explicit wire vectors, independently decoded by 7zz. No codec imports.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = path.dirname(fileURLToPath(import.meta.url));
const oracle = process.env.ORACLE ?? '/dev/shm/z7z-coverage-20260906.QOCJby/7zzs';
const sha256 = b => createHash('sha256').update(b).digest('hex');
const version = execFileSync(oracle, ['i'], { encoding: 'utf8' });
if (!version.includes('26.03')) throw new Error('Expected oracle 26.03');
class Bits {
	bytes = []; count = 0;
	put(value, width) {
		for (let i = 0; i < width; i++, this.count++) {
			const byte = this.count >>> 3;
			this.bytes[byte] = (this.bytes[byte] ?? 0) | (((value >>> i) & 1) << (this.count & 7));
		}
	}
	code(value, width) { for (let i = width - 1; i >= 0; i--) this.put((value >>> i) & 1, 1); }
	literal(symbol) {
		if (symbol < 144) this.code(0x30 + symbol, 8);
		else if (symbol < 256) this.code(0x190 + symbol - 144, 9);
		else if (symbol < 280) this.code(symbol - 256, 7);
		else this.code(0xc0 + symbol - 280, 8);
	}
	stored(data) {
		this.put(0, 3);
		while (this.count & 7) this.put(0, 1);
		this.put(data.length, 16); this.put(data.length ^ 65535, 16);
		for (const byte of data) this.put(byte, 8);
	}
	buffer() { return Buffer.from(this.bytes); }
}
function zip(raw, plain) {
	let crc = 0xffffffff;
	for (const byte of plain) {
		crc ^= byte;
		for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
	}
	crc = (crc ^ 0xffffffff) >>> 0;
	const name = Buffer.from('payload.bin');
	const local = Buffer.alloc(30);
	local.writeUInt32LE(0x04034b50); local.writeUInt16LE(21, 4); local.writeUInt16LE(9, 8);
	local.writeUInt32LE(crc, 14); local.writeUInt32LE(raw.length, 18); local.writeUInt32LE(plain.length, 22);
	local.writeUInt16LE(name.length, 26);
	const central = Buffer.alloc(46);
	central.writeUInt32LE(0x02014b50); central.writeUInt16LE(21, 4); central.writeUInt16LE(21, 6);
	central.writeUInt16LE(9, 10); central.writeUInt32LE(crc, 16); central.writeUInt32LE(raw.length, 20);
	central.writeUInt32LE(plain.length, 24); central.writeUInt16LE(name.length, 28);
	const end = Buffer.alloc(22);
	end.writeUInt32LE(0x06054b50); end.writeUInt16LE(1, 8); end.writeUInt16LE(1, 10);
	end.writeUInt32LE(central.length + name.length, 12); end.writeUInt32LE(local.length + name.length + raw.length, 16);
	return Buffer.concat([local, name, raw, central, name, end]);
}
const cases = [];
for (const extra of [0, 255, 65535]) {
	const bits = new Bits();
	bits.put(3, 3); bits.literal(65); bits.literal(285); bits.put(extra, 16); bits.code(0, 5); bits.literal(256);
	cases.push({ name: `extended-${extra}`, bits, plain: Buffer.alloc(extra + 4, 65), detail: `fixed: literal A; length285 extra=${extra}; distance=1; EOB` });
}
const seed = fs.readFileSync(path.join(root, 'stored.plain'));
const history = Buffer.concat([seed, seed.subarray(0, 16384)]);
const bits = new Bits(); bits.stored(history.subarray(0, 65535)); bits.stored(history.subarray(65535));
bits.put(3, 3); bits.literal(257); bits.code(31, 5); bits.put(16383, 14); bits.literal(256);
cases.push({ name: 'distance65536', bits, plain: Buffer.concat([history, history.subarray(0, 3)]), detail: 'two stored blocks (65535+1); fixed length3, distance code31 extra16383 = 65536' });
const manifest = { oracle_sha256: sha256(fs.readFileSync(oracle)), cases: [] };
for (const { name, bits, plain, detail } of cases) {
	const archive = path.join(root, `${name}.zip`);
	if (fs.existsSync(archive)) throw new Error(`Refusing to overwrite ${archive}`);
	const raw = bits.buffer(); const bytes = zip(raw, plain);
	fs.writeFileSync(archive, bytes);
	const actual = execFileSync(oracle, ['x', '-so', archive]);
	if (!actual.equals(plain)) throw new Error(`Oracle disagrees: ${name}`);
	fs.writeFileSync(path.join(root, `${name}.raw`), raw);
	fs.writeFileSync(path.join(root, `${name}.plain`), plain);
	manifest.cases.push({ name, detail, valid_bits: bits.count, oracle_verified: true, plain_sha256: sha256(plain), raw_sha256: sha256(raw), archive_sha256: sha256(bytes) });
}
fs.writeFileSync(path.join(root, 'crafted-provenance.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(JSON.stringify(manifest, null, 2));
