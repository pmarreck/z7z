# PPMd Reuse Audit

Date: 2026-09-06 EDT. Scope: potential reuse of rarz PPMd in z7z, not a
full-codebase security review. Peter authorized inspection and assessment;
implementation and original 7-Zip source inspection remain outside this audit.

## Decision

The rarz statistical model is a plausible reuse candidate, but its current API
is unsuitable for direct 7z integration. Compatibility and provenance are not
yet established sufficiently to recommend production adoption. No decoder was
copied, adapted, or integrated during this audit.

Reviewed rarz HEAD `80ec687108dadc447da8b1048892e1380cba78ef`, with unchanged
`src/lib/decompress/ppm.zig`. Its last change is
`3ddbbdd89e5f7ffb088b004404a5639118755c26`; file SHA-256 is
`8f8d06f0967719cbfaa2c47135f9d9a10244b96efc76fc806255408522ed5ae4`.
The sibling's existing PLAN.md modification was left untouched.

## Confirmed Interface Mismatches

1. RAR initialization is coupled to its compressed stream. `ppm.zig:1197`
   reads reset/order/escape flags and an integer-megabyte model size, then
   initializes its carryless range coder. z7z's existing oracle probes use
   separate order and byte-sized memory properties, including 64 KiB and odd
   sizes. Passing a 7z stream to this initializer is not a valid adapter.
2. EOF is suppressed. `ppm.zig:70` returns zero when its BitReader fails.
   A ReleaseSafe probe using the hard-bounded reader and only `{0x21, 0}`
   returned successful initialization despite having no range-state bytes.
   This violates the proposed strict initializer contract; it does not prove
   that rarz accepts a corrupt archive through its complete verification path.
3. Backing allocation failure loses its identity. `ppm.zig:288` accepts a
   megabyte count, allocates a rounded pool plus overhead, and returns false on
   allocation failure. A failing-allocator probe confirmed that `decodeInit`
   returns false instead of OutOfMemory. z7z requires separate malformed-input,
   resource-limit, and backing-allocation errors.
4. There is no 7z completion contract. `decodeChar` at `ppm.zig:1223` emits one
   symbol and mutates the model; RAR-specific escape/end handling is in
   `unpack29.zig:883`. A future adapter must establish exact output size,
   permitted terminal range state, input consumption, and truncation handling
   against the 7z oracle. Neither a CRC match nor the RAR wrapper replaces that.

## Reusable Parts And Limits

The statistical state, SEE2 escape estimation, frequency rescaling, context
updates, and offset-based suballocator are implemented in Zig. `PpmModel.init`
accepts a caller allocator; there is no C decompressor or subprocess in this
module. Symbol-at-a-time decoding is promising for bounded output and BCJ2 pull
integration, provided error and completion rules are established first.

The model and range coder are coupled throughout symbol decoding. Several
initialization helpers are private, and rarz's build does not expose a standalone
PPMd Zig module. Simply pinning rarz and importing PpmModel would not solve these
contract differences. Memory-pool sizing and exhaustion-triggered restarts also
affect decoding; rounding every 7z model to a megabyte would need compatibility
proof and cannot be assumed harmless.

The [official 7z overview](https://www.7-zip.org/7z.html) identifies modified
PPMdH but does not specify its bit-exact modifications. No claim is made here
that the statistical model or range coding is already 7z-compatible. Arbitrary
corruption safety of the offset-based model was not exhaustively audited.

## Provenance Finding

The candidate is committed code, not an uncommitted experiment. rarz's LICENSE
offers MIT terms, while `ppm.zig:3` and commit 3ddbbdd describe a faithful UnRAR
reference port. README.md:158 describes specification-only implementation;
RAR_SPECIFICATION.md:17 describes separate source-exposed specification and
unexposed implementation lanes. These statements could be reconciled by actual
lane separation, but the inspected records do not establish that the August 27
replacement followed it.

The provenance audit read only `license.txt` and `acknow.txt` from RARLAB's
[7.2.4 source archive](https://www.rarlab.com/rar/unrarsrc-7.2.4.tar.gz) and
[7.2.7 source archive](https://www.rarlab.com/rar/unrarsrc-7.2.7.tar.gz).
Acknowledgments support public-domain PPMII/range-coder ancestry. The package
license carries additional terms and notice requirements. Those records do not
establish that every later UnRAR contribution potentially represented in this
Zig port is public domain or available under MIT alone. This is an unresolved
chain-of-rights question, not a finding that reuse is prohibited or a legal
opinion.

Needed evidence: the August 27 implementation's exact input version and digest
(header 7.20 versus specification 7.2.4), its source-access/specification-lane
record, and the applicable component notices. Original 7-Zip implementation
source remains off-limits. Detailed audit report:
`/tmp/dispatch-log/z7z-ppmd-provenance-final.md`.

## Existing Test Evidence

The independent test audit reran all five PPM scalar/structure tests in
ReleaseSafe; they passed. The PPM mode-switch test also passed through the rarz
test root, but `unpack29.zig:1626` returns success on readTables errors and its
conditional assertion also permits the wrong mode without failing. It cannot
establish successful PPM initialization.

Two retained RAR fixtures contain nontrivial XML/prose payloads of 223,298 and
243,893 bytes. Fresh UnRAR integrity checks passed for both. The inspected rarz
root gate asserts VERIFIED; its CLI byte-for-byte extraction gate excludes
these fixtures. Exact payload equality was not freshly tested by this audit,
and no 7z compatibility follows from these RAR checks. Allocation failures,
PPM-specific prefix rejection, learned-state resets, and actually reached
high-order contexts lack demonstrated coverage in the inspected gates.

The existing z7z draft corpus has eight independent 7z fixtures and six failing
decoder acceptance groups. It remains unintegrated, with no decoder. Its
memory-pressure and nominal high-order cases likewise do not prove internal
restart counts or reached model depth. Detailed test commands, oracle results,
fixture hashes, and limitations are in
`/tmp/dispatch-log/z7z-ppmd-test-evidence-final.md`.

## Executed Contract Probes

Two audit-only tests in `/dev/shm/z7z-ppmd-audit-20260906/strict_contract_probe.zig`
import the unchanged rarz module. Both compiled and failed at runtime as expected:

```text
expected error.EndOfStream, found true
expected error.OutOfMemory, found false
0 passed; 0 skipped; 2 failed.
```

Command (Zig 0.16.0, no sibling source changes):

```bash
nix develop -c zig test -O ReleaseSafe -target x86_64-linux-musl \
  --dep ppm -Mroot=/dev/shm/z7z-ppmd-audit-20260906/strict_contract_probe.zig \
  -O ReleaseSafe -target x86_64-linux-musl \
  -Mppm=/home/pmarreck/Code/rarz/src/lib/decompress/ppm.zig -lc \
  --cache-dir /dev/shm/z7z-ppmd-audit-20260906/cache --test-filter 'audit strict'
```

These are proposed z7z contract tests, not additions to rarz's test suite.
They remain isolated from z7z's passing production suite.

## Next Gates

- Resolve the provenance discrepancy before copying or adapting the model.
- After explicit implementation approval, prove exact bytes on the existing
  eight 7z oracle fixtures before designing a shared production abstraction.
- Separate raw-model initialization from RAR flags; preserve byte-sized model
  memory, allocator ownership, allocation failure, and strict input errors.
- Prove high-order contexts, memory-pressure restarts, every packed prefix,
  corrupt inputs, sink failure, and independent model lifetimes.
- Only then expose a pinned shared module with separate RAR/7z adapters, retain
  both consumers' independent regression suites, and measure production builds.

PPMd remains unsupported in z7z. No original 7-Zip implementation source was
opened, no production oracle was added, and no sibling files were changed.
