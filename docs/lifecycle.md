# Client lifecycle and dependency updates

## Client ownership

Create one `DiscordClient` per credential set and keep it on one async event-loop
thread. Its HTTP pool, cancellation tokens and rate-limit buckets are mutable
single-thread state. The default pool has four reusable connections. Call
`close()` on that same thread during shutdown; it cancels active requests and
closes the pool.

An application with an owner thread must not wait for Discord while holding a
room lock or database transaction. Send an owned serialized request to a
transport-thread dispatcher, and return a completion containing the correlation
id plus serialized JSON or a structured error. Do not send `JsonNode`, futures,
SQLite handles or mutable refs between threads. Bound the submission queue and
return an explicit queue-full result.

Each network attempt has a ten-second timeout by default. The client retries
429s at most twice after honoring fractional `retry_after` and rate-limit
headers. It does not retry ambiguous message creation, OAuth exchanges or other
non-429 failures. Caller cancellation is supported, and closing a client
cancels its in-flight work.

## Dependency updates

Riichi pins a full tested commit SHA from the public repository. To update it:

1. Review the compatibility matrix and current Discord API contract.
2. Run the Nim unit suite and Ruby loopback contract fixture on Linux and macOS.
3. Record the commit SHA from a successful library CI run.
4. Update the pinned SHA in Riichi, then run adapter recorder tests and room
   validation gates before opening an application PR.

The package has no Nimble dependencies. A fresh Nimble directory must be able
to install it over public HTTPS without GitHub credentials or a preinstalled
Discord package.
