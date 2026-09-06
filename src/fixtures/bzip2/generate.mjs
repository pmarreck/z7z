import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

const oracle = process.argv[2];
if (!oracle) throw new Error('Pass the independent 7zzs executable path');
const root = dirname(fileURLToPath(import.meta.url));
const temp = mkdtempSync(join(tmpdir(), 'z7z-bzip2-fixtures-'));
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const cases = [
	['small', Buffer.from('BZip2 from independent 7-Zip 26.03.\nBinary: \x00\x01\x7f\xff\n', 'latin1')],
	['rle-expansion', Buffer.alloc(1_200_000, 0x41)],
	['multiblock', Buffer.from(Array.from({ length: 210_000 }, (_, i) => i % 251))],
	['filter-swap4', readFileSync(join(root, '../filters/swap4/encoded.bin'))],
];
const manifest = {
	oracle: '7-Zip 26.03 static 7zzs (black-box execution only)',
	oracle_sha256: sha256(readFileSync(oracle)),
	generated: new Date().toISOString(),
	command: '7zzs a -t7z -m0=BZip2 -md=100k -mx=9 -mmt=1 -mhc=off -mtc=off -mtm=off -mta=off ARCHIVE INPUT',
	packed_payload: 'Archive bytes [32, 32 + uint64le(header[12..20])) with uncompressed next header; single packed stream.',
	cases: [],
};
for (const [name, expected] of cases) {
	const input = join(temp, `${name}.bin`);
	const archive = join(temp, `${name}.7z`);
	writeFileSync(input, expected);
	execFileSync(oracle, ['a', '-t7z', '-m0=BZip2', '-md=100k', '-mx=9', '-mmt=1', '-mhc=off', '-mtc=off', '-mtm=off', '-mta=off', archive, input]);
	const listing = execFileSync(oracle, ['l', '-slt', archive], { encoding: 'utf8' });
	assert.match(listing, /Method = BZip2/);
	const decoded = execFileSync(oracle, ['x', '-so', archive], { maxBuffer: 4_000_000 });
	assert.deepEqual(decoded, expected);
	const bytes = readFileSync(archive);
	const packed = bytes.subarray(32, 32 + Number(bytes.readBigUInt64LE(12)));
	assert.equal(packed.subarray(0, 3).toString(), 'BZh');
	assert.equal(Number(listing.match(/^Packed Size = (\d+)$/m)[1]), packed.length);
	writeFileSync(join(root, `${name}.7z`), bytes);
	writeFileSync(join(root, `${name}.bz2`), packed);
	manifest.cases.push({ name, size: expected.length, crc32: listing.match(/^CRC = ([A-F0-9]+)$/m)[1], input_sha256: sha256(expected), archive_sha256: sha256(bytes), packed_sha256: sha256(packed), packed_size: packed.length,
		...(name === 'filter-swap4' ? { input_source: '../filters/swap4/encoded.bin (independent filter oracle fixture)' } : {}),
	});
}
writeFileSync(join(root, 'provenance.json'), JSON.stringify(manifest, null, 2) + '\n');
process.stdout.write(JSON.stringify(manifest, null, 2) + '\n');
