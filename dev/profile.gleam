// Profiles alpacki's encode/decode on a larger header set with eprof to
// find the actual hot functions, instead of guessing from reading code.
//
// Run with: gleam run -m profile

import alpacki
import gleam/int
import gleam/io
import gleam/list

@external(erlang, "profile_ffi", "eprof")
fn eprof(run: fn() -> a) -> a

const table_size = 4096

fn large_headers() -> List(alpacki.HeaderField) {
  let extra =
    int.range(from: 1, to: 200, with: [], run: list.prepend)
    |> list.map(fn(i) {
      let n = int.to_string(i)
      alpacki.HeaderField(
        name: <<"x-custom-header-":utf8, n:utf8>>,
        value: <<"value-":utf8, n:utf8>>,
        indexing: alpacki.WithIndexing,
      )
    })
  extra
}

pub fn main() {
  let headers = large_headers()

  io.println("\n==== profiling encode (200 headers) ====\n")
  let #(encoded, _table) =
    eprof(fn() {
      alpacki.encode_header_block(headers, alpacki.new_dynamic(table_size), False)
    })

  io.println("\n==== profiling decode (200 headers) ====\n")
  let _ =
    eprof(fn() {
      alpacki.decode_header_block(encoded, alpacki.new_dynamic(table_size))
    })

  Nil
}
