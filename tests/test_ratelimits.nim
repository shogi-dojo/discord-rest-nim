import std/[asyncdispatch, asyncfutures, json, strutils, tables, unittest]
import discordrest

type
  TestClock = ref object
    now: float
    sleeps: seq[int]

  ParallelState = ref object
    calls: int
    active: int
    maximumActive: int
    paths: seq[string]
    times: seq[float]
    clock: TestClock

proc testClock(clock: TestClock): ClockProc =
  result = proc(): float = clock.now

proc testSleep(clock: TestClock): SleepProc =
  result = proc(milliseconds: int): Future[void] =
    clock.sleeps.add milliseconds
    clock.now += milliseconds.float / 1000.0
    let future = newFuture[void]("test.sleep")
    future.complete()
    future

proc headers(items: openArray[tuple[key, value: string]]): Table[string, string] =
  result = initTable[string, string]()
  for (key, value) in items: result[key] = value

proc jsonResponse(body: string, responseHeaders = initTable[string, string]()): HttpResponse =
  HttpResponse(status: 200, headers: responseHeaders, body: body)

proc response(status: int, body: string,
               responseHeaders = initTable[string, string]()): HttpResponse =
  HttpResponse(status: status, headers: responseHeaders, body: body)

proc runThree(client: DiscordClient): Future[void] {.async.} =
  let first = client.requestJson(dhmPost, "/channels/123/messages", %*{"content": "one"})
  let second = client.requestJson(dhmPost, "/channels/123/messages", %*{"content": "two"})
  let third = client.requestJson(dhmPost, "/channels/123/messages", %*{"content": "three"})
  discard await first
  discard await second
  discard await third

proc runTwo(client: DiscordClient, firstPath, secondPath: string): Future[void] {.async.} =
  let first = client.requestJson(dhmGet, firstPath)
  let second = client.requestJson(dhmGet, secondPath)
  discard await first
  discard await second

suite "Discord rate limits":
  test "route buckets include Discord major resources":
    let first = routeIdentity(dhmPost, "/channels/111/messages")
    let second = routeIdentity(dhmPost, "/channels/222/messages")
    let same = routeIdentity(dhmPost, "/channels/111/messages?wait=true")
    check first.key != second.key
    check first.major == "channels:111"
    check first.key == same.key
    check routeIdentity(dhmDelete, "/guilds/5/members/42").major == "guilds:5"
    check routeIdentity(dhmPut, "/webhooks/6/secret/messages/@original").major == "webhooks:6:secret"

  test "serializes same-bucket requests in FIFO order and lets other buckets progress":
    let state = ParallelState(paths: @[])
    let client = newDiscordClient("token", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc state.calls
        inc state.active
        state.maximumActive = max(state.maximumActive, state.active)
        state.paths.add parseJson(request.body)["content"].getStr
        await sleepAsync(5)
        dec state.active
        return jsonResponse("{}", headers([("x-ratelimit-bucket", "messages"), ("x-ratelimit-remaining", "9")]))
    ))
    waitFor runThree(client)
    check state.paths == @["one", "two", "three"]
    check state.maximumActive == 1
    client.close()

    let unrelated = ParallelState(paths: @[])
    let otherClient = newDiscordClient("token", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc unrelated.active
        unrelated.maximumActive = max(unrelated.maximumActive, unrelated.active)
        await sleepAsync(if request.url.contains("channels/1/"): 30 else: 1)
        dec unrelated.active
        return jsonResponse("{}", headers([("x-ratelimit-bucket", request.url)]))
    ))
    waitFor runTwo(otherClient, "/channels/1/messages", "/channels/2/messages")
    check unrelated.maximumActive == 2
    otherClient.close()

  test "rounds fractional retry_after upward and retries at most twice after 429":
    let clock = TestClock(now: 100.0, sleeps: @[])
    var attempts = 0
    let client = newDiscordClient("token", DiscordClientOptions(
      clock: testClock(clock),
      sleep: testSleep(clock),
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc attempts
        if attempts == 1:
          return response(429, """{"retry_after":0.0011}""", headers([("x-ratelimit-bucket", "fractional")]))
        return jsonResponse("{}")
    ))
    discard waitFor client.requestJson(dhmGet, "/guilds/1")
    check attempts == 2
    check clock.sleeps == @[2]
    client.close()

    let exhaustedClock = TestClock(now: 10.0, sleeps: @[])
    attempts = 0
    let exhausted = newDiscordClient("token", DiscordClientOptions(
      clock: testClock(exhaustedClock),
      sleep: testSleep(exhaustedClock),
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc attempts
        return response(429, """{"retry_after":0.0001}""", headers([("x-ratelimit-bucket", "always-limited")]))
    ))
    var failure: ref DiscordError
    try:
      discard waitFor exhausted.requestJson(dhmGet, "/channels/123/messages")
    except DiscordError as error:
      failure = error
    check failure != nil and failure.kind == deRateLimit
    check failure.retryAfterMs == 1
    check attempts == 3
    check exhaustedClock.sleeps.len >= 2
    var waitedMs = 0
    for milliseconds in exhaustedClock.sleeps: waitedMs += milliseconds
    check waitedMs >= 2
    exhausted.close()

  test "uses reset-after after exhausted response capacity and Retry-After when the body has no delay":
    let clock = TestClock(now: 30.0, sleeps: @[])
    var calls = 0
    let client = newDiscordClient("token", DiscordClientOptions(
      clock: testClock(clock), sleep: testSleep(clock),
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc calls
        if calls == 1:
          return jsonResponse("{}", headers([
            ("x-ratelimit-bucket", "reset-after"),
            ("x-ratelimit-remaining", "0"),
            ("x-ratelimit-reset-after", "0.01")
          ]))
        return jsonResponse("{}")
    ))
    discard waitFor client.requestJson(dhmGet, "/channels/5/messages")
    discard waitFor client.requestJson(dhmGet, "/channels/5/messages")
    check clock.sleeps == @[10]
    check calls == 2
    client.close()

    let retryClock = TestClock(now: 50.0, sleeps: @[])
    calls = 0
    let retryClient = newDiscordClient("token", DiscordClientOptions(
      clock: testClock(retryClock), sleep: testSleep(retryClock),
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc calls
        if calls == 1: return response(429, "{}", headers([("retry-after", "0.0023")]))
        return jsonResponse("{}")
    ))
    discard waitFor retryClient.requestJson(dhmGet, "/users/@me")
    check retryClock.sleeps == @[3]
    check calls == 2
    retryClient.close()

  test "global 429 throttles unrelated buckets for this client":
    let clock = TestClock(now: 100.0, sleeps: @[])
    let state = ParallelState(times: @[], clock: clock)
    let client = newDiscordClient("token", DiscordClientOptions(
      clock: testClock(clock),
      sleep: testSleep(clock),
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc state.calls
        state.times.add clock.now
        if state.calls <= 2:
          return response(429, """{"global":true,"retry_after":0.05}""",
                          headers([("x-ratelimit-scope", "global")]))
        return jsonResponse("{}")
    ))
    waitFor runTwo(client, "/channels/11/messages", "/users/@me")
    check state.calls == 4
    check state.times.len == 4
    check state.times[0] == 100.0 and state.times[1] == 100.0
    check state.times[2] >= 100.05 and state.times[3] >= 100.05
    client.close()

  test "a cancelled FIFO waiter is removed without preventing later work":
    var calls = 0
    let client = newDiscordClient("token", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc calls
        await sleepAsync(15)
        return jsonResponse("{}", headers([("x-ratelimit-bucket", "cancel-test")]))
    ))
    let cancellation = newCancellationToken()
    proc run(): Future[void] {.async.} =
      let first = client.requestJson(dhmPost, "/channels/7/messages", %*{"content": "first"})
      let waiting = client.requestJson(dhmPost, "/channels/7/messages", %*{"content": "cancel"},
                                       cancellation = cancellation)
      await sleepAsync(1)
      cancellation.cancel()
      var cancelled = false
      try:
        discard await waiting
      except DiscordError as error:
        cancelled = error.kind == deCancelled
      discard await first
      check cancelled
    waitFor run()
    check calls == 1
    client.close()

  test "a waiter cancelled after it was handed the bucket passes the bucket on":
    # Without a dispatcher, futures run their callbacks at once and the race cannot happen.
    discard getGlobalDispatcher()
    let limiter = newRateLimiter()
    let first = waitFor limiter.acquire(dhmGet, "/channels/9/messages", newCancellationToken())
    let cancellation = newCancellationToken()
    let handedOver = limiter.acquire(dhmGet, "/channels/9/messages", cancellation)
    # The release completes the waiter at once but resumes it only on the next poll,
    # so this cancellation lands after the bucket was already handed over.
    limiter.release(first)
    cancellation.cancel()
    var cancelled = false
    try:
      discard waitFor handedOver
    except DiscordError as error:
      cancelled = error.kind == deCancelled
    check cancelled
    let later = limiter.acquire(dhmGet, "/channels/9/messages", newCancellationToken())
    check waitFor withTimeout(later, 100)
    limiter.release(later.read)

  test "limiter state is per client, including global windows":
    let firstClock = TestClock(now: 200.0, sleeps: @[])
    let secondClock = TestClock(now: 200.0, sleeps: @[])
    var firstCalls = 0
    var secondCalls = 0
    let firstClient = newDiscordClient("token-a", DiscordClientOptions(
      clock: testClock(firstClock), sleep: testSleep(firstClock),
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc firstCalls
        if firstCalls == 1: return response(429, """{"global":true,"retry_after":0.1}""")
        return jsonResponse("{}")
    ))
    let secondClient = newDiscordClient("token-b", DiscordClientOptions(
      clock: testClock(secondClock), sleep: testSleep(secondClock),
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc secondCalls
        return jsonResponse("{}")
    ))
    discard waitFor firstClient.requestJson(dhmGet, "/channels/1/messages")
    discard waitFor secondClient.requestJson(dhmGet, "/channels/1/messages")
    check firstClock.now >= 200.1
    check secondClock.now == 200.0
    check firstCalls == 2 and secondCalls == 1
    firstClient.close()
    secondClient.close()
