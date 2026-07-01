![alpacki](https://github.com/vshakitskiy/alpacki/blob/mistress/priv/banner.jpg?raw=true)

[![Package Version](https://img.shields.io/hexpm/v/alpacki)](https://hex.pm/packages/alpacki)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/alpacki/)

alpacki is an HPACK ([RFC 7541](https://datatracker.ietf.org/doc/html/rfc7541))
implementation for Gleam. It handles header compression for HTTP/2 connections.

```sh
gleam add alpacki@3
```

# Encoding and decoding

Each side of an HTTP/2 connection maintains its own dynamic table. Headers are
encoded into compact header block fragments for transmission, and decoded back
on the receiving side.

Encoding from a list of headers:
```gleam
let table = alpacki.new_dynamic(4096)
let headers = [
  alpacki.HeaderField(":method", "GET", alpacki.WithIndexing),
  alpacki.HeaderField(":path", "/", alpacki.WithIndexing),
  alpacki.HeaderField(":scheme", "https", alpacki.WithIndexing),
]

let #(data, table) =
  alpacki.encode_header_block(headers, table, huffman: True)
```

Decoding headers from raw bits:
```gleam
let table = alpacki.new_dynamic(4096)
let assert Ok(#(headers, table)) = alpacki.decode_header_block(data, table)
```

The `Indexing` type on each `HeaderField` controls the wire representation:
`WithIndexing` adds the entry to the dynamic table for future reference,
`WithoutIndexing` sends it without storing, and `NeverIndexed` signals that
the value is sensitive and must never be compressed by intermediaries.

# Resizing the dynamic table

When the remote peer sends a SETTINGS frame that changes
`SETTINGS_HEADER_TABLE_SIZE`, call `resize_dynamic` on the **encoder's**
table. The next `encode_header_block` call will automatically prepend the
required size update instructions before the header fields.

```gleam
// Remote peer reduced the table size to 2048 bytes.
let encoder_table = alpacki.resize_dynamic(encoder_table, 2048)

// The next encoded block will start with a size update instruction.
let #(data, encoder_table) =
  alpacki.encode_header_block(headers, encoder_table, huffman: True)
```

On the decoder side, `expect_table_size_update` can optionally be used to enforce the peer sends the size update, `decode_header_block` processes any size update instructions at the start of a block automatically.

# Primitives

Beyond the high-level API, alpacki exposes the individual HPACK primitives.
If you are building on primitives instead of `encode_header_block` /
`decode_header_block`, you are responsible for emitting dynamic table size
updates yourself with `encode_table_size_update` when the maximum table size
changes.

Integer:
```gleam
let encoded = alpacki.encode_integer(120, prefix: 5)
let assert Ok(#(120, <<>>)) = alpacki.decode_integer(encoded, prefix: 5)
```

String Literal:
```gleam
let encoded = alpacki.encode_string_literal(<<"Wibble":utf8>>, huffman: False)
let assert Ok(#(decoded, <<>>)) = alpacki.decode_string_literal(encoded)
```

Huffman:
```gleam
let encoded = alpacki.encode_huffman(<<"www.example.com":utf8>>)
let assert Ok(decoded) = alpacki.decode_huffman(encoded)
```

Further documentation can be found at <https://hexdocs.pm/alpacki>.
