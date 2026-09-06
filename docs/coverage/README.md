# Verification Coverage

`feature-matrix.json` inventories codec IDs and archive features. It is an initial
inventory, not a declaration of complete support. The pinned 7-Zip 26.03 binary
and its user manual were consulted as a black-box oracle; no implementation
source was read. The independently captured `7zzs i` codec list is retained in
`oracle-26.03-codecs.tsv`. Download and executable hashes are in the matrix.

## Commands

- `nix develop -c ./coverage --check` validates row uniqueness, catalog coverage,
  statuses, and referenced test names. It runs under `./test` and Mechatron CI.
- `nix develop -c ./coverage --complete` lists remaining gaps and returns failure
  until every inventoried feature has verification evidence and the inventory
  is declared complete. Do not remove the oracle while this command fails.
- `nix develop -c tests/unit/feature-matrix` tests the checker against valid and
  mutated row sets, including omissions, duplicates, false completion, and
  fabricated test references.

`partial` means implemented or tested subsets, `missing` means no implementation,
and `unknown` means insufficient evidence. `implemented_paths` records the code
surface, not independent validation of every parameter combination. `test_ids`
refer to existing test names; they do not by themselves prove full coverage.
The consistency check is a documentation control, not an automatic proof of
correctness or exhaustive coverage. Promotion to `verified` requires independent
fixtures, corruption/limit tests, and review of the stated feature domain.

Generic oracle codec listings include methods associated with other containers.
The Rar1/2/3/5 and AES256CBC entries remain unresolved for 7z coder-graph
eligibility. RAR containers themselves remain delegated to `rarz`; ZIP
containers are also outside this milestone. Do not infer 7z support merely from
a generic codec listing, or silently omit an unresolved method.

The matrix separately tracks the existing Zstd extension. Official 7-Zip 26.03
lists a Zstd container, but its codec list does not advertise the 7z extension
method `04 F7 11 01` used here.

Current gaps include full property domains, coder combinations, external streams,
prefix/SFX handling, split volumes, and compressed-input streaming. The production
oracle remains prohibited; its executable is used only for development tests.
