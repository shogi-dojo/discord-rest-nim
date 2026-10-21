import std/[asyncdispatch, asyncfutures, json, math, options, strutils, tables, times]
import ./[errors, transport, types]

type
  ClockProc* = proc(): float {.closure.}
  SleepProc* = proc(milliseconds: int): Future[void] {.closure.}

  RateBucket = ref object
    busy: bool
    remaining: int
    resetAtMs: int64
    waiters: seq[Future[void]]

  RateLimiter* = ref object
    now: ClockProc
    sleep: SleepProc
    routes: Table[string, string]
    buckets: Table[string, RateBucket]
    globalUntilMs: int64

  RateLease* = object
    routeKey*: string
    bucketKey*: string
    major*: string

proc systemClock(): float = epochTime()
proc systemSleep(milliseconds: int): Future[void] = sleepAsync(milliseconds)

proc newRateLimiter*(clock: ClockProc = nil, sleeper: SleepProc = nil): RateLimiter =
  RateLimiter(
    now: if clock == nil: systemClock else: clock,
    sleep: if sleeper == nil: systemSleep else: sleeper,
    routes: initTable[string, string](),
    buckets: initTable[string, RateBucket](),
    globalUntilMs: 0
  )

proc nowMs(limiter: RateLimiter): int64 = int64(floor(limiter.now() * 1000.0))

proc bucketFor(limiter: RateLimiter, key: string): RateBucket =
  if key notin limiter.buckets:
    limiter.buckets[key] = RateBucket(remaining: -1, waiters: @[])
  limiter.buckets[key]

proc routeIdentity*(httpMethod: DiscordHttpMethod, path: string): tuple[key, major: string] =
  let route = path.split('?')[0]
  var segments: seq[string] = @[]
  for segment in route.split('/'):
    if segment.len > 0: segments.add segment
  var major = ""
  if segments.len >= 2:
    case segments[0]
    of "channels", "guilds": major = segments[0] & ":" & segments[1]
    of "webhooks":
      if segments.len >= 3: major = "webhooks:" & segments[1] & ":" & segments[2]
    else: discard
  var normalized: seq[string] = @[]
  for index, segment in segments:
    if segment.len > 0 and segment[0] in {'0'..'9'} and segment.allCharsInSet({'0'..'9'}):
      normalized.add ":id"
    else:
      normalized.add segment
  result.major = major
  result.key = httpMethod.httpMethodName & ":/" & normalized.join("/") & "|" & major

proc removeWaiter(bucket: RateBucket, waiter: Future[void]) =
  for index in countdown(bucket.waiters.high, 0):
    if bucket.waiters[index] == waiter:
      bucket.waiters.delete(index)
      break

proc release(bucket: RateBucket) =
  bucket.busy = false
  while bucket.waiters.len > 0:
    let waiter = bucket.waiters[0]
    bucket.waiters.delete(0)
    if waiter.finished: continue
    bucket.busy = true
    waiter.complete()
    break

proc release(limiter: RateLimiter, key: string) =
  limiter.bucketFor(key).release()

proc waitForLock(limiter: RateLimiter, bucket: RateBucket,
                 cancellation: CancellationToken) {.async.} =
  cancellation.checkCancellation()
  if not bucket.busy:
    bucket.busy = true
    return
  let waiter = newFuture[void]("discordrest.rateLimit.bucket")
  bucket.waiters.add waiter
  let cancelId = cancellation.onCancel(proc() =
    if not waiter.finished:
      waiter.fail(discordError(deCancelled, "Discord request cancelled while waiting for its rate-limit bucket"))
  )
  try:
    await waiter
    cancellation.checkCancellation()
  except CatchableError:
    bucket.removeWaiter(waiter)
    # `release` may have handed this waiter the bucket before the cancellation was seen;
    # pass it on, or every later request on this bucket waits forever.
    if waiter.finished and not waiter.failed: bucket.release()
    raise
  finally:
    cancellation.removeCancelCallback(cancelId)

proc waitCancellable(limiter: RateLimiter, milliseconds: int,
                     cancellation: CancellationToken) {.async.} =
  var remaining = milliseconds
  while remaining > 0:
    cancellation.checkCancellation()
    let slice = min(remaining, 25)
    await limiter.sleep(slice)
    remaining -= slice
  cancellation.checkCancellation()

proc acquire*(limiter: RateLimiter, httpMethod: DiscordHttpMethod, path: string,
              cancellation: CancellationToken): Future[RateLease] {.async.} =
  let identity = routeIdentity(httpMethod, path)
  while true:
    cancellation.checkCancellation()
    let key = limiter.routes.getOrDefault(identity.key, "route:" & identity.key)
    let bucket = limiter.bucketFor(key)
    await limiter.waitForLock(bucket, cancellation)
    # A queued route may have learned its server bucket while it waited on the
    # provisional route key. Release that key and join the now-canonical bucket.
    if limiter.routes.getOrDefault(identity.key, "route:" & identity.key) != key:
      limiter.release(key)
      continue
    result = RateLease(routeKey: identity.key, bucketKey: key, major: identity.major)
    try:
      while true:
        cancellation.checkCancellation()
        let now = limiter.nowMs()
        var waitUntil = limiter.globalUntilMs
        if bucket.remaining == 0 and bucket.resetAtMs > waitUntil:
          waitUntil = bucket.resetAtMs
        let waitMs = max(0'i64, waitUntil - now).int
        if waitMs <= 0: break
        await limiter.waitCancellable(waitMs, cancellation)
      return result
    except CatchableError:
      limiter.release(key)
      raise

proc parseSeconds(value: string): Option[float] =
  if value.len == 0: return none(float)
  try:
    let parsed = parseFloat(value)
    if parsed >= 0 and parsed < 86_400: return some(parsed)
  except ValueError:
    discard
  none(float)

proc retrySeconds(response: HttpResponse): float =
  var body: JsonNode
  try: body = parseJson(response.body)
  except CatchableError: discard
  if body != nil and body.kind == JObject and body.hasKey("retry_after") and
      body["retry_after"].kind in {JInt, JFloat}:
    let value = body["retry_after"].getFloat
    if value >= 0 and value < 86_400: return value
  let fromHeader = response.headers.getOrDefault("retry-after")
  let fromRetry = parseSeconds(fromHeader)
  if fromRetry.isSome: return fromRetry.get
  let reset = parseSeconds(response.headers.getOrDefault("x-ratelimit-reset-after"))
  if reset.isSome: return reset.get
  1.0

proc isGlobal(response: HttpResponse): bool =
  if response.headers.getOrDefault("x-ratelimit-scope").toLowerAscii == "global": return true
  try:
    let body = parseJson(response.body)
    body.kind == JObject and body.hasKey("global") and body["global"].kind == JBool and body["global"].getBool
  except CatchableError:
    false

proc observe*(limiter: RateLimiter, lease: RateLease, response: HttpResponse): int =
  ## Updates bucket state from Discord's headers and, for a 429, returns the
  ## retry delay rounded upward to a whole millisecond.
  var key = lease.bucketKey
  let serverBucket = response.headers.getOrDefault("x-ratelimit-bucket")
  if serverBucket.len > 0:
    key = "server:" & serverBucket & "|" & lease.major
    limiter.routes[lease.routeKey] = key
  let bucket = limiter.bucketFor(key)
  let remaining = response.headers.getOrDefault("x-ratelimit-remaining")
  if remaining.len > 0:
    try: bucket.remaining = parseInt(remaining)
    except ValueError: discard
  let resetAfter = parseSeconds(response.headers.getOrDefault("x-ratelimit-reset-after"))
  if resetAfter.isSome:
    bucket.resetAtMs = limiter.nowMs() + int64(ceil(resetAfter.get * 1000.0))
  if response.status == 429:
    result = int(ceil(retrySeconds(response) * 1000.0))
    let retryAt = limiter.nowMs() + result.int64
    if response.isGlobal:
      limiter.globalUntilMs = max(limiter.globalUntilMs, retryAt)
    else:
      bucket.remaining = 0
      bucket.resetAtMs = max(bucket.resetAtMs, retryAt)

proc release*(limiter: RateLimiter, lease: RateLease) =
  limiter.release(lease.bucketKey)
