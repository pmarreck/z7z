# 7z Cleanroom Functional Specification (Dirty-Team Output)

Status: Draft for clean-team implementation input  
Scope: 7z container format and coder-property semantics needed for compatible decoding  
Non-scope: source-level implementation structure, internal object model, memory/threading strategy

## 1. Format Overview

This specification defines the byte-level structure and validation behavior for `.7z` archives.

The archive is composed of:

1. Fixed 32-byte signature header.
2. Packed data region (possibly empty), from immediately after the signature header up to `NextHeaderOffset`.
3. Next-header region at `Start + 0x20 + NextHeaderOffset`, length `NextHeaderSize`.

The next-header region contains either:

- `kHeader` (plain header), or
- `kEncodedHeader` followed by `StreamsInfo` that describes a packed/encoded header stream which decodes to a `kHeader`.

All fixed-width integers are little-endian.  
Variable-width `UINT64` values use the 7z prefix encoding in Section 2.2.

### 1.1 Signature Header (32 bytes)

| Offset | Size | Field |
|---|---:|---|
| 0x00 | 6 | Signature bytes: `37 7A BC AF 27 1C` |
| 0x06 | 1 | Major version (MUST be `0`) |
| 0x07 | 1 | Minor version |
| 0x08 | 4 | `StartHeaderCRC` (CRC32 of bytes `0x0C..0x1F`) |
| 0x0C | 8 | `NextHeaderOffset` (REAL_UINT64) |
| 0x14 | 8 | `NextHeaderSize` (REAL_UINT64) |
| 0x1C | 4 | `NextHeaderCRC` (CRC32 of next-header region) |

### 1.2 High-Level Header Tree

Plain:

`kHeader -> [ArchiveProperties] [AdditionalStreamsInfo] [MainStreamsInfo] [FilesInfo] kEnd`

Encoded:

`kEncodedHeader -> StreamsInfo -> decode -> kHeader tree above`


## 2. Byte-Level Grammar

### 2.1 Primitive Types

- `BYTE`: 8-bit octet.
- `REAL_UINT32`: 4-byte little-endian unsigned.
- `REAL_UINT64`: 8-byte little-endian unsigned.
- `UINT64`: 7z variable-length unsigned (Section 2.2).
- `BOOL_VECTOR(N)`: `N` boolean items, packed MSB-first (`item0` = bit `0x80` of first byte).
- `BOOL_VECTOR2(N)`:
  - One prefix byte `AllAreDefined`.
  - If prefix != 0: all `N` booleans are true.
  - Else: read `BOOL_VECTOR(N)`.

### 2.2 7z Variable `UINT64` Encoding

Let first byte be `b0`.

- If bit7 of `b0` is `0`: value is `b0` (7-bit payload).
- Otherwise, the count of leading `1` bits in `b0` determines additional low-order bytes.
- Remaining non-prefix bits in `b0` are high bits of the value.
- Additional bytes are appended little-endian.

Equivalent table:

| First-byte form | Extra bytes | Value form |
|---|---:|---|
| `0xxxxxxx` | 0 | `xxxxxxx` |
| `10xxxxxx` | 1 | `(xxxxxx << 8) + y0` |
| `110xxxxx` | 2 | `(xxxxx << 16) + y[0..1]` |
| ... | ... | ... |
| `11111110` | 7 | `y[0..6]` |
| `11111111` | 8 | `y[0..7]` |

### 2.3 NID (Property/Node IDs)

| Hex | Name |
|---|---|
| 00 | `kEnd` |
| 01 | `kHeader` |
| 02 | `kArchiveProperties` |
| 03 | `kAdditionalStreamsInfo` |
| 04 | `kMainStreamsInfo` |
| 05 | `kFilesInfo` |
| 06 | `kPackInfo` |
| 07 | `kUnpackInfo` |
| 08 | `kSubStreamsInfo` |
| 09 | `kSize` |
| 0A | `kCRC` |
| 0B | `kFolder` |
| 0C | `kCodersUnpackSize` |
| 0D | `kNumUnpackStream` |
| 0E | `kEmptyStream` |
| 0F | `kEmptyFile` |
| 10 | `kAnti` |
| 11 | `kName` |
| 12 | `kCTime` |
| 13 | `kATime` |
| 14 | `kMTime` |
| 15 | `kWinAttrib` |
| 16 | `kComment` |
| 17 | `kEncodedHeader` |
| 18 | `kStartPos` |
| 19 | `kDummy` |

### 2.4 `StreamsInfo`

`StreamsInfo := [PackInfo] [UnpackInfo] [SubStreamsInfo] kEnd`

#### 2.4.1 `PackInfo`

`kPackInfo`  
`PackPos: UINT64`  
`NumPackStreams: UINT64`  
`kSize` + `PackSize[NumPackStreams]: UINT64`  
`[kCRC + DigestVector(NumPackStreams)]`  
`kEnd`

`DigestVector(N)` layout:

- `BOOL_VECTOR2(N)` indicating defined CRC entries
- `REAL_UINT32` values for defined entries only, in index order

#### 2.4.2 `UnpackInfo`

`kUnpackInfo`  
`kFolder`  
`NumFolders: UINT64`  
`External: BYTE`

- If `External == 0`: folder records follow inline.
- If `External != 0`: `DataStreamIndex: UINT64`, folder records are read from decoded AdditionalStreams buffer at that index.

Then:

`kCodersUnpackSize` + unpack size list (`UINT64` per coder output stream in folder order)  
`[kCRC + DigestVector(NumFolders)]`  
`kEnd`

#### 2.4.3 Folder Record

`NumCoders: UINT64`  
For each coder:

- `MainByte: BYTE`
  - bits `0..3`: `CodecIdSize`
  - bit `4`: complex coder flag (explicit in/out stream counts present)
  - bit `5`: coder properties present
  - bits `6..7`: reserved, MUST be `0`
- `CodecId[CodecIdSize]` (method ID bytes; big-endian identifier encoding)
- if complex flag: `NumInStreams: UINT64`, `NumOutStreams: UINT64`
- if props flag: `PropsSize: UINT64`, `Props[PropsSize]`

Graph linkage:

- `NumBindPairs = TotalOutStreams - 1`
- `BindPairs[NumBindPairs]` each: `InIndex: UINT64`, `OutIndex: UINT64`
- `NumPackedStreams = TotalInStreams - NumBindPairs`
  - if `NumPackedStreams == 1`: packed stream index is implicit (the only unbound input stream)
  - else: explicit `PackedIndex[NumPackedStreams]` (`UINT64` each)

#### 2.4.4 `SubStreamsInfo`

`kSubStreamsInfo`  
`[kNumUnpackStream + NumUnpackStreamsInFolder[NumFolders]: UINT64]`  
`[kSize + SubstreamSizes[]: UINT64]`  
`[kCRC + DigestVector(NumSubDigests)]`  
`kEnd`

Size rules:

- For each folder with `n` substreams:
  - if `n == 0`: contributes no substream sizes
  - if `n >= 1`: store first `n-1` sizes in `kSize`; final size is inferred as
    `FolderUnpackSize - sum(previous n-1 sizes)`.

Digest rules:

- If folder has exactly one substream and folder-level CRC is defined, substream digest is inherited.
- Otherwise, digest(s) come from `kCRC` substream digest vector.

### 2.5 `FilesInfo`

`kFilesInfo`  
`NumFiles: UINT64`  
Repeated file-property records until `kEnd`:

- `PropertyType: UINT64`
- if `PropertyType == kEnd`: stop
- `PropertySize: UINT64`
- `PropertyPayload[PropertySize]`

Recognized file properties:

- `kName (0x11)`:
  - `External: BYTE`
  - if external: `DataIndex: UINT64` and payload is externalized
  - name bytes are UTF-16LE, zero-terminated per file, concatenated exactly `NumFiles` entries
- `kEmptyStream (0x0E)`: `BOOL_VECTOR(NumFiles)`
- `kEmptyFile (0x0F)`: `BOOL_VECTOR(CountTrue(kEmptyStream))`
- `kAnti (0x10)`: `BOOL_VECTOR(CountTrue(kEmptyStream))`
- `kWinAttrib (0x15)`:
  - `BOOL_VECTOR2(NumFiles)` for attribute-defined flags
  - `External` switch + data source
  - `REAL_UINT32` values for defined entries
- `kCTime (0x12)`, `kATime (0x13)`, `kMTime (0x14)`, `kStartPos (0x18)`:
  - `BOOL_VECTOR2(NumFiles)` for defined flags
  - `External` switch + data source
  - `REAL_UINT64` values for defined entries
- `kDummy (0x19)`: ignorable padding/opaque bytes
- Unknown file properties in `FilesInfo` (typed-size records) MUST be skipped using declared `PropertySize` and MUST emit a non-fatal warning classification.

Time value interpretation:

- 64-bit NTFS FILETIME units (100 ns ticks since 1601-01-01 UTC).

File role derivation:

- If `kEmptyStream[file] == false`: regular stream-bearing file.
- If `kEmptyStream[file] == true`:
  - `kEmptyFile[emptyIndex] == false` => directory entry.
  - `kEmptyFile[emptyIndex] == true` => empty regular file.
- `kAnti` marks anti-items among empty-stream entries.


## 3. Method Identifiers

Method IDs are variable-length byte identifiers (up to 8 bytes).  
In folder coder records they are stored as raw bytes (`CodecId`) with explicit length.

Common IDs used in 7z archives:

| Method | ID (hex) |
|---|---|
| Copy | `00` |
| Delta | `03` |
| LZMA2 | `21` |
| LZMA | `030101` |
| PPMd | `030401` |
| BCJ | `03030103` |
| BCJ2 | `0303011B` |
| PPC | `03030205` |
| IA64 | `03030401` |
| ARM | `03030501` |
| ARMT | `03030701` |
| SPARC | `03030805` |
| ARM64 | `0A` |
| RISCV | `0B` |
| 7zAES | `06F10701` |

Method ID registry reference: `DOC/Methods.txt` in 7-Zip source.


## 4. Coder Graph Semantics (Format-Level)

Each folder defines a directed acyclic coder graph:

- Coder outputs are connected to coder inputs via `BindPairs`.
- Inputs not bound by a pair are pack-stream sources.
- Exactly one coder output remains unbound; that output is the folder’s final unpack stream.
- Substream partitioning further divides folder output in `SubStreamsInfo`.

Processing model:

1. Locate folder pack streams in packed data area via `PackPos + PackPositions`.
2. Execute coder pipeline according to folder graph.
3. Validate folder or substream CRCs where present.
4. Map resulting substreams to files according to `FilesInfo` empty-stream vectors and substream counts.

For encoded headers:

- The same folder graph model is used to decode header bytes from packed streams.
- Decoded header payload MUST start with `kHeader`.


## 5. Validation Rules

### 5.1 Required Structural Checks

- Signature MUST equal `37 7A BC AF 27 1C`.
- Major version MUST equal `0`.
- `StartHeaderCRC` MUST match CRC32 of bytes `[NextHeaderOffset, NextHeaderSize, NextHeaderCRC]`.
- `NextHeaderOffset + NextHeaderSize` MUST be representable and within file bounds.
- `NextHeaderCRC` MUST match CRC32 over the next-header region.
- `kHeader` and all nested sections MUST terminate with `kEnd` where required.
- In folder records:
  - reserved `MainByte` bits 6 and 7 MUST be `0`;
  - bind/pack indices MUST be in range and non-duplicate where uniqueness is required;
  - exactly one final unpack output must be derivable.
- In `FilesInfo`:
  - name payload length MUST be even (UTF-16LE code units);
  - exactly `NumFiles` NUL-terminated names MUST be present when `kName` exists.
- All declared byte counts and vectors MUST fit available input bytes.
- Any integer accumulation used for offsets/sizes MUST reject overflow.

### 5.2 CRC Rules

CRC algorithm:

- CRC-32 polynomial: `0xEDB88320`
- Initial value: `0xFFFFFFFF`
- Final digest: `crc ^ 0xFFFFFFFF`

CRC coverage points:

- Start-header CRC over bytes 12..31 of the 32-byte signature header.
- Next-header CRC over raw next-header bytes (`NextHeaderSize` bytes).
- Optional pack/folder/substream/file CRCs as declared by digest vectors.

### 5.3 Externalized Property Data

Properties with an `External` switch MUST obey:

- `External == 0`: payload comes from current property body.
- `External != 0`: next value is `DataIndex`, which MUST reference a decoded AdditionalStreams buffer.


## 6. Error Classification Rules

Implementations SHOULD classify failures into these buckets:

1. `NotArchive`
   - bad signature
   - impossible top-level geometry
   - missing required top-level header markers

2. `ChecksumError`
   - start-header CRC mismatch
   - next-header CRC mismatch
   - declared stream/folder/file CRC mismatch

3. `TruncatedInput`
   - declared size exceeds available bytes
   - EOF before completing mandatory structures

4. `UnsupportedFeature`
   - unsupported major version
   - unsupported coder method for decoding profile
   - reserved/invalid control values that the implementation elects not to process

5. `StructuralError`
   - out-of-range indices
   - inconsistent stream counts
   - invalid name-vector or property vector topology
   - arithmetic overflow in offset/size composition

6. `WarningOnly`
   - unknown ignorable file property skipped
   - dummy-padding nonzero bytes


## 7. Test Vectors

All vectors below are real archives generated with 7-Zip and then inspected as raw bytes.

### 7.1 TV-A: Plain header, Copy method, one file

Archive bytes (`plain-copy-nohdr.7z`, 112 bytes):

```hex
37 7A BC AF 27 1C 00 04 D1 47 FD 58 06 00 00 00
00 00 00 00 4A 00 00 00 00 00 00 00 DD C7 47 D5
68 65 6C 6C 6F 0A 01 04 06 00 01 09 06 00 07 0B
01 00 01 01 00 0C 06 00 08 0A 01 20 30 3A 36 00
00 05 01 11 15 00 68 00 65 00 6C 00 6C 00 6F 00
2E 00 74 00 78 00 74 00 00 00 14 0A 01 00 80 CA
91 2A 0D A4 DC 01 15 06 01 00 20 80 A4 81 00 00
```

Expected behavior:

- Accept as valid 7z archive.
- One file `hello.txt`, size 6, method `Copy`, CRC `0x363A3020`.

### 7.2 TV-B: Plain header, LZMA2 method, one file

Archive bytes (`plain-lzma2-hdr.7z`, 132 bytes):

```hex
37 7A BC AF 27 1C 00 04 6D E0 CC 1D 0A 00 00 00
00 00 00 00 5A 00 00 00 00 00 00 00 DA 13 AD AC
01 00 05 68 65 6C 6C 6F 0A 00 01 04 06 00 01 09
0A 00 07 0B 01 00 01 21 21 01 00 0C 06 00 08 0A
01 20 30 3A 36 00 00 05 01 19 0C 00 00 00 00 00
00 00 00 00 00 00 00 11 15 00 68 00 65 00 6C 00
6C 00 6F 00 2E 00 74 00 78 00 74 00 00 00 14 0A
01 00 80 CA 91 2A 0D A4 DC 01 15 06 01 00 20 80
A4 81 00 00
```

Expected behavior:

- Accept as valid.
- Folder coder method ID `0x21` (LZMA2), property byte `0x00`.

### 7.3 TV-C: Encoded header with 7zAES in header stream

Archive bytes (`encrypted-hdr.7z`, 206 bytes):

```hex
37 7A BC AF 27 1C 00 04 BA BF B2 1B 80 00 00 00
00 00 00 00 2E 00 00 00 00 00 00 00 C3 DE 66 78
2D 21 5A 68 8F 06 0A 16 80 6E 10 AF 56 B2 AA FF
F2 A5 89 19 83 63 2E 92 96 D7 BD 18 56 8F 20 64
A1 02 8C 6D 4D 84 23 D5 9C 21 16 7D 8F F4 85 C8
77 75 D7 F4 07 71 D5 A5 17 82 F6 D4 1B 09 43 7A
7A 3D 0C D3 E9 5C 7C 4B EA 7A 0C 78 B7 98 3C 88
8A A9 81 5D 26 E8 6F AC 19 2F 02 AE 6F 84 AE DA
58 61 E4 9A 4C 28 32 83 4A DB 66 9F 1C 65 AB 8F
3E 2A C6 A6 79 D8 FA 85 27 D5 B1 91 1D 0B 51 B8
17 06 10 01 09 70 00 07 0B 01 00 01 24 06 F1 07
01 12 53 0F C6 81 FE 2B 24 39 B9 8B 41 BC 48 B6
BD F2 2B 8C 0C 6A 0A 01 C2 B6 63 3B 00 00
```

Expected behavior:

- Without password: reject for encrypted header / cannot decode header.
- With correct password: decode to valid `kHeader`.

### 7.4 Mutation Failure Vectors

Using TV-A as baseline:

1. Mutate byte 0 (signature):
   - Expected: `NotArchive`.

2. Mutate byte 8 (`StartHeaderCRC` field):
   - Expected: checksum failure (`NotArchive` or `ChecksumError`, implementation class mapping allowed).

3. Mutate byte 28 (`NextHeaderCRC` field):
   - Expected: checksum failure when validating next-header bytes.


## 8. Non-Supported Method Handling Rules

### 8.1 Unknown Method IDs

- If a folder contains a coder method ID unsupported by the implementation’s decode profile:
  - metadata parse MAY continue;
  - extraction of affected folder/files MUST fail with `UnsupportedFeature`.

### 8.2 Unknown NID Handling

- In sections where entries are `type + size + payload` records (`ArchiveProperties`, `FilesInfo`, many optional subrecords):
  - unknown types MUST be skipped by `size`.
  - parser MUST continue processing subsequent records.
  - parser MUST emit a `WarningOnly` event for each skipped unknown typed-size property.
- For mandatory structural positions expecting a specific marker (`kHeader`, `kFolder`, `kCodersUnpackSize`, terminal `kEnd`):
  - mismatch MUST be treated as `StructuralError` or `UnsupportedFeature`.

### 8.3 Reserved/Invalid Control Bits

- Folder coder `MainByte` reserved bits 6 and 7 MUST be zero for this profile.
- Nonzero reserved bits SHOULD trigger `UnsupportedFeature`.

### 8.4 Encrypted Content Policy

- If `7zAES` coder is present and password/key material is unavailable:
  - implementation MUST report encrypted/unsupported extraction for impacted streams.
- If password is present but AES props are malformed:
  - MUST fail with `StructuralError` or `UnsupportedFeature`.
