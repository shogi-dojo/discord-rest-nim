version       = "0.1.0"
author        = "shogi-dojo"
description   = "A small asynchronous Discord HTTP and interaction protocol client for Nim"
license       = "MIT"
srcDir        = "src"
requires      "nim >= 2.2.12"

task test, "Run the discordrest unit tests":
  exec "nim c -r -d:ssl --hints:off --path:src --nimcache:tests/nimcache --outdir:tests/bin tests/test_discordrest.nim"
  exec "nim c -r -d:ssl --hints:off --path:src --nimcache:tests/nimcache --outdir:tests/bin tests/test_client.nim"
  exec "nim c -r -d:ssl --hints:off --path:src --nimcache:tests/nimcache --outdir:tests/bin tests/test_ratelimits.nim"
  exec "nim c -r -d:ssl --hints:off --path:src --nimcache:tests/nimcache --outdir:tests/bin tests/test_protocol_helpers.nim"
  exec "nim c -d:ssl --hints:off --path:src --nimcache:tests/nimcache --out:tests/bin/discordrest_probe tests/fixtures/http_probe.nim"
  exec "ruby tests/fixtures/http_contract.rb tests/bin/discordrest_probe"
