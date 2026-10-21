# Riichi Dojo compatibility matrix

The Bun implementation in Riichi Dojo is the application compatibility oracle.
Each row links the protocol behavior to a package test. Business policy remains
in the application adapter.

| Capability | Required behavior | Package proof | Application status |
|---|---|---|---|
| Channel messages | POST content, flags and `allowed_mentions`; decode snowflake IDs as strings | `tests/test_endpoints.nim`, `tests/fixtures/http_contract.rb` | Not migrated |
| Image galleries | Preserve groups of four and first-image caption placement | `tests/test_endpoints.nim` | Not migrated |
| Native polls | Serialize question, answers, duration and multiselect | `tests/test_endpoints.nim` | Not migrated |
| Pinning | PUT current pins endpoint; accept HTTP 204 | `tests/test_endpoints.nim` | Not migrated |
| Direct messages | Open DM, decode its ID, then send in order | `tests/test_endpoints.nim` | Not migrated |
| Commands | GET/PUT application commands without modifying application policy | `tests/test_endpoints.nim` | Not migrated |
| Interactions | Verify Ed25519 over timestamp plus untouched body; build PONG, autocomplete and ephemeral shapes | `tests/test_signatures.nim`, `tests/test_interactions.nim` | Handlers not migrated |
| Browser OAuth | Exchange code with `redirect_uri`, then GET current user | `tests/test_oauth.nim` | Sign-in not migrated |
| Activity OAuth | Exchange without `redirect_uri`; return transient access token to caller | `tests/test_oauth.nim` | Sign-in not migrated |
| Rate limits | Bucket + major-resource identity, global wait, fractional retry delays, cancellation and FIFO | `tests/test_ratelimits.nim` | N/A |
| Connections | At most four per client by default; reuse keep-alive sockets | `tests/fixtures/http_contract.rb` | N/A |

`N/A` means transport behavior has no corresponding business-handler migration.
Recorder parity is separate from network compatibility: a recorded call alone
does not prove the HTTP implementation.
