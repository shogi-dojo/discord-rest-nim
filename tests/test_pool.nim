## The connection pool is private to the transport, so this suite includes the module.
import std/unittest
include discordrest/transport

suite "Discord connection pool":
  test "a waiter cancelled after it was handed a slot gives the slot back":
    # Without a dispatcher, futures run their callbacks at once and the race cannot happen.
    discard getGlobalDispatcher()
    let pool = newConnectionPool(1)
    let origin = originOf("https://discord.com/api/v10/channels/1/messages")
    let first = waitFor pool.acquire(origin, newCancellationToken())
    let cancellation = newCancellationToken()
    let handedOver = pool.acquire(origin, cancellation)
    # The release completes the waiter at once but resumes it only on the next poll,
    # so this cancellation lands after the slot was already handed over.
    pool.release(first)
    cancellation.cancel()
    var cancelled = false
    try:
      discard waitFor handedOver
    except DiscordError as error:
      cancelled = error.kind == deCancelled
    check cancelled
    let later = pool.acquire(origin, newCancellationToken())
    check waitFor withTimeout(later, 100)
    pool.close()
