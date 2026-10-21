# discord-rest-nim

A small, asynchronous Nim library for the Discord HTTP protocols used by
Riichi Dojo. It targets Nim 2.2.12 and OpenSSL 3, and intentionally excludes
Gateway sessions, voice, listeners, uploads and unrelated Discord resources.

The first release is being developed on `feat/client-v1`. The compatibility
matrix in [`docs/compatibility.md`](docs/compatibility.md) records the Bun
behavior and the test that proves each adapter-facing protocol.

The public API is exported from `discordrest`: `DiscordClient` for async HTTP,
message/DM/pin helpers, application-command list/replace helpers, OAuth code
exchange and current-user lookup, and raw-body Ed25519 verification. The
helpers leave policy with the caller: they do not render messages, split image
galleries, shape polls or decide which Activity commands to keep.

## Installation

After the initial public release, install an exact tested commit without
credentials:

```sh
nimble install https://github.com/shogi-dojo/discord-rest-nim#<full-commit-sha>
```

Then import `discordrest`. The library has no package dependencies outside the
Nim standard library. HTTPS and signature verification use OpenSSL 3.

## Development

```sh
nimble test
```

The `nimble test` task runs the Nim unit suites and the Ruby 4.0.7 loopback
contract fixture, including connection reuse, the four-connection cap, peer
disconnects, a lost response after an accepted POST, and an untrusted TLS peer.

Build with `-d:ssl`; install OpenSSL 3 development files (Linux) or
`openssl@3` (macOS). The interaction verifier loads OpenSSL 3 at runtime. On
macOS it checks `OPENSSL_DIR`, the Homebrew Apple Silicon and Intel prefixes,
then the dynamic loader path; Linux uses `libcrypto.so.3`.

The async client and its HTTP connections belong to one event-loop thread.
Applications with a separate state-owner thread should pass owned serialized
requests to a transport thread and deliver correlated serialized completions.
Never pass futures, mutable JSON nodes, SQLite stores or mutable references
between threads. See [`docs/lifecycle.md`](docs/lifecycle.md) for shutdown and
dependency-update guidance.

## Security

The client does not log requests or responses. Application code should not log
access tokens, authorization codes, message bodies, or raw provider responses.
The Ed25519 interaction helper verifies the timestamp plus the original raw
body bytes; callers must perform that check before decoding or normalizing JSON.

## License

MIT. See [`LICENSE`](LICENSE).
