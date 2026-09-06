// Independent fixtures: instruction-shaped inputs, encoded only by the external oracle.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = path.dirname(new URL(import.meta.url).pathname);
const oracle = process.env.ORACLE ?? '/dev/shm/z7z-coverage-20260906.QOCJby/7zzs';
const hash = b => createHash('sha256').update(b).digest('hex');
const cases = [];
function words(values, big = false) {
	const b = Buffer.alloc(values.length * 4);
	values.forEach((v, i) => big ? b.writeUInt32BE(v >>> 0, i * 4) : b.writeUInt32LE(v >>> 0, i * 4));
	return b;
}
function add(name, method, props, bytes) { cases.push({ name, method, props, bytes }); }
const data = Buffer.from(Array.from({ length: 1031 }, (_, i) => (i * 37 + (i >> 3) * 11) & 255));
for (const d of [1, 2, 3, 16, 256]) add(`delta${d}`, `Delta:${d}`, [d - 1], data);
add('swap2', 'Swap2', [], data);
add('swap4', 'Swap4', [], data);
const arm = words(Array.from({ length: 80 }, (_, i) => [0xeb000123, 0xebffff80, 0xea000030, 0x1b000042, 0xe1a00000][i % 5]));
const ppc = words(Array.from({ length: 80 }, (_, i) => [0x48000101, 0x4bffff81, 0x48000003, 0x48000000, 0x60000000][i % 5]), true);
const sparc = words(Array.from({ length: 80 }, (_, i) => [0x40000123, 0x7fffff80, 0x50000000, 0x01000000, 0x7f800001][i % 5]), true);
const thumb = Buffer.from(Array.from({ length: 80 }, (_, i) => [0x12, 0xf0, 0x45, 0xf8, 0x00, 0xbf, 0xff, 0xf7, 0x81, 0xff][i % 10]));
const arm64 = words(Array.from({ length: 80 }, (_, i) => [0x94000123, 0x97ffff80, 0x14000030, 0x90000007, 0xf0ffffe2, 0xd503201f, 0x90800001, 0x90ffffe3][i % 8]));
for (const [name, method, bytes] of [['arm', 'ARM', arm], ['ppc', 'PPC', ppc], ['sparc', 'SPARC', sparc], ['armt', 'ARMT', thumb], ['arm64', 'ARM64', arm64]]) {
	add(name, method, [], Buffer.concat([bytes, Buffer.from([0xe7, 0xf0, 0xeb])]));
}
const ia64 = [];
for (let template = 0; template < 32; template++) {
	for (let slot = 0; slot < 3; slot++) {
		let bundle = BigInt(template);
		const insn = (5n << 37n) | (0x12345n << 13n);
		bundle |= insn << BigInt(5 + slot * 41);
		const b = Buffer.alloc(16);
		for (let j = 0; j < 16; j++) b[j] = Number((bundle >> BigInt(j * 8)) & 255n);
		ia64.push(b);
	}
}
add('ia64', 'IA64', [], Buffer.concat([...ia64, Buffer.from([1, 2, 3])]));
const riscv = words(Array.from({ length: 80 }, (_, i) => [0x123450ef, 0xfffff0ef, 0x0100006f, 0x12345297, 0x678280e7, 0x00000013, 0xabcde517, 0xfff50513][i % 8]));
add('riscv', 'RISCV', [], Buffer.concat([riscv, Buffer.from([0xef, 0x01, 0x05])]));
const rvShapes = [];
for (let rd = 0; rd < 32; rd++) {
	for (let op = 0; op < 128; op++) {
		for (const rs of [rd, rd ^ 1]) {
			rvShapes.push(words([0x12345017 | (rd << 7), (0xabc00500 | (rs << 15) | op) >>> 0, 0x13]));
		}
	}
}
for (let rd = 0; rd < 32; rd++) {
	for (let bit = 12; bit < 32; bit++) rvShapes.push(words([(2 ** bit | (rd << 7) | 0x6f) >>> 0, 0x13]));
}
for (const rd of [0, 2]) {
	for (let reg = 0; reg < 32; reg++) {
		for (const low of [0, 1, 2, 3, 7, 0xe7]) {
			rvShapes.push(words([(reg << 27) | (low << 12) | (rd << 7) | 0x17, 0xdeadbeef, 0x13]));
		}
	}
}
add('riscv-shapes', 'RISCV', [], Buffer.concat(rvShapes));
let rng = 0x7a703230;
const random = Buffer.alloc(65539);
for (let i = 0; i < random.length; i++) {
	rng ^= rng << 13; rng ^= rng >>> 17; rng ^= rng << 5;
	random[i] = rng & 255;
}
for (const method of ['ARM', 'ARMT', 'PPC', 'SPARC', 'ARM64', 'IA64', 'RISCV']) {
	add(`${method.toLowerCase()}-random`, method, [], random);
}

const report = { oracle, version: execFileSync(oracle, ['i'], { encoding: 'utf8' }).split('\n').slice(0, 4).join('\n'), oracle_sha256: hash(fs.readFileSync(oracle)), cases: [] };
for (const c of cases) {
	const dir = path.join(root, c.name);
	fs.mkdirSync(dir, { recursive: true });
	const input = path.join(dir, 'plain.bin');
	const archive = path.join(dir, 'oracle.7z');
	fs.writeFileSync(input, c.bytes);
	const args = ['a', '-t7z', `-m0=${c.method}`, '-mhc=off', '-mtm=off', '-mta=off', '-mtc=off', archive, input];
	execFileSync(oracle, args, { stdio: 'pipe' });
	const full = fs.readFileSync(archive);
	const packedSize = Number(full.readBigUInt64LE(12));
	if (packedSize !== c.bytes.length) throw new Error(`${c.name}: unexpected packed size ${packedSize}`);
	const encoded = full.subarray(32, 32 + packedSize);
	if (encoded.equals(c.bytes)) throw new Error(`${c.name}: identity fixture`);
	const decoded = execFileSync(oracle, ['x', '-so', archive], { stdio: ['ignore', 'pipe', 'pipe'] });
	if (!decoded.equals(c.bytes)) throw new Error(`${c.name}: oracle roundtrip mismatch`);
	fs.writeFileSync(path.join(dir, 'encoded.bin'), encoded);
	report.cases.push({ name: c.name, method: c.method, properties: c.props, command: [oracle, ...args], bytes: c.bytes.length, changed_bytes: encoded.reduce((n, b, i) => n + (b !== c.bytes[i]), 0), plain_sha256: hash(c.bytes), encoded_sha256: hash(encoded), archive_sha256: hash(full) });
}
fs.writeFileSync(path.join(root, 'provenance.json'), JSON.stringify(report, null, 2) + '\n');
console.log(report.cases.map(c => `${c.name}: ${c.bytes} bytes, ${c.changed_bytes} changed`).join('\n'));
