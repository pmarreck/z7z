# External Archive Regression Checks

After `./build`, run:

```bash
nix develop -c tests/integration/verify-archive /path/to/archive.7z
```

The script accumulates independent oracle, C ABI/CLI, and Zig-native verification
outcomes. It never executes extracted contents and does not copy supplied archives
into the repository. It is an explicit-input diagnostic, not part of the default
suite; permanent public fixtures are covered by the archive unit tests.

On 2026-09-06, `RESET BAT-499-v1.7z` (1089 bytes, SHA-256
`145203bcad341c54aa2afafe5f954bf48724c902b0c851ee35b34ac5c202e312`)
passed all three paths at z7z commit `1567c2c`. Oracle listing reported LZMA:16,
one 7086-byte file, and CRC32 `623FB94D`. The installed sibling validate binary
also reported full validation. Its printed binary SHA-256 was
`9f7515a6565ac300057f99598f609d033a7713d8ec0dbd296ff9aa95cfd22d7e`.
The historical warning is not reproduced by these current binaries; its original
cause is not inferred from their success. No private archive contents are stored
here.
