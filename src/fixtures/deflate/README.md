# Deflate Compatibility Fixtures

Generated 2026-09-04 with the black-box 7-Zip 26.00 executable. No reference
implementation source was consulted. These fixtures require no oracle at test
runtime. They establish coverage for these combinations, not all 7z features.

Oracle executable SHA-256:
`be1d074f196bf5f351b21731572fd9337a42813a3ec20d734d41e9897f4167ec`.

Each archive contains one solid folder with two files, in this order:

- `a.bin`: ASCII `Deflate fixture: ` repeated 16384 times, 278528 bytes.
  SHA-256 `6edcc1991418be8887128e64a69975d5f476b917f15e8ca7858f1c3e0f863146`.
- `b.bin`: hex `90e810000000e920000000` repeated 8192 times, 90112 bytes.
  SHA-256 `da9f7d89f175a6fd90003b262c797a8a38b09682040f0fdf3cd8eebc14b7e0fe`.

All generation commands used:
`7zz a -t7z -mhc=off -mmt=1 -mtc=off -mta=off -mtm=off <options> <archive> a.bin b.bin`.

| Archive | Options | SHA-256 |
| --- | --- | --- |
| plain.7z | `-m0=Deflate` | `43377624718743ae84b8c277bde2d7819a10a7cdc6b724973c5c838c20895b3c` |
| bcj.7z | `-m0=BCJ -m1=Deflate` | `85963ee0c9508bb8b0ce1d5cfb29690dc6134c8c7946bd4700bcdb4ca0c0eab1` |
| bcj2.7z | `-m0=BCJ2 -m1=Deflate -m2=Deflate -m3=Deflate -mb0:1 -mb0s1:2 -mb0s2:3` | `4f70310e9ece54ecd8ea95314a22fb3f6c392895934847c35a58bf10db805263` |
| encrypted.7z | `-m0=Deflate -pfixture-password -mhe=on` | `8560f5977c2eb1c0a6cf443cd70ba82db34e26f8636a0326cb34416cd5dc1602` |

Every archive passed `7zz t -pfixture-password`. Encrypted generation uses random
salt/IV, so regeneration need not produce the same archive hash. Archive tests
compare every decoded byte against independently constructed payloads, verify
through slice and short-read range APIs under an allocation cap, and reject
corrupted packed data. CLI tests cover extraction and verification through the
C ABI. The existing range adapter still retains compressed folder input.
