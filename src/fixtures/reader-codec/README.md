# Streaming Reader Fixture

`zeros-257m.lzma` is a raw LZMA1 stream produced by XZ Utils 5.8.3:

```bash
head -c 269484032 /dev/zero | xz --format=raw --lzma1=lc=3,lp=0,pb=2,dict=64KiB -c > zeros-257m.lzma
```

It has an end marker and decodes to 257 MiB of zero bytes. Tests use a 128 KiB
fixed allocator and a non-retaining writer to prove decoded length does not
determine allocation size. Input is delivered in fragments. No oracle source
was consulted.

- Compressed size: 38,089 bytes.
- Compressed SHA-256: `d63673834dcc7fbd87fb64bc7ec6d7acaddbdfb626c743cc36bb8bed9e0aba63`.
- Decoded SHA-256 (independently decoded with xz): `053eadfdec682cf16f3f8704c7609c57868dd75765e08dc5a7491f5d06bcb74d`.
- Properties: `5d 00 00 01 00` (lc=3, lp=0, pb=2, dictionary=65536).

Small inline fixtures in `../../codec_reader_tests.zig` record their producer
commands. Both xz marker-bearing output and 7zz 26.02 size-delimited output
are covered without requiring an oracle executable at test time.
