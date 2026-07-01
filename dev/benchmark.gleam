import alpacki
import gleam/dynamic
import gleam/int
import gleam/list
import glychee/benchmark
import glychee/configuration

pub type HpaxTable

@external(erlang, "hpax_ffi", "new")
pub fn new(max_size: Int) -> HpaxTable

@external(erlang, "hpax_ffi", "resize")
pub fn resize(table: HpaxTable, new_size: Int) -> HpaxTable

@external(erlang, "hpax_ffi", "decode")
pub fn decode(data: BitArray, table: HpaxTable) -> dynamic.Dynamic

@external(erlang, "hpax_ffi", "encode_store")
pub fn encode_store(
  headers: List(#(BitArray, BitArray)),
  table: HpaxTable,
) -> #(BitArray, HpaxTable)

pub fn main() {
  configuration.initialize()
  configuration.set_pair(configuration.Warmup, 2)
  configuration.set_pair(configuration.Parallel, 1)

  run_encode_benchmark()
  run_decode_benchmark()
  run_resize_benchmark()
}

const table_size = 4096

fn small_headers() -> List(#(BitArray, BitArray)) {
  [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
    #(<<":authority":utf8>>, <<"www.example.com":utf8>>),
    #(<<"accept":utf8>>, <<"*/*":utf8>>),
    #(<<"user-agent":utf8>>, <<"alpacki-bench/1.0":utf8>>),
  ]
}

fn large_headers() -> List(#(BitArray, BitArray)) {
  let extra =
    int.range(from: 1, to: 40, with: [], run: list.prepend)
    |> list.map(fn(i) {
      let n = int.to_string(i)
      #(<<"x-custom-header-":utf8, n:utf8>>, <<"value-":utf8, n:utf8>>)
    })
  list.append(small_headers(), extra)
}

fn to_header_fields(
  headers: List(#(BitArray, BitArray)),
) -> List(alpacki.HeaderField) {
  list.map(headers, fn(header) {
    let #(name, value) = header
    alpacki.HeaderField(name:, value:, indexing: alpacki.WithIndexing)
  })
}

// Encode
// -----------------------------------------------------------------------------

fn run_encode_benchmark() {
  benchmark.run(
    [
      benchmark.Function(label: "alpacki", callable: fn(headers) {
        let fields = to_header_fields(headers)
        fn() {
          let _ =
            alpacki.encode_header_block(
              fields,
              alpacki.new_dynamic(table_size),
              False,
            )
          Nil
        }
      }),
      benchmark.Function(label: "hpax", callable: fn(headers) {
        fn() {
          let _ = encode_store(headers, new(table_size))
          Nil
        }
      }),
    ],
    [
      benchmark.Data(label: "encode: small (6 headers)", data: small_headers()),
      benchmark.Data(label: "encode: large (46 headers)", data: large_headers()),
    ],
  )
}

// Decode
// -----------------------------------------------------------------------------

fn run_decode_benchmark() {
  let #(alpacki_small, _) =
    alpacki.encode_header_block(
      to_header_fields(small_headers()),
      alpacki.new_dynamic(table_size),
      False,
    )
  let #(alpacki_large, _) =
    alpacki.encode_header_block(
      to_header_fields(large_headers()),
      alpacki.new_dynamic(table_size),
      False,
    )
  let #(hpax_small, _) = encode_store(small_headers(), new(table_size))
  let #(hpax_large, _) = encode_store(large_headers(), new(table_size))

  benchmark.run(
    [
      benchmark.Function(label: "alpacki", callable: fn(data) {
        let #(alpacki_bytes, _hpax_bytes) = data
        fn() {
          let _ =
            alpacki.decode_header_block(
              alpacki_bytes,
              alpacki.new_dynamic(table_size),
            )
          Nil
        }
      }),
      benchmark.Function(label: "hpax", callable: fn(data) {
        let #(_alpacki_bytes, hpax_bytes) = data
        fn() {
          let _ = decode(hpax_bytes, new(table_size))
          Nil
        }
      }),
    ],
    [
      benchmark.Data(label: "decode: small (6 headers)", data: #(
        alpacki_small,
        hpax_small,
      )),
      benchmark.Data(label: "decode: large (46 headers)", data: #(
        alpacki_large,
        hpax_large,
      )),
    ],
  )
}

// Resize
// -----------------------------------------------------------------------------

fn run_resize_benchmark() {
  let #(_, alpacki_table) =
    alpacki.encode_header_block(
      to_header_fields(large_headers()),
      alpacki.new_dynamic(table_size),
      False,
    )
  let #(_, hpax_table) = encode_store(large_headers(), new(table_size))

  benchmark.run(
    [
      benchmark.Function(label: "alpacki", callable: fn(table) {
        fn() {
          let _ =
            alpacki.resize_dynamic(table, 0)
            |> alpacki.resize_dynamic(table_size)
          Nil
        }
      }),
      benchmark.Function(label: "hpax", callable: fn(_table) {
        fn() {
          let _ =
            resize(hpax_table, 0)
            |> resize(table_size)
          Nil
        }
      }),
    ],
    [
      benchmark.Data(
        label: "resize: populated table (46 entries)",
        data: alpacki_table,
      ),
    ],
  )
}
