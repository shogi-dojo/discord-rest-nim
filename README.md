# discord-rest-nim

A small, asynchronous Nim library for the Discord HTTP protocols used by
Riichi Dojo. It targets Nim 2.2.12 and OpenSSL 3, and intentionally excludes
Gateway sessions, voice, listeners, uploads and unrelated Discord resources.

The first release is being developed on `feat/client-v1`. The compatibility
matrix in [`docs/compatibility.md`](docs/compatibility.md) records the Bun
behavior and the test that proves each adapter-facing protocol.

## Installation

After the initial public release, install an exact tested commit without
credentials:

```sh
nimble install https://github.com/shogi-dojo/discord-rest-nim@<full-commit-sha>
```

Then import `discordrest`. The library has no package dependencies outside the
Nim standard library. HTTPS and signature verification use OpenSSL 3.

## Development

```sh
nimble test
ruby tests/fixtures/http_contract.rb tests/bin/discordrest_probe
```

Build with `-d:ssl`; install OpenSSL 3 development files (Linux) or
`openssl@3` (macOS). The async client and its HTTP connections belong to one
event-loop thread. Applications that have a separate state-owner thread should
send owned serialized requests to a transport thread and return correlated
serialized completions.

## Security

The client does not log requests or responses. Application code should not log
access tokens, authorization codes, message bodies, or raw provider responses.
The Ed25519 interaction helper verifies the timestamp plus the original raw
body bytes; callers must perform that check before decoding or normalizing JSON.

## License

MIT. See [`LICENSE`](LICENSE).
