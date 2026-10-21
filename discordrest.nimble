version       = "0.1.0"
author        = "shogi-dojo"
description   = "A small asynchronous Discord HTTP and interaction protocol client for Nim"
license       = "MIT"
srcDir        = "src"
requires      "nim >= 2.2.12"

task test, "Run the discordrest unit tests":
  exec "nim c -r -d:ssl --hints:off --path:src --nimcache:tests/nimcache --outdir:tests/bin tests/test_discordrest.nim"
