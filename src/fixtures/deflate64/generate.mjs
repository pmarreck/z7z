#!/usr/bin/env node
// Black-box fixture generation. No decoder or compression library is imported.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = path.dirname(fileURLToPath(import.meta.url));
const oracle = process.env.ORACLE ?? '/dev/shm/z7z-coverage-20260906.QOCJby/7zzs';
const version = execFileSync(oracle, ['i'], { encoding: 'utf8' });
if (!version.includes('26.03')) throw new Error('Expected oracle 26.03');
const sha256 = data => createHash('sha256').update(data).digest('hex');
let state = 0x6437abcd;
const random = Buffer.alloc(49152);
for (let i = 0; i < random.length; i++) {
	state ^= state << 13; state ^= state >>> 17; state ^= state << 5;
	random[i] = state >>> 24;
}
const cases = {
	fixed: Buffer.from('Hello Deflate64!\n'),
	stored: random,
	dynamic: Buffer.from('Deflate64 bounded history, literal trees and repeated lengths.\n'.repeat(500)),
	history49152: Buffer.concat([random, random]),
	length285: Buffer.alloc(70000, 65),
};
const manifest = {
	oracle: version.split('\n').find(line => line.includes('26.03')),
	oracle_sha256: sha256(fs.readFileSync(oracle)),
	random: 'xorshift32 seed 0x6437abcd, shifts 13/17/5; high byte; 49152 bytes',
	cases: [],
};
for (const [name, plain] of Object.entries(cases)) {
	const input = `${name}.plain`;
	const archive = `${name}.7z`;
	if (fs.existsSync(path.join(root, archive))) throw new Error(`Refusing to overwrite ${archive}`);
	fs.writeFileSync(path.join(root, input), plain);
	const args = ['a', '-t7z', '-m0=Deflate64', '-mx=9', '-mhc=off', '-ms=off', '-mtm=off', '-mta=off', '-mtc=off', archive, input];
	execFileSync(oracle, args, { cwd: root });
	const unpacked = execFileSync(oracle, ['x', '-so', archive], { cwd: root });
	if (!unpacked.equals(plain)) throw new Error(`Oracle mismatch: ${name}`);
	const bytes = fs.readFileSync(path.join(root, archive));
	const packedSize = Number(bytes.readBigUInt64LE(12));
	const raw = bytes.subarray(32, 32 + packedSize);
	fs.writeFileSync(path.join(root, `${name}.raw`), raw);
	manifest.cases.push({ name, command: [oracle, ...args], plain_size: plain.length, raw_size: raw.length,
		first_block_type: (raw[0] >>> 1) & 3, plain_sha256: sha256(plain), raw_sha256: sha256(raw), archive_sha256: sha256(bytes) });
}
fs.writeFileSync(path.join(root, 'provenance.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(JSON.stringify(manifest, null, 2));
