import alpacki

// Decode
// =============================================================================

// Representations (RFC 7541 C.2)
// -----------------------------------------------------------------------------

pub fn decode_literal_with_indexing_new_name_test() {
  let table = alpacki.new_dynamic(4096)
  let assert Ok(decoded) =
    alpacki.decode_header_block(
      <<0x40, 0x0a, "custom-key":utf8, 0x0d, "custom-header":utf8>>,
      table,
    )
  assert decoded.headers == [#(<<"custom-key":utf8>>, <<"custom-header":utf8>>)]
  assert decoded.remaining == <<>>
  assert alpacki.dynamic_length(decoded.dynamic_table) == 1
  assert alpacki.dynamic_size(decoded.dynamic_table) == 55
  assert decoded.decoded_size == 55
}

pub fn decode_literal_without_indexing_indexed_name_test() {
  let table = alpacki.new_dynamic(4096)
  let assert Ok(decoded) =
    alpacki.decode_header_block(<<0x04, 0x0c, "/sample/path":utf8>>, table)
  assert decoded.headers == [#(<<":path":utf8>>, <<"/sample/path":utf8>>)]
  assert alpacki.dynamic_length(decoded.dynamic_table) == 0
}

pub fn decode_literal_never_indexed_new_name_test() {
  let table = alpacki.new_dynamic(4096)
  let assert Ok(decoded) =
    alpacki.decode_header_block(
      <<0x10, 0x08, "password":utf8, 0x06, "secret":utf8>>,
      table,
    )
  assert decoded.headers == [#(<<"password":utf8>>, <<"secret":utf8>>)]
}

pub fn decode_indexed_test() {
  let table = alpacki.new_dynamic(4096)
  let assert Ok(decoded) = alpacki.decode_header_block(<<0x82>>, table)
  assert decoded.headers == [#(<<":method":utf8>>, <<"GET":utf8>>)]
}

// Sequential Requests (RFC 7541 C.3)
// -----------------------------------------------------------------------------

pub fn decode_c3_sequential_requests_test() {
  let table = alpacki.new_dynamic(4096)

  let assert Ok(decoded) =
    alpacki.decode_header_block(
      <<0x82, 0x86, 0x84, 0x41, 0x0f, "www.example.com":utf8>>,
      table,
    )
  assert decoded.headers
    == [
      #(<<":method":utf8>>, <<"GET":utf8>>),
      #(<<":scheme":utf8>>, <<"http":utf8>>),
      #(<<":path":utf8>>, <<"/":utf8>>),
      #(<<":authority":utf8>>, <<"www.example.com":utf8>>),
    ]
  assert alpacki.dynamic_length(decoded.dynamic_table) == 1
  assert alpacki.dynamic_size(decoded.dynamic_table) == 57

  // :authority reused from dynamic table
  let assert Ok(decoded) =
    alpacki.decode_header_block(
      <<0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, "no-cache":utf8>>,
      decoded.dynamic_table,
    )
  assert decoded.headers
    == [
      #(<<":method":utf8>>, <<"GET":utf8>>),
      #(<<":scheme":utf8>>, <<"http":utf8>>),
      #(<<":path":utf8>>, <<"/":utf8>>),
      #(<<":authority":utf8>>, <<"www.example.com":utf8>>),
      #(<<"cache-control":utf8>>, <<"no-cache":utf8>>),
    ]
  assert alpacki.dynamic_length(decoded.dynamic_table) == 2
  assert alpacki.dynamic_size(decoded.dynamic_table) == 110

  // :authority shifted to index 63 after cache-control added
  let assert Ok(decoded) =
    alpacki.decode_header_block(
      <<
        0x82, 0x87, 0x85, 0xbf, 0x40, 0x0a, "custom-key":utf8, 0x0c,
        "custom-value":utf8,
      >>,
      decoded.dynamic_table,
    )
  assert decoded.headers
    == [
      #(<<":method":utf8>>, <<"GET":utf8>>),
      #(<<":scheme":utf8>>, <<"https":utf8>>),
      #(<<":path":utf8>>, <<"/index.html":utf8>>),
      #(<<":authority":utf8>>, <<"www.example.com":utf8>>),
      #(<<"custom-key":utf8>>, <<"custom-value":utf8>>),
    ]
  assert alpacki.dynamic_length(decoded.dynamic_table) == 3
  assert alpacki.dynamic_size(decoded.dynamic_table) == 164
}

// Huffman
// -----------------------------------------------------------------------------

pub fn decode_huffman_encoded_value_test() {
  let table = alpacki.new_dynamic(4096)
  let assert Ok(decoded) =
    alpacki.decode_header_block(
      <<
        0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90,
        0xf4, 0xff,
      >>,
      table,
    )
  assert decoded.headers
    == [#(<<":authority":utf8>>, <<"www.example.com":utf8>>)]
}

// Size Update
// -----------------------------------------------------------------------------

pub fn decode_size_update_before_headers_test() {
  let table = alpacki.new_dynamic(4096)
  let assert Ok(decoded) =
    alpacki.decode_header_block(<<0x3f, 0x61, 0x82>>, table)
  assert decoded.headers == [#(<<":method":utf8>>, <<"GET":utf8>>)]
  assert alpacki.dynamic_max_size(decoded.dynamic_table) == 128
}

pub fn decode_size_update_to_zero_clears_table_test() {
  let table = alpacki.new_dynamic(4096)
  let assert Ok(decoded) =
    alpacki.decode_header_block(<<0x41, 0x03, "ewe":utf8>>, table)
  assert alpacki.dynamic_length(decoded.dynamic_table) == 1
  let assert Ok(decoded) =
    alpacki.decode_header_block(<<0x20, 0x82>>, decoded.dynamic_table)
  assert alpacki.dynamic_length(decoded.dynamic_table) == 0
  assert alpacki.dynamic_max_size(decoded.dynamic_table) == 0
}

pub fn decode_consecutive_size_updates_test() {
  let table =
    alpacki.new_dynamic(4096)
    |> alpacki.add_dynamic(<<"server":utf8>>, <<"ewe":utf8>>)
  assert alpacki.dynamic_length(table) == 1
  // Two size updates (0 then 128) followed by indexed :method GET.
  // These are the same bytes encode_pending_double_resize_test produces.
  let assert Ok(decoded) =
    alpacki.decode_header_block(<<0x20, 0x3f, 0x61, 0x82>>, table)
  assert decoded.headers == [#(<<":method":utf8>>, <<"GET":utf8>>)]
  assert alpacki.dynamic_length(decoded.dynamic_table) == 0
  assert alpacki.dynamic_max_size(decoded.dynamic_table) == 128
}

pub fn decode_expected_size_update_present_test() {
  let table =
    alpacki.new_dynamic(4096)
    |> alpacki.expect_table_size_update
  let assert Ok(decoded) =
    alpacki.decode_header_block(<<0x3f, 0x61, 0x82>>, table)
  assert decoded.headers == [#(<<":method":utf8>>, <<"GET":utf8>>)]
  assert alpacki.dynamic_max_size(decoded.dynamic_table) == 128
}

// Errors
// -----------------------------------------------------------------------------

pub fn decode_empty_block_test() {
  let table = alpacki.new_dynamic(4096)
  let assert Ok(decoded) = alpacki.decode_header_block(<<>>, table)
  assert decoded.headers == []
}

pub fn decode_invalid_index_test() {
  let table = alpacki.new_dynamic(4096)
  assert alpacki.decode_header_block(<<0xfe>>, table)
    == Error(alpacki.InvalidTableIndex)
}

// A header block fragment that ends mid-field stops decoding and returns the
// unconsumed bytes instead of erroring, supporting CONTINUATION reassembly.
pub fn decode_truncated_data_test() {
  let table = alpacki.new_dynamic(4096)
  // Name "custom-key" (10 bytes) is complete; the 13-byte value declares
  // "custom-header" but only its first 5 bytes ("custo") have arrived.
  let truncated = <<0x40, 0x0a, "custom-key":utf8, 0x0d, "custo":utf8>>
  let assert Ok(decoded) = alpacki.decode_header_block(truncated, table)
  assert decoded.headers == []
  assert decoded.remaining == truncated
  assert alpacki.dynamic_length(decoded.dynamic_table) == 0

  // Feeding the rest of the value completes the header field.
  let assert Ok(decoded) =
    alpacki.decode_header_block(
      <<decoded.remaining:bits, "m-header":utf8>>,
      decoded.dynamic_table,
    )
  assert decoded.headers == [#(<<"custom-key":utf8>>, <<"custom-header":utf8>>)]
  assert decoded.remaining == <<>>
}

pub fn decode_truncated_size_update_test() {
  let table = alpacki.new_dynamic(4096)
  // 0x3f starts a size update whose value continues past the prefix, but the
  // continuation byte is missing.
  let truncated = <<0x3f>>
  let assert Ok(decoded) = alpacki.decode_header_block(truncated, table)
  assert decoded.headers == []
  assert decoded.remaining == truncated
  assert alpacki.dynamic_max_size(decoded.dynamic_table) == 4096
}

// Index 0 is invalid per RFC 7541 Section 6.1
pub fn decode_indexed_zero_test() {
  let table = alpacki.new_dynamic(4096)
  assert alpacki.decode_header_block(<<0x80>>, table)
    == Error(alpacki.InvalidTableIndex)
}

// HPACK treats names as opaque octets (RFC 7541 Section 1.3)
pub fn decode_opaque_header_name_test() {
  let table = alpacki.new_dynamic(4096)
  let assert Ok(decoded) =
    alpacki.decode_header_block(
      <<0x40, 0x03, "FOO":utf8, 0x03, "bar":utf8>>,
      table,
    )
  assert decoded.headers == [#(<<"FOO":utf8>>, <<"bar":utf8>>)]
}

pub fn decode_missing_expected_size_update_test() {
  let table =
    alpacki.new_dynamic(4096)
    |> alpacki.expect_table_size_update
  assert alpacki.decode_header_block(<<0x82>>, table)
    == Error(alpacki.MissingSizeUpdate)
}

// Representations
// -----------------------------------------------------------------------------

pub fn encode_indexed_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, _table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":method":utf8>>,
          <<"GET":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x82>>
}

// FullMatch always uses indexed representation regardless of indexing flag
pub fn encode_full_match_ignores_indexing_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, _table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":method":utf8>>,
          <<"GET":utf8>>,
          alpacki.NeverIndexed,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x82>>
}

pub fn encode_literal_with_indexing_indexed_name_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":status":utf8>>,
          <<"418":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x48, 0x03, "418":utf8>>
  assert alpacki.dynamic_length(table) == 1
}

pub fn encode_literal_without_indexing_indexed_name_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":path":utf8>>,
          <<"/sample/path":utf8>>,
          alpacki.WithoutIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x04, 0x0c, "/sample/path":utf8>>
  assert alpacki.dynamic_length(table) == 0
}

pub fn encode_literal_never_indexed_indexed_name_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":status":utf8>>,
          <<"418":utf8>>,
          alpacki.NeverIndexed,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x18, 0x03, "418":utf8>>
  assert alpacki.dynamic_length(table) == 0
}

pub fn encode_literal_with_indexing_new_name_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<"custom-key":utf8>>,
          <<"custom-header":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded
    == <<0x40, 0x0a, "custom-key":utf8, 0x0d, "custom-header":utf8>>
  assert alpacki.dynamic_length(table) == 1
  assert alpacki.dynamic_size(table) == 55
}

pub fn encode_literal_without_indexing_new_name_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<"x-custom":utf8>>,
          <<"value":utf8>>,
          alpacki.WithoutIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x00, 0x08, "x-custom":utf8, 0x05, "value":utf8>>
  assert alpacki.dynamic_length(table) == 0
}

pub fn encode_literal_never_indexed_new_name_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, _table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<"password":utf8>>,
          <<"secret":utf8>>,
          alpacki.NeverIndexed,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x10, 0x08, "password":utf8, 0x06, "secret":utf8>>
}

// HPACK treats names as opaque octets (RFC 7541 Section 1.3)
pub fn encode_uppercase_header_name_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, _table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<"FOO":utf8>>,
          <<"bar":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x40, 0x03, "FOO":utf8, 0x03, "bar":utf8>>
}

// Sequential Requests (RFC 7541 C.3)
// -----------------------------------------------------------------------------

pub fn encode_c3_sequential_requests_test() {
  let table = alpacki.new_dynamic(4096)

  let #(encoded, table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":method":utf8>>,
          <<"GET":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<":scheme":utf8>>,
          <<"http":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<":path":utf8>>,
          <<"/":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<":authority":utf8>>,
          <<"www.example.com":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x82, 0x86, 0x84, 0x41, 0x0f, "www.example.com":utf8>>

  // :authority now FullMatch(62) from dynamic table
  let #(encoded, table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":method":utf8>>,
          <<"GET":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<":scheme":utf8>>,
          <<"http":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<":path":utf8>>,
          <<"/":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<":authority":utf8>>,
          <<"www.example.com":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<"cache-control":utf8>>,
          <<"no-cache":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, "no-cache":utf8>>

  // :authority shifted to index 63
  let #(encoded, _table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":method":utf8>>,
          <<"GET":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<":scheme":utf8>>,
          <<"https":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<":path":utf8>>,
          <<"/index.html":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<":authority":utf8>>,
          <<"www.example.com":utf8>>,
          alpacki.WithIndexing,
        ),
        alpacki.HeaderField(
          <<"custom-key":utf8>>,
          <<"custom-value":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded
    == <<
      0x82, 0x87, 0x85, 0xbf, 0x40, 0x0a, "custom-key":utf8, 0x0c,
      "custom-value":utf8,
    >>
}

// Huffman
// -----------------------------------------------------------------------------

pub fn encode_huffman_value_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, _table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":authority":utf8>>,
          <<"www.example.com":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      True,
    )
  assert encoded
    == <<
      0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90,
      0xf4, 0xff,
    >>
}

// Pending Resize
// -----------------------------------------------------------------------------

pub fn encode_pending_resize_test() {
  let table =
    alpacki.new_dynamic(4096)
    |> alpacki.resize_dynamic(128)
  let #(encoded, table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":method":utf8>>,
          <<"GET":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x3f, 0x61, 0x82>>
  assert alpacki.dynamic_max_size(table) == 128
}

// Down then up emits two size updates; the minimum, then the final
pub fn encode_pending_double_resize_test() {
  let table =
    alpacki.new_dynamic(4096)
    |> alpacki.resize_dynamic(0)
    |> alpacki.resize_dynamic(128)
  let #(encoded, table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":method":utf8>>,
          <<"GET":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x20, 0x3f, 0x61, 0x82>>
  assert alpacki.dynamic_max_size(table) == 128
}

pub fn encode_no_pending_resize_test() {
  let table = alpacki.new_dynamic(4096)
  let #(encoded, _table) =
    alpacki.encode_header_block(
      [
        alpacki.HeaderField(
          <<":method":utf8>>,
          <<"GET":utf8>>,
          alpacki.WithIndexing,
        ),
      ],
      table,
      False,
    )
  assert encoded == <<0x82>>
}
