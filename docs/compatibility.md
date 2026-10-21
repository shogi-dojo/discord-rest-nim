# Riichi Dojo compatibility matrix

The Bun implementation in Riichi Dojo is the application compatibility oracle.
Each row links protocol behavior to a package test. Business policy remains in
the application adapter.

| Capability | Required behavior | Package proof | Application status |
|---|---|---|---|
| Channel messages | POST caller-provided content, flags, embeds, polls and `allowed_mentions`; snowflake IDs stay strings | `tests/test_protocol_helpers.nim`, `tests/test_client.nim` | Not migrated |
| Image galleries | Caller payload passes through unchanged; gallery grouping and caption placement stay application policy | `tests/test_protocol_helpers.nim` | Not migrated |
| Native polls | Caller payload passes through unchanged; question/answer limits and duration stay application policy | `tests/test_protocol_helpers.nim` | Not migrated |
| Pinning | PUT current pins endpoint; accept HTTP 204 | `tests/test_protocol_helpers.nim` | Not migrated |
| Direct messages | Open DM, decode its string ID, then allow caller to send in order | `tests/test_protocol_helpers.nim` | Not migrated |
| Commands | GET/PUT application commands; caller chooses which Activity entries to preserve | `tests/test_protocol_helpers.nim` | Not migrated |
| Interactions | Verify Ed25519 over timestamp plus untouched body; build PONG, autocomplete and ephemeral shapes | `tests/test_protocol_helpers.nim` | Handlers not migrated |
| Browser OAuth | Form-encoded exchange includes `redirect_uri`; current-user lookup uses Bearer auth | `tests/test_protocol_helpers.nim` | Sign-in not migrated |
| Activity OAuth | Form-encoded exchange omits `redirect_uri`; access token remains caller-owned | `tests/test_protocol_helpers.nim` | Sign-in not migrated |
| Rate limits | Bucket + major-resource identity, global wait, fractional delays, cancellation and FIFO | `tests/test_ratelimits.nim` | N/A |
| Connections | At most four per client by default; reuse keep-alive sockets | `tests/fixtures/http_contract.rb` | N/A |

`N/A` means transport behavior has no corresponding business-handler migration.
Recorder parity is separate from network compatibility: a recorded call alone
does not prove the HTTP implementation. Image and poll presentation rules are
intentionally verified at the application boundary, not in this protocol
package.
