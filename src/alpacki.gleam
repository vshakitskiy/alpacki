//// <script>
//// const docs = [
////   {
////     header: "Header Blocks",
////     functions: [
////       "decode_header_block",
////       "encode_header_block"
////     ]
////   },
////   {
////     header: "Index Address Space",
////     functions: [
////       "match",
////       "lookup"
////     ]
////   },
////   {
////     header: "Dynamic Table",
////     functions: [
////       "new_dynamic",
////       "dynamic_size",
////       "dynamic_max_size",
////       "dynamic_length",
////       "add_dynamic",
////       "lookup_dynamic",
////       "match_dynamic",
////       "resize_dynamic",
////       "clear_dynamic"
////     ]
////   },
////   {
////     header: "Static Table",
////     functions: [
////       "lookup_static",
////       "match_static"
////     ]
////   },
////   {
////     header: "Primitives",
////     functions: [
////      "decode_integer",
////      "encode_integer",
////      "decode_string_literal",
////      "encode_string_literal",
////      "encode_table_size_update"
////     ]
////   },
////   {
////     header: "Huffman",
////     functions: [
////       "decode_huffman",
////       "encode_huffman"
////     ]
////   },
//// ]
////
//// const callback = () => {
////   const list = document.querySelector(".sidebar > ul:last-of-type")
////   const sortedLists = document.createDocumentFragment()
////   const sortedMembers = document.createDocumentFragment()
////
////   for (const section of docs) {
////     sortedLists.append((() => {
////       const node = document.createElement("h3")
////       node.append(section.header)
////       return node
////     })())
////     sortedMembers.append((() => {
////       const node = document.createElement("h2")
////       node.append(section.header)
////       return node
////     })())
////
////     const sortedList = document.createElement("ul")
////     sortedLists.append(sortedList)
////
////     const sortedFunctions = [...section.functions].sort()
////
////     for (const funcName of sortedFunctions) {
////       const href = `#${funcName}`
////       const member = document.querySelector(
////         `.member:has(h2 > a[href="${href}"])`
////       )
////       const sidebar = list.querySelector(`li:has(a[href="${href}"])`)
////       sortedList.append(sidebar)
////       sortedMembers.append(member)
////     }
////   }
////
////   document.querySelector(".sidebar").insertBefore(sortedLists, list)
////   document
////     .querySelector(".module-members:has(#module-values)")
////     .insertBefore(
////       sortedMembers,
////       document.querySelector("#module-values").nextSibling
////     )
//// }
////
//// document.readyState !== "loading"
////   ? callback()
////   : document.addEventListener(
////     "DOMContentLoaded",
////     callback,
////     { once: true }
////   )
//// </script>

import alpacki/internal/huffman
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Errors that can occur when decoding a header block or its components.
pub type DecodeError {
  /// The input ended before a complete value could be decoded.
  Incomplete
  /// An encoded integer exceeded the maximum supported value.
  IntegerOverflow
  /// The data contained an unrecognizable bit pattern.
  InvalidEncoding
  /// A header field referenced a table index that does not exist.
  InvalidTableIndex
  /// Huffman-encoded data was malformed or had invalid padding.
  InvalidHuffmanEncoding
  /// A required Dynamic Table Size Update was not found at the start of the
  /// header block.
  MissingSizeUpdate
}

// Integer and String Representations (Section 5)
// -----------------------------------------------------------------------------

/// Decodes an integer used to represent name indices, string lengths, or
/// integer values. Accepts a BitArray starting at the byte containing the
/// prefix and the number of prefix bits. Returns the decoded integer with the
/// remaining BitArray, or a decode error.
///
/// The prefix size must be between 1 and 8 bits. Other values cause a panic.
///
/// See: [RFC 7541 Section 5.1](https://datatracker.ietf.org/doc/html/rfc7541#section-5.1)
///
/// ---
///
/// An integer is represented in two parts: a prefix that fills the current
/// octet and an optional list of octets that are used if the integer value
/// does not fit within the prefix.
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | ? | ? | ? |       Value       |  N = 5, value < 2^N-1
/// +---+---+---+-------------------+
/// ```
///
/// If the value is too large for the N-bit prefix, all prefix bits are set
/// to 1 and the remainder is encoded using continuation bytes in base-128.
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | ? | ? | ? | 1   1   1   1   1 |  N = 5, prefix exhausted
/// +---+---+---+-------------------+
/// | 1 |    Value-(2^N-1) LSB      |
/// +---+---------------------------+
///                ...
/// +---+---------------------------+
/// | 0 |    Value-(2^N-1) MSB      |
/// +---+---------------------------+
/// ```
pub fn decode_integer(
  data: BitArray,
  prefix prefix: Int,
) -> Result(#(Int, BitArray), DecodeError) {
  let maximum_prefix = maximum_value_for_bits(prefix)
  let ignored = 8 - prefix
  case data {
    <<_ignored:size(ignored), value:size(prefix), remaining:bits>> ->
      case value == maximum_prefix {
        // Integer value encoded after the prefix.
        True -> decode_integer_after_prefix(remaining, maximum_prefix, 1)
        // Integer value encoded within the prefix.
        False -> Ok(#(value, remaining))
      }
    _ -> Error(Incomplete)
  }
}

// Maximum allowed continuation multiplier (128^4)
// Allows 4 continuation bytes * 7 bits = 28 bits + 8-bit prefix = 36 bits
// total. This is plenty for HPACK.
const max_continuation_multiplier = 268_435_456

// Decodes an integer encoded after the prefix.
fn decode_integer_after_prefix(
  data: BitArray,
  acc: Int,
  multiplier: Int,
  // ^^^^^^^
  // Represents the place value weight of the current continuation byte in
  // base-128 arithmetic.
) {
  // First check: "Are we about to read a 5th continuation byte?"
  case multiplier > max_continuation_multiplier, data {
    // No more than 4 continuation bytes allowed!
    True, _ -> Error(IntegerOverflow)

    // If MSB is set to 0, this is the last byte.
    False, <<0:1, value:7, remaining:bits>> ->
      Ok(#(acc + value * multiplier, remaining))
    // If MSB is set to 1, the value continues.
    False, <<1:1, value:7, remaining:bits>> ->
      decode_integer_after_prefix(
        remaining,
        acc + value * multiplier,
        multiplier * 128,
      )

    False, _ -> Error(Incomplete)
  }
}

/// Encodes an integer used to represent name indices, string lengths, or
/// integer values. Accepts an integer and the number of prefix bits (N).
/// Returns the encoded BitArray.
///
/// The prefix size must be between 1 and 8 bits. Other values cause a panic.
///
/// See: [RFC 7541 Section 5.1](https://datatracker.ietf.org/doc/html/rfc7541#section-5.1)
///
/// ---
///
/// An integer is represented in two parts: a prefix that fills the current
/// octet and an optional list of octets that are used if the integer value
/// does not fit within the prefix.
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | ? | ? | ? |       Value       |  N = 5, value < 2^N-1
/// +---+---+---+-------------------+
/// ```
///
/// If the value is too large for the N-bit prefix, all prefix bits are set
/// to 1 and the remainder is encoded using continuation bytes in base-128.
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | ? | ? | ? | 1   1   1   1   1 |  N = 5, prefix exhausted
/// +---+---+---+-------------------+
/// | 1 |    Value-(2^N-1) LSB      |
/// +---+---------------------------+
///                ...
/// +---+---------------------------+
/// | 0 |    Value-(2^N-1) MSB      |
/// +---+---------------------------+
/// ```
pub fn encode_integer(integer: Int, prefix prefix: Int) -> BitArray {
  let maximum_prefix = maximum_value_for_bits(prefix)
  let ignored = 8 - prefix

  case integer < maximum_prefix {
    True -> <<0:size(ignored), integer:size(prefix)>>
    False ->
      encode_integer_after_prefix(integer - maximum_prefix, <<
        0:size(ignored),
        maximum_prefix:size(prefix),
      >>)
  }
}

// Encodes continuation bytes using base-128 variable-length encoding.
fn encode_integer_after_prefix(remaining: Int, acc: BitArray) -> BitArray {
  case remaining < 128 {
    True -> <<acc:bits, 0:1, remaining:7>>
    False ->
      encode_integer_after_prefix(remaining / 128, <<
        acc:bits,
        1:1,
        { remaining % 128 }:7,
      >>)
  }
}

// Maximum integer value for a particular prefix size (N for integer
// representation), calculated with: 2^N - 1. Integers outside [1, 8] will
// raise a panic!
fn maximum_value_for_bits(n: Int) -> Int {
  case n {
    8 -> 255
    7 -> 127
    6 -> 63
    5 -> 31
    4 -> 15
    3 -> 7
    2 -> 3
    1 -> 1
    _ -> panic as "Invalid HPACK prefix size!"
  }
}

/// Decodes a string literal representation used for header field names and
/// values. Returns the decoded octets and the remaining BitArray, or a
/// decode error.
///
/// See: [RFC 7541 Section 5.2](https://datatracker.ietf.org/doc/html/rfc7541#section-5.2)
///
/// ---
///
/// A string literal is an opaque sequence of octets, encoded either directly
/// or using Huffman coding. The representation starts with a one-bit flag (H)
/// indicating Huffman encoding, followed by the string length as a 7-bit
/// prefixed integer, then the encoded data.
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | H |    String Length (7+)     |
/// +---+---------------------------+
/// |  String Data (Length octets)  |
/// +-------------------------------+
/// ```
pub fn decode_string_literal(
  data: BitArray,
) -> Result(#(BitArray, BitArray), DecodeError) {
  case decode_integer(data, 7) {
    Error(error) -> Error(error)
    Ok(#(length, remaining)) ->
      case remaining, data {
        <<encoded:bytes-size(length), remaining:bits>>, <<1:1, _remaining:bits>>
        ->
          case decode_huffman(encoded) {
            Error(error) -> Error(error)
            Ok(string_literal) -> Ok(#(string_literal, remaining))
          }
        <<string_literal:bytes-size(length), remaining:bits>>,
          <<0:1, _remaining:bits>>
        -> Ok(#(string_literal, remaining))
        _, _ -> Error(Incomplete)
      }
  }
}

/// Encodes a string literal representation for header field names and values.
/// Accepts the raw octets and a flag indicating whether to use Huffman
/// coding. Returns the encoded BitArray.
///
/// See: [RFC 7541 Section 5.2](https://datatracker.ietf.org/doc/html/rfc7541#section-5.2)
///
/// ---
///
/// A string literal is an opaque sequence of octets, encoded either directly
/// or using Huffman coding. The representation starts with a one-bit flag (H)
/// indicating Huffman encoding, followed by the string length as a 7-bit
/// prefixed integer, then the encoded data.
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | H |    String Length (7+)     |
/// +---+---------------------------+
/// |  String Data (Length octets)  |
/// +-------------------------------+
/// ```
pub fn encode_string_literal(
  data: BitArray,
  huffman huffman: Bool,
) -> BitArray {
  let #(data, h) = case huffman {
    True -> #(encode_huffman(data), 0b10000000)
    False -> #(data, 0b00000000)
  }

  case bit_array.byte_size(data) |> encode_integer(prefix: 7) {
    <<byte:8, remaining:bits>> -> <<{ byte + h }:8, remaining:bits, data:bits>>
    _ -> panic as "Unreachable pattern for encoded integer!"
  }
}

/// Encodes a dynamic table size update instruction, signaling the decoder
/// about a change in the maximum dynamic table size.
///
/// See: [RFC 7541 Section 6.3](https://datatracker.ietf.org/doc/html/rfc7541#section-6.3)
///
/// ---
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | 0 | 0 | 1 |   Max size (5+)   |
/// +---+---+---+-------------------+
/// ```
pub fn encode_table_size_update(new_size: Int) -> BitArray {
  encode_prefixed_integer(new_size, 5, 0x20)
}

// Huffman Coding (Appendix B)
// -----------------------------------------------------------------------------

/// Decodes Huffman-coded data. Accepts Huffman-encoded bits and returns the
/// decoded byte sequence. The input must be padded to an octet boundary with
/// the most significant bits of the EOS symbol.
///
/// See: [RFC 7541 Appendix B](https://datatracker.ietf.org/doc/html/rfc7541#appendix-B)
pub fn decode_huffman(data: BitArray) -> Result(BitArray, DecodeError) {
  huffman.decode(data, <<>>)
  |> result.replace_error(InvalidHuffmanEncoding)
}

/// Encodes data using Huffman coding. Accepts raw bytes and returns
/// Huffman-encoded bits padded to an octet boundary with the most significant
/// bits of the EOS symbol.
///
/// See: [RFC 7541 Appendix B](https://datatracker.ietf.org/doc/html/rfc7541#appendix-B)
pub fn encode_huffman(data: BitArray) -> BitArray {
  huffman.encode(data, <<>>)
}

// Static Table (Appendix A)
// -----------------------------------------------------------------------------

/// Looks up a header field by index 1 to 61 in the static table. Returns
/// the name-value pair or an error if the index is out of range.
///
/// See: [RFC 7541 Appendix A](https://datatracker.ietf.org/doc/html/rfc7541#appendix-A)
pub fn lookup_static(index: Int) -> Result(#(BitArray, BitArray), Nil) {
  case index {
    1 -> Ok(#(<<":authority":utf8>>, <<>>))
    2 -> Ok(#(<<":method":utf8>>, <<"GET":utf8>>))
    3 -> Ok(#(<<":method":utf8>>, <<"POST":utf8>>))
    4 -> Ok(#(<<":path":utf8>>, <<"/":utf8>>))
    5 -> Ok(#(<<":path":utf8>>, <<"/index.html":utf8>>))
    6 -> Ok(#(<<":scheme":utf8>>, <<"http":utf8>>))
    7 -> Ok(#(<<":scheme":utf8>>, <<"https":utf8>>))
    8 -> Ok(#(<<":status":utf8>>, <<"200":utf8>>))
    9 -> Ok(#(<<":status":utf8>>, <<"204":utf8>>))
    10 -> Ok(#(<<":status":utf8>>, <<"206":utf8>>))
    11 -> Ok(#(<<":status":utf8>>, <<"304":utf8>>))
    12 -> Ok(#(<<":status":utf8>>, <<"400":utf8>>))
    13 -> Ok(#(<<":status":utf8>>, <<"404":utf8>>))
    14 -> Ok(#(<<":status":utf8>>, <<"500":utf8>>))
    15 -> Ok(#(<<"accept-charset":utf8>>, <<>>))
    16 -> Ok(#(<<"accept-encoding":utf8>>, <<"gzip, deflate":utf8>>))
    17 -> Ok(#(<<"accept-language":utf8>>, <<>>))
    18 -> Ok(#(<<"accept-ranges":utf8>>, <<>>))
    19 -> Ok(#(<<"accept":utf8>>, <<>>))
    20 -> Ok(#(<<"access-control-allow-origin":utf8>>, <<>>))
    21 -> Ok(#(<<"age":utf8>>, <<>>))
    22 -> Ok(#(<<"allow":utf8>>, <<>>))
    23 -> Ok(#(<<"authorization":utf8>>, <<>>))
    24 -> Ok(#(<<"cache-control":utf8>>, <<>>))
    25 -> Ok(#(<<"content-disposition":utf8>>, <<>>))
    26 -> Ok(#(<<"content-encoding":utf8>>, <<>>))
    27 -> Ok(#(<<"content-language":utf8>>, <<>>))
    28 -> Ok(#(<<"content-length":utf8>>, <<>>))
    29 -> Ok(#(<<"content-location":utf8>>, <<>>))
    30 -> Ok(#(<<"content-range":utf8>>, <<>>))
    31 -> Ok(#(<<"content-type":utf8>>, <<>>))
    32 -> Ok(#(<<"cookie":utf8>>, <<>>))
    33 -> Ok(#(<<"date":utf8>>, <<>>))
    34 -> Ok(#(<<"etag":utf8>>, <<>>))
    35 -> Ok(#(<<"expect":utf8>>, <<>>))
    36 -> Ok(#(<<"expires":utf8>>, <<>>))
    37 -> Ok(#(<<"from":utf8>>, <<>>))
    38 -> Ok(#(<<"host":utf8>>, <<>>))
    39 -> Ok(#(<<"if-match":utf8>>, <<>>))
    40 -> Ok(#(<<"if-modified-since":utf8>>, <<>>))
    41 -> Ok(#(<<"if-none-match":utf8>>, <<>>))
    42 -> Ok(#(<<"if-range":utf8>>, <<>>))
    43 -> Ok(#(<<"if-unmodified-since":utf8>>, <<>>))
    44 -> Ok(#(<<"last-modified":utf8>>, <<>>))
    45 -> Ok(#(<<"link":utf8>>, <<>>))
    46 -> Ok(#(<<"location":utf8>>, <<>>))
    47 -> Ok(#(<<"max-forwards":utf8>>, <<>>))
    48 -> Ok(#(<<"proxy-authenticate":utf8>>, <<>>))
    49 -> Ok(#(<<"proxy-authorization":utf8>>, <<>>))
    50 -> Ok(#(<<"range":utf8>>, <<>>))
    51 -> Ok(#(<<"referer":utf8>>, <<>>))
    52 -> Ok(#(<<"refresh":utf8>>, <<>>))
    53 -> Ok(#(<<"retry-after":utf8>>, <<>>))
    54 -> Ok(#(<<"server":utf8>>, <<>>))
    55 -> Ok(#(<<"set-cookie":utf8>>, <<>>))
    56 -> Ok(#(<<"strict-transport-security":utf8>>, <<>>))
    57 -> Ok(#(<<"transfer-encoding":utf8>>, <<>>))
    58 -> Ok(#(<<"user-agent":utf8>>, <<>>))
    59 -> Ok(#(<<"vary":utf8>>, <<>>))
    60 -> Ok(#(<<"via":utf8>>, <<>>))
    61 -> Ok(#(<<"www-authenticate":utf8>>, <<>>))
    _ -> Error(Nil)
  }
}

/// Searches the static table for an entry matching the given name and value.
/// Returns `FullMatch` with index if both match, `NameMatch` with index if
/// only the name matches, or `NoMatch`.
///
/// See: [RFC 7541 Appendix A](https://datatracker.ietf.org/doc/html/rfc7541#appendix-A)
pub fn match_static(name: BitArray, value: BitArray) -> TableMatch {
  case name, value {
    <<":authority":utf8>>, <<>> -> FullMatch(1)
    <<":method":utf8>>, <<"GET":utf8>> -> FullMatch(2)
    <<":method":utf8>>, <<"POST":utf8>> -> FullMatch(3)
    <<":path":utf8>>, <<"/":utf8>> -> FullMatch(4)
    <<":path":utf8>>, <<"/index.html":utf8>> -> FullMatch(5)
    <<":scheme":utf8>>, <<"http":utf8>> -> FullMatch(6)
    <<":scheme":utf8>>, <<"https":utf8>> -> FullMatch(7)
    <<":status":utf8>>, <<"200":utf8>> -> FullMatch(8)
    <<":status":utf8>>, <<"204":utf8>> -> FullMatch(9)
    <<":status":utf8>>, <<"206":utf8>> -> FullMatch(10)
    <<":status":utf8>>, <<"304":utf8>> -> FullMatch(11)
    <<":status":utf8>>, <<"400":utf8>> -> FullMatch(12)
    <<":status":utf8>>, <<"404":utf8>> -> FullMatch(13)
    <<":status":utf8>>, <<"500":utf8>> -> FullMatch(14)
    <<"accept-charset":utf8>>, <<>> -> FullMatch(15)
    <<"accept-encoding":utf8>>, <<"gzip, deflate":utf8>> -> FullMatch(16)
    <<"accept-language":utf8>>, <<>> -> FullMatch(17)
    <<"accept-ranges":utf8>>, <<>> -> FullMatch(18)
    <<"accept":utf8>>, <<>> -> FullMatch(19)
    <<"access-control-allow-origin":utf8>>, <<>> -> FullMatch(20)
    <<"age":utf8>>, <<>> -> FullMatch(21)
    <<"allow":utf8>>, <<>> -> FullMatch(22)
    <<"authorization":utf8>>, <<>> -> FullMatch(23)
    <<"cache-control":utf8>>, <<>> -> FullMatch(24)
    <<"content-disposition":utf8>>, <<>> -> FullMatch(25)
    <<"content-encoding":utf8>>, <<>> -> FullMatch(26)
    <<"content-language":utf8>>, <<>> -> FullMatch(27)
    <<"content-length":utf8>>, <<>> -> FullMatch(28)
    <<"content-location":utf8>>, <<>> -> FullMatch(29)
    <<"content-range":utf8>>, <<>> -> FullMatch(30)
    <<"content-type":utf8>>, <<>> -> FullMatch(31)
    <<"cookie":utf8>>, <<>> -> FullMatch(32)
    <<"date":utf8>>, <<>> -> FullMatch(33)
    <<"etag":utf8>>, <<>> -> FullMatch(34)
    <<"expect":utf8>>, <<>> -> FullMatch(35)
    <<"expires":utf8>>, <<>> -> FullMatch(36)
    <<"from":utf8>>, <<>> -> FullMatch(37)
    <<"host":utf8>>, <<>> -> FullMatch(38)
    <<"if-match":utf8>>, <<>> -> FullMatch(39)
    <<"if-modified-since":utf8>>, <<>> -> FullMatch(40)
    <<"if-none-match":utf8>>, <<>> -> FullMatch(41)
    <<"if-range":utf8>>, <<>> -> FullMatch(42)
    <<"if-unmodified-since":utf8>>, <<>> -> FullMatch(43)
    <<"last-modified":utf8>>, <<>> -> FullMatch(44)
    <<"link":utf8>>, <<>> -> FullMatch(45)
    <<"location":utf8>>, <<>> -> FullMatch(46)
    <<"max-forwards":utf8>>, <<>> -> FullMatch(47)
    <<"proxy-authenticate":utf8>>, <<>> -> FullMatch(48)
    <<"proxy-authorization":utf8>>, <<>> -> FullMatch(49)
    <<"range":utf8>>, <<>> -> FullMatch(50)
    <<"referer":utf8>>, <<>> -> FullMatch(51)
    <<"refresh":utf8>>, <<>> -> FullMatch(52)
    <<"retry-after":utf8>>, <<>> -> FullMatch(53)
    <<"server":utf8>>, <<>> -> FullMatch(54)
    <<"set-cookie":utf8>>, <<>> -> FullMatch(55)
    <<"strict-transport-security":utf8>>, <<>> -> FullMatch(56)
    <<"transfer-encoding":utf8>>, <<>> -> FullMatch(57)
    <<"user-agent":utf8>>, <<>> -> FullMatch(58)
    <<"vary":utf8>>, <<>> -> FullMatch(59)
    <<"via":utf8>>, <<>> -> FullMatch(60)
    <<"www-authenticate":utf8>>, <<>> -> FullMatch(61)
    <<":authority":utf8>>, _ -> NameMatch(1)
    <<":method":utf8>>, _ -> NameMatch(2)
    <<":path":utf8>>, _ -> NameMatch(4)
    <<":scheme":utf8>>, _ -> NameMatch(6)
    <<":status":utf8>>, _ -> NameMatch(8)
    <<"accept-charset":utf8>>, _ -> NameMatch(15)
    <<"accept-encoding":utf8>>, _ -> NameMatch(16)
    <<"accept-language":utf8>>, _ -> NameMatch(17)
    <<"accept-ranges":utf8>>, _ -> NameMatch(18)
    <<"accept":utf8>>, _ -> NameMatch(19)
    <<"access-control-allow-origin":utf8>>, _ -> NameMatch(20)
    <<"age":utf8>>, _ -> NameMatch(21)
    <<"allow":utf8>>, _ -> NameMatch(22)
    <<"authorization":utf8>>, _ -> NameMatch(23)
    <<"cache-control":utf8>>, _ -> NameMatch(24)
    <<"content-disposition":utf8>>, _ -> NameMatch(25)
    <<"content-encoding":utf8>>, _ -> NameMatch(26)
    <<"content-language":utf8>>, _ -> NameMatch(27)
    <<"content-length":utf8>>, _ -> NameMatch(28)
    <<"content-location":utf8>>, _ -> NameMatch(29)
    <<"content-range":utf8>>, _ -> NameMatch(30)
    <<"content-type":utf8>>, _ -> NameMatch(31)
    <<"cookie":utf8>>, _ -> NameMatch(32)
    <<"date":utf8>>, _ -> NameMatch(33)
    <<"etag":utf8>>, _ -> NameMatch(34)
    <<"expect":utf8>>, _ -> NameMatch(35)
    <<"expires":utf8>>, _ -> NameMatch(36)
    <<"from":utf8>>, _ -> NameMatch(37)
    <<"host":utf8>>, _ -> NameMatch(38)
    <<"if-match":utf8>>, _ -> NameMatch(39)
    <<"if-modified-since":utf8>>, _ -> NameMatch(40)
    <<"if-none-match":utf8>>, _ -> NameMatch(41)
    <<"if-range":utf8>>, _ -> NameMatch(42)
    <<"if-unmodified-since":utf8>>, _ -> NameMatch(43)
    <<"last-modified":utf8>>, _ -> NameMatch(44)
    <<"link":utf8>>, _ -> NameMatch(45)
    <<"location":utf8>>, _ -> NameMatch(46)
    <<"max-forwards":utf8>>, _ -> NameMatch(47)
    <<"proxy-authenticate":utf8>>, _ -> NameMatch(48)
    <<"proxy-authorization":utf8>>, _ -> NameMatch(49)
    <<"range":utf8>>, _ -> NameMatch(50)
    <<"referer":utf8>>, _ -> NameMatch(51)
    <<"refresh":utf8>>, _ -> NameMatch(52)
    <<"retry-after":utf8>>, _ -> NameMatch(53)
    <<"server":utf8>>, _ -> NameMatch(54)
    <<"set-cookie":utf8>>, _ -> NameMatch(55)
    <<"strict-transport-security":utf8>>, _ -> NameMatch(56)
    <<"transfer-encoding":utf8>>, _ -> NameMatch(57)
    <<"user-agent":utf8>>, _ -> NameMatch(58)
    <<"vary":utf8>>, _ -> NameMatch(59)
    <<"via":utf8>>, _ -> NameMatch(60)
    <<"www-authenticate":utf8>>, _ -> NameMatch(61)
    _, _ -> NoMatch
  }
}

// Dynamic Table (Section 4)
// -----------------------------------------------------------------------------

/// Dynamic table for HPACK compression. Stores recently used header fields
/// with indices starting at 62. The encoder and decoder each maintain their
/// own table.
/// 
/// See: [RFC 7541 Section 2.3.2](https://datatracker.ietf.org/doc/html/rfc7541#section-2.3.2)
pub opaque type DynamicTable {
  DynamicTable(
    entries: List(#(BitArray, BitArray)),
    size: Int,
    max_size: Int,
    length: Int,
    pending_resize: Option(Int),
    pending_size_update: Bool,
  )
}

// Dynamic table starts at index 62.
const dynamic_table_start = 62

// Entry overhead as defined in RFC 7541 Section 4.1.
const entry_overhead = 32

/// Returns the current size of the dynamic table in bytes, calculated as
/// the sum of each entry's name length, value length, and 32-byte overhead.
/// ([RFC 7541 Section 4.1](https://datatracker.ietf.org/doc/html/rfc7541#section-4.1))
pub fn dynamic_size(table: DynamicTable) -> Int {
  table.size
}

/// Returns the maximum size of the dynamic table in bytes.
/// ([RFC 7541 Section 4.2](https://datatracker.ietf.org/doc/html/rfc7541#section-4.2))
pub fn dynamic_max_size(table: DynamicTable) -> Int {
  table.max_size
}

/// Returns the number of entries in the dynamic table.
/// ([RFC 7541 Section 2.3.2](https://datatracker.ietf.org/doc/html/rfc7541#section-2.3.2))
pub fn dynamic_length(table: DynamicTable) -> Int {
  table.length
}

/// Creates an empty dynamic table with the specified maximum size in bytes.
/// The protocol determines the initial maximum size; HTTP/2 defaults to
/// 4096 bytes via `SETTINGS_HEADER_TABLE_SIZE`.
///
/// See: [RFC 7541 Section 4.2](https://datatracker.ietf.org/doc/html/rfc7541#section-4.2)
pub fn new_dynamic(max_size: Int) -> DynamicTable {
  DynamicTable(
    entries: [],
    size: 0,
    max_size:,
    length: 0,
    pending_resize: None,
    pending_size_update: False,
  )
}

/// Adds an entry to the dynamic table at index 62. Evicts oldest entries if
/// the new entry would exceed maximum size. Clears the table without adding
/// if the entry alone exceeds maximum size.
///
/// See: [RFC 7541 Section 4.4](https://datatracker.ietf.org/doc/html/rfc7541#section-4.4)
pub fn add_dynamic(
  table: DynamicTable,
  name: BitArray,
  value: BitArray,
) -> DynamicTable {
  let entry_size = calculate_entry_size(name, value)

  case entry_size > table.max_size {
    True -> DynamicTable(..table, entries: [], size: 0, length: 0)
    False -> {
      let table = evict_until_fits(table, entry_size)
      DynamicTable(
        ..table,
        entries: [#(name, value), ..table.entries],
        size: table.size + entry_size,
        length: table.length + 1,
      )
    }
  }
}

/// Looks up a header field by index in the dynamic table. Indices start at
/// 62 for the most recently added entry. Returns the name-value pair or an
/// error if the index is out of range.
///
/// See: [RFC 7541 Section 2.3.3](https://datatracker.ietf.org/doc/html/rfc7541#section-2.3.3)
pub fn lookup_dynamic(
  table: DynamicTable,
  index: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  case index < dynamic_table_start {
    True -> Error(Nil)
    False -> {
      let position = index - dynamic_table_start
      case position < table.length {
        True -> list.drop(table.entries, position) |> list.first
        False -> Error(Nil)
      }
    }
  }
}

/// Searches the dynamic table for an entry matching the given name and value.
/// Returns `FullMatch` with index if both match, `NameMatch` with index if
/// only the name matches, or `NoMatch`.
///
/// See: [RFC 7541 Section 2.3.2](https://datatracker.ietf.org/doc/html/rfc7541#section-2.3.2)
pub fn match_dynamic(
  table: DynamicTable,
  name: BitArray,
  value: BitArray,
) -> TableMatch {
  case table.length {
    0 -> NoMatch
    _ -> do_match_dynamic(table.entries, name, value, 0, NoMatch)
  }
}

fn do_match_dynamic(
  entries: List(#(BitArray, BitArray)),
  name: BitArray,
  value: BitArray,
  position: Int,
  match_accumulator: TableMatch,
) -> TableMatch {
  case entries {
    // Found exact match
    [#(n, v), ..] if n == name && v == value ->
      FullMatch(dynamic_table_start + position)

    // Name matches but value doesn't
    [#(n, _), ..remaining] if n == name -> {
      let match_accumulator = case match_accumulator {
        NoMatch -> NameMatch(dynamic_table_start + position)
        match_accumulator -> match_accumulator
      }
      do_match_dynamic(remaining, name, value, position + 1, match_accumulator)
    }

    // No match
    [_, ..remaining] ->
      do_match_dynamic(remaining, name, value, position + 1, match_accumulator)

    // Return what we found
    [] -> match_accumulator
  }
}

/// Resizes the dynamic table, typically in response to a SETTINGS frame.
/// Evicts oldest entries if the current size exceeds the new maximum. Records
/// the pending resize so that `encode_header_block` automatically emits the
/// required size update instructions at the start of the next header block.
///
/// See: [RFC 7541 Section 4.2](https://datatracker.ietf.org/doc/html/rfc7541#section-4.2)
pub fn resize_dynamic(table: DynamicTable, new_max_size: Int) -> DynamicTable {
  let pending = case table.pending_resize {
    None -> new_max_size
    Some(current_min) -> int.min(current_min, new_max_size)
  }
  DynamicTable(
    ..evict_to_size(table, new_max_size),
    max_size: new_max_size,
    pending_resize: Some(pending),
  )
}

/// Marks the decoder table as expecting a Dynamic Table Size Update
/// instruction at the start of the next header block.
///
/// See: [RFC 7541 Section 4.2](https://datatracker.ietf.org/doc/html/rfc7541#section-4.2)
pub fn expect_table_size_update(table: DynamicTable) -> DynamicTable {
  DynamicTable(..table, pending_size_update: True)
}

/// Removes all entries from the dynamic table while preserving the maximum
/// size setting.
pub fn clear_dynamic(table: DynamicTable) -> DynamicTable {
  DynamicTable(..table, entries: [], size: 0, length: 0)
}

// Evicts oldest entries until there is space for the new entry.
fn evict_until_fits(table: DynamicTable, needed_space: Int) -> DynamicTable {
  case table.size + needed_space <= table.max_size {
    True -> table
    False -> rebuild_within(table, table.max_size - needed_space)
  }
}

// Evicts oldest entries until table size is within the target size.
fn evict_to_size(table: DynamicTable, target_size: Int) -> DynamicTable {
  case table.size <= target_size {
    True -> table
    False -> rebuild_within(table, target_size)
  }
}

// `entries` is newest first, so lets keep the newest first prefix that fits 
// the `budget` and drop the remaining.
fn rebuild_within(table: DynamicTable, budget: Int) -> DynamicTable {
  let #(kept, new_size, new_length) =
    keep_within(table.entries, budget, [], 0, 0)

  DynamicTable(
    ..table,
    entries: list.reverse(kept),
    size: new_size,
    length: new_length,
  )
}

fn keep_within(
  entries: List(#(BitArray, BitArray)),
  budget: Int,
  kept: List(#(BitArray, BitArray)),
  kept_size: Int,
  kept_length: Int,
) -> #(List(#(BitArray, BitArray)), Int, Int) {
  case entries {
    [] -> #(kept, kept_size, kept_length)
    [#(name, value) as entry, ..remaining] -> {
      let entry_size = calculate_entry_size(name, value)
      case kept_size + entry_size <= budget {
        True ->
          keep_within(
            remaining,
            budget,
            [entry, ..kept],
            kept_size + entry_size,
            kept_length + 1,
          )
        False -> #(kept, kept_size, kept_length)
      }
    }
  }
}

// Calculates entry size per RFC 7541 Section 4.1: name + value + 32 bytes.
fn calculate_entry_size(name: BitArray, value: BitArray) -> Int {
  bit_array.byte_size(name) + bit_array.byte_size(value) + entry_overhead
}

// Index Address Space (Section 2.3.3)
// -----------------------------------------------------------------------------

/// Result of searching a table for a header field. The index refers to the
/// combined address space: 1–61 for static entries, 62 and above for dynamic
/// entries.
///
/// See: [RFC 7541 Section 2.3.3](https://datatracker.ietf.org/doc/html/rfc7541#section-2.3.3)
pub type TableMatch {
  /// Both name and value matched an entry at the given index.
  FullMatch(index: Int)
  /// Only the name matched; the value at this index differs.
  NameMatch(index: Int)
  /// Neither name nor value matched any entry.
  NoMatch
}

/// Searches the static and dynamic tables for the best match for a header
/// field. Checks the static table first, then the dynamic table, and returns
/// the most useful match found.
///
/// A full match in the static table wins immediately. When the static table
/// has only a name match, the dynamic table is still checked for a full
/// match. A static name match is preferred over a dynamic name match. When
/// the static table has no match, the dynamic table result is returned.
///
/// See: [RFC 7541 Section 2.3.3](https://datatracker.ietf.org/doc/html/rfc7541#section-2.3.3)
pub fn match(
  dynamic_table: DynamicTable,
  name: BitArray,
  value: BitArray,
) -> TableMatch {
  case match_static(name, value) {
    NameMatch(static_index) -> {
      case match_dynamic(dynamic_table, name, value) {
        NoMatch | NameMatch(_) -> NameMatch(static_index)
        matched -> matched
      }
    }
    NoMatch -> match_dynamic(dynamic_table, name, value)
    full_match -> full_match
  }
}

/// Looks up a header field by index across the static and dynamic tables.
/// Indices 1 to 61 address the static table; 62 and above address the
/// dynamic table starting from the most recently added entry. Returns the
/// name-value pair or an error if the index is out of range.
///
/// See: [RFC 7541 Section 2.3.3](https://datatracker.ietf.org/doc/html/rfc7541#section-2.3.3)
pub fn lookup(
  dynamic_table: DynamicTable,
  index: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  case index < dynamic_table_start {
    True -> lookup_static(index)
    False -> lookup_dynamic(dynamic_table, index)
  }
}

// Binary Format (Section 6)
// -----------------------------------------------------------------------------

/// Indexing mode for a header field, controlling how the encoder represents it
/// on the wire and how the decoder preserves the original signal.
///
/// See: [RFC 7541 Section 6.2](https://datatracker.ietf.org/doc/html/rfc7541#section-6.2)
pub type Indexing {
  /// Literal with incremental indexing (Section 6.2.1). Store in the dynamic
  /// table for future reference.
  WithIndexing
  /// Literal without indexing (Section 6.2.2). Do not store. Useful for
  /// header fields that change every request.
  WithoutIndexing
  /// Literal never indexed (Section 6.2.3). Do not store, and signal to
  /// intermediaries that this value is sensitive and must never be compressed.
  NeverIndexed
}

/// A header field as it flows through the encoder and decoder. When encoding,
/// the `indexing` mode controls the wire representation. When decoding, it
/// preserves the representation chosen by the sender.
pub type HeaderField {
  HeaderField(name: BitArray, value: BitArray, indexing: Indexing)
}

/// Result of decoding a header block fragment.
///
/// `remaining` holds any unconsumed trailing bytes. It is non-empty when the
/// fragment ends mid-field: the header fields decoded so far are returned
/// along with the updated table, and the caller is expected to prepend more
/// data to `remaining` and decode again. `remaining` is empty when the whole
/// fragment was consumed.
///
/// `decoded_size` is the sum of RFC 7541 Section 4.1 entry sizes (name +
/// value + 32) for the headers decoded in this call, useful for enforcing a
/// maximum header list size across calls.
pub type DecodedHeaderBlock {
  DecodedHeaderBlock(
    headers: List(#(BitArray, BitArray)),
    decoded_size: Int,
    dynamic_table: DynamicTable,
    remaining: BitArray,
  )
}

/// Decodes a header block fragment into header fields, updating the dynamic
/// table as specified by the encoded instructions.
///
/// Any dynamic table size update instructions at the start of the block are
/// processed automatically before header fields are decoded.
///
/// Unlike a single header field or integer, a header block fragment does not
/// need to be complete. If it ends mid field, decoding stops there and the
/// unconsumed bytes are returned in `remaining` rather than raising
/// `Incomplete`.
///
/// See: [RFC 7541 Section 6](https://datatracker.ietf.org/doc/html/rfc7541#section-6)
///
/// ---
///
/// A header block is a sequence of header field representations, each
/// identified by its first-byte bit pattern:
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | 1 |        Index (7+)         | 6.1 Indexed
/// +---+---------------------------+
/// | 0 | 1 |      Index (6+)       | 6.2.1 With Indexing
/// +---+---+-----------------------+
/// | 0 | 0 | 0 | 0 |  Index (4+)   | 6.2.2 Without Indexing
/// +---+---+---+---+---------------+
/// | 0 | 0 | 0 | 1 |  Index (4+)   | 6.2.3 Never Indexed
/// +---+---+---+---+---------------+
/// | 0 | 0 | 1 |   Max size (5+)   | 6.3 Size Update
/// +---+---+---+-------------------+
/// ```
///
/// Indexed representations reference an existing table entry. Literal
/// representations carry the value on the wire, optionally referencing a
/// table entry for the name. Header names and values are returned as opaque.
pub fn decode_header_block(
  data: BitArray,
  dynamic_table: DynamicTable,
) -> Result(DecodedHeaderBlock, DecodeError) {
  case decode_size_updates(data, dynamic_table) {
    Error(error) -> Error(error)
    Ok(#(data, table, True)) ->
      Ok(DecodedHeaderBlock(
        headers: [],
        decoded_size: 0,
        dynamic_table: table,
        remaining: data,
      ))
    Ok(#(data, table, False)) -> decode_header_fields(data, table, [], 0)
  }
}

fn decode_size_updates(
  data: BitArray,
  table: DynamicTable,
) -> Result(#(BitArray, DynamicTable, Bool), DecodeError) {
  case data {
    // 6.3 Dynamic Table Size Update
    //   0   1   2   3   4   5   6   7
    // +---+---+---+---+---+---+---+---+
    // | 0 | 0 | 1 |   Max size (5+)   |
    // +---+---+---+-------------------+
    <<0:2, 1:1, _:5, _:bits>> ->
      case decode_integer(data, 5) {
        Error(Incomplete) -> Ok(#(data, table, True))
        Error(error) -> Error(error)
        Ok(#(new_size, remaining)) -> {
          let table =
            DynamicTable(
              ..evict_to_size(table, new_size),
              max_size: new_size,
              pending_size_update: False,
            )
          decode_size_updates(remaining, table)
        }
      }
    _ ->
      case table.pending_size_update {
        True -> Error(MissingSizeUpdate)
        False -> Ok(#(data, table, False))
      }
  }
}

fn decode_header_fields(
  data: BitArray,
  table: DynamicTable,
  acc: List(#(BitArray, BitArray)),
  decoded_size: Int,
) -> Result(DecodedHeaderBlock, DecodeError) {
  case data {
    <<>> ->
      Ok(DecodedHeaderBlock(
        headers: list.reverse(acc),
        decoded_size:,
        dynamic_table: table,
        remaining: data,
      ))

    // 6.1 Indexed Header Field Representation
    //   0   1   2   3   4   5   6   7
    // +---+---+---+---+---+---+---+---+
    // | 1 |        Index (7+)         |
    // +---+---------------------------+
    <<1:1, _:7, _:bits>> ->
      case decode_integer(data, 7) {
        Error(Incomplete) -> Ok(stop(acc, decoded_size, table, data))
        Error(error) -> Error(error)
        Ok(#(index, remaining)) ->
          case lookup(table, index) {
            Error(Nil) -> Error(InvalidTableIndex)
            Ok(#(name, value)) -> {
              let entry_size = calculate_entry_size(name, value)
              decode_header_fields(
                remaining,
                table,
                [#(name, value), ..acc],
                decoded_size + entry_size,
              )
            }
          }
      }

    // 6.2.1 Literal Header Field with Incremental Indexing
    //   0   1   2   3   4   5   6   7
    // +---+---+---+---+---+---+---+---+
    // | 0 | 1 |      Index (6+)       |
    // +---+---+-----------------------+
    <<0:1, 1:1, _:6, _:bits>> ->
      case decode_literal(data, table, 6) {
        Error(Incomplete) -> Ok(stop(acc, decoded_size, table, data))
        Error(error) -> Error(error)
        Ok(#(name, value, remaining)) -> {
          let table = add_dynamic(table, name, value)
          let entry_size = calculate_entry_size(name, value)
          decode_header_fields(
            remaining,
            table,
            [#(name, value), ..acc],
            decoded_size + entry_size,
          )
        }
      }

    // 6.2.3 Literal Header Field Never Indexed
    //   0   1   2   3   4   5   6   7
    // +---+---+---+---+---+---+---+---+
    // | 0 | 0 | 0 | 1 |  Index (4+)   |
    // +---+---+---+---+---------------+
    <<0:3, 1:1, _:4, _:bits>> ->
      case decode_literal(data, table, 4) {
        Error(Incomplete) -> Ok(stop(acc, decoded_size, table, data))
        Error(error) -> Error(error)
        Ok(#(name, value, remaining)) -> {
          let entry_size = calculate_entry_size(name, value)
          decode_header_fields(
            remaining,
            table,
            [#(name, value), ..acc],
            decoded_size + entry_size,
          )
        }
      }

    // 6.2.2 Literal Header Field without Indexing
    //   0   1   2   3   4   5   6   7
    // +---+---+---+---+---+---+---+---+
    // | 0 | 0 | 0 | 0 |  Index (4+)   |
    // +---+---+---+---+---------------+
    <<0:4, _:4, _:bits>> ->
      case decode_literal(data, table, 4) {
        Error(Incomplete) -> Ok(stop(acc, decoded_size, table, data))
        Error(error) -> Error(error)
        Ok(#(name, value, remaining)) -> {
          let entry_size = calculate_entry_size(name, value)
          decode_header_fields(
            remaining,
            table,
            [#(name, value), ..acc],
            decoded_size + entry_size,
          )
        }
      }

    _ -> Error(InvalidEncoding)
  }
}

// Builds the result when decoding stops early because the header block
// fragment ended mid-field. `data` is the untouched start of that field.
fn stop(
  acc: List(#(BitArray, BitArray)),
  decoded_size: Int,
  table: DynamicTable,
  data: BitArray,
) -> DecodedHeaderBlock {
  DecodedHeaderBlock(
    headers: list.reverse(acc),
    decoded_size:,
    dynamic_table: table,
    remaining: data,
  )
}

fn decode_literal(
  data: BitArray,
  table: DynamicTable,
  prefix: Int,
) -> Result(#(BitArray, BitArray, BitArray), DecodeError) {
  case decode_integer(data, prefix) {
    Error(error) -> Error(error)
    Ok(#(index, remaining)) -> {
      let name_result = case index {
        // That is a new string literal.
        0 -> decode_string_literal(remaining)
        // That is a name from the table.
        _ ->
          case lookup(table, index) {
            Error(Nil) -> Error(InvalidTableIndex)
            Ok(#(name, _value)) -> Ok(#(name, remaining))
          }
      }
      case name_result {
        Error(error) -> Error(error)
        Ok(#(name, remaining)) ->
          case decode_string_literal(remaining) {
            Error(error) -> Error(error)
            Ok(#(value, remaining)) -> Ok(#(name, value, remaining))
          }
      }
    }
  }
}

/// Encodes a list of header fields into a header block fragment, updating the
/// dynamic table as entries are added. Returns the encoded block as a
/// `BitArray` and the updated dynamic table. When `huffman` is `True`, all
/// name and value strings use Huffman coding.
///
/// If `resize_dynamic` was called since the last encoding, the required
/// dynamic table size update instructions are prepended automatically.
///
/// See: [RFC 7541 Section 6](https://datatracker.ietf.org/doc/html/rfc7541#section-6)
///
/// ---
///
/// The encoder looks up each header field in the static and dynamic tables
/// and selects the most compact representation. A full match always uses the
/// indexed representation regardless of the indexing mode, as the entry is
/// already visible to the decoder as referencing it leaks no new information.
///
/// When only the name matches or nothing matches, the indexing mode selects
/// the literal representation: `WithIndexing` uses incremental indexing and
/// adds the entry to the dynamic table, `WithoutIndexing` sends the value
/// without storing it, and `NeverIndexed` signals that intermediaries must
/// never compress this value.
pub fn encode_header_block(
  headers: List(HeaderField),
  dynamic_table: DynamicTable,
  huffman huffman: Bool,
) -> #(BitArray, DynamicTable) {
  let #(table, resize_pieces) = emit_pending_resizes(dynamic_table)
  let #(pieces, table) =
    encode_header_fields(headers, table, huffman, list.reverse(resize_pieces))
  #(bit_array.concat(list.reverse(pieces)), table)
}

// The private helpers below build a flat `List(BitArray)` by consing
// instead of concatenating each piece with `<<a:bits, b:bits>>`.
// `encode_header_block` is the only place that flattens, via
// `bit_array.concat`, once, for the whole block.
fn emit_pending_resizes(
  table: DynamicTable,
) -> #(DynamicTable, List(BitArray)) {
  case table.pending_resize {
    None -> #(table, [])
    Some(min_size) -> {
      let table = DynamicTable(..table, pending_resize: None)
      case min_size < table.max_size {
        // Size went down then back up; emit minimum then final.
        True -> #(table, [
          encode_table_size_update(min_size),
          encode_table_size_update(table.max_size),
        ])
        // Size only went down or stayed unchanged; emit final.
        False -> #(table, [encode_table_size_update(min_size)])
      }
    }
  }
}

fn encode_header_fields(
  headers: List(HeaderField),
  table: DynamicTable,
  huffman: Bool,
  acc: List(BitArray),
) -> #(List(BitArray), DynamicTable) {
  case headers {
    [] -> #(acc, table)
    [header, ..remaining] -> {
      let #(pieces, table) = encode_header_field(header, table, huffman)
      let acc = list.fold(pieces, acc, fn(acc, piece) { [piece, ..acc] })
      encode_header_fields(remaining, table, huffman, acc)
    }
  }
}

fn encode_header_field(
  header: HeaderField,
  table: DynamicTable,
  huffman: Bool,
) -> #(List(BitArray), DynamicTable) {
  case match(table, header.name, header.value), header.indexing {
    FullMatch(index), _ -> #([encode_indexed(index)], table)

    // Name match + store; literal with incremental indexing.
    NameMatch(index), WithIndexing -> {
      let encoded = encode_literal(index, header.value, 6, 0x40, huffman)
      #(encoded, add_dynamic(table, header.name, header.value))
    }

    // Name match + don't store; literal without indexing.
    NameMatch(index), WithoutIndexing -> #(
      encode_literal(index, header.value, 4, 0x00, huffman),
      table,
    )

    // Name match + sensitive; literal never indexed.
    NameMatch(index), NeverIndexed -> #(
      encode_literal(index, header.value, 4, 0x10, huffman),
      table,
    )

    // No match + store; literal with incremental indexing, new name.
    NoMatch, WithIndexing -> {
      let encoded =
        encode_literal_new_name(header.name, header.value, 6, 0x40, huffman)
      #(encoded, add_dynamic(table, header.name, header.value))
    }

    // No match + don't store; literal without indexing, new name.
    NoMatch, WithoutIndexing -> #(
      encode_literal_new_name(header.name, header.value, 4, 0x00, huffman),
      table,
    )

    // No match + sensitive; literal never indexed, new name.
    NoMatch, NeverIndexed -> #(
      encode_literal_new_name(header.name, header.value, 4, 0x10, huffman),
      table,
    )
  }
}

// Encodes an integer with type bits set in the upper bits of the first byte.
fn encode_prefixed_integer(
  integer: Int,
  prefix: Int,
  type_bits: Int,
) -> BitArray {
  case encode_integer(integer, prefix:) {
    <<byte:8, remaining:bits>> -> <<{ byte + type_bits }:8, remaining:bits>>
    _ -> panic as "Unreachable pattern for encoded integer!"
  }
}

// 6.1 Indexed Header Field Representation.
fn encode_indexed(index: Int) -> BitArray {
  encode_prefixed_integer(index, 7, 0x80)
}

// 6.2.x Literal Header Field with name referenced by index.
fn encode_literal(
  index: Int,
  value: BitArray,
  prefix: Int,
  type_bits: Int,
  huffman: Bool,
) -> List(BitArray) {
  let index = encode_prefixed_integer(index, prefix, type_bits)
  let value = encode_string_literal(value, huffman:)
  [index, value]
}

// 6.2.x Literal Header Field with new name.
fn encode_literal_new_name(
  name: BitArray,
  value: BitArray,
  prefix: Int,
  type_bits: Int,
  huffman: Bool,
) -> List(BitArray) {
  let index = encode_prefixed_integer(0, prefix, type_bits)
  let name = encode_string_literal(name, huffman:)
  let value = encode_string_literal(value, huffman:)
  [index, name, value]
}
