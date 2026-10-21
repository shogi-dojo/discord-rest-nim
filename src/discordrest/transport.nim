import std/[asyncdispatch, asyncfutures, httpclient, httpcore, strutils, tables, uri]
import ./[errors, types]

type
  CancellationToken* = ref object
    wasCancelled: bool
    nextCallbackId: int
    callbacks: seq[tuple[id: int, callback: proc() {.closure.}]]

  HttpRequest* = object
    httpMethod*: DiscordHttpMethod
    url*: string
    headers*: Table[string, string]
    body*: string
    hasBody*: bool

  HttpResponse* = object
    status*: int
    headers*: Table[string, string]
    body*: string

  TransportProc* = proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.closure.}
  CloseTransportProc* = proc() {.closure.}

  PoolSlot = ref object
    client: AsyncHttpClient
    origin: string
    busy: bool

  PoolWaiter = ref object
    future: Future[int]
    origin: string

  ConnectionPool = ref object
    maximum: int
    slots: seq[PoolSlot]
    waiters: seq[PoolWaiter]
    closed: bool

proc newCancellationToken*(): CancellationToken =
  CancellationToken(wasCancelled: false, nextCallbackId: 0, callbacks: @[])

proc isCancelled*(token: CancellationToken): bool =
  token == nil or token.wasCancelled

proc cancel*(token: CancellationToken) =
  if token == nil or token.wasCancelled: return
  token.wasCancelled = true
  for item in token.callbacks:
    item.callback()
  token.callbacks.setLen(0)

proc onCancel*(token: CancellationToken, callback: proc() {.closure.}): int =
  if token == nil: return 0
  if token.wasCancelled:
    callback()
  else:
    inc token.nextCallbackId
    result = token.nextCallbackId
    token.callbacks.add (result, callback)

proc removeCancelCallback*(token: CancellationToken, id: int) =
  if token == nil or id == 0: return
  for index in countdown(token.callbacks.high, 0):
    if token.callbacks[index].id == id:
      token.callbacks.delete(index)
      break

proc checkCancellation*(token: CancellationToken) =
  if token.isCancelled:
    raise discordError(deCancelled, "Discord request cancelled")

proc normalizedHeaders(headers: HttpHeaders): Table[string, string] =
  result = initTable[string, string]()
  for key, values in headers.table:
    if values.len > 0: result[key.toLowerAscii] = values[0]

proc makeHeaders(request: HttpRequest): HttpHeaders =
  result = newHttpHeaders()
  for key, value in request.headers:
    result[key] = value

proc httpMethodValue(httpMethod: DiscordHttpMethod): HttpMethod =
  case httpMethod
  of dhmGet: HttpGet
  of dhmPost: HttpPost
  of dhmPut: HttpPut
  of dhmPatch: HttpPatch
  of dhmDelete: HttpDelete

proc originOf*(url: string): string =
  let parsed = parseUri(url)
  let defaultPort = if parsed.scheme == "https": "443" else: "80"
  parsed.scheme.toLowerAscii & "://" & parsed.hostname.toLowerAscii & ":" &
    (if parsed.port.len == 0: defaultPort else: parsed.port)

proc newConnectionPool(maximum: int): ConnectionPool =
  ConnectionPool(maximum: max(1, maximum), slots: @[], waiters: @[])

proc removeWaiter(pool: ConnectionPool, waiter: PoolWaiter) =
  for index in countdown(pool.waiters.high, 0):
    if pool.waiters[index] == waiter:
      pool.waiters.delete(index)
      break

proc release(pool: ConnectionPool, index: int, discardConnection = false) =
  if index < 0 or index >= pool.slots.len: return
  let slot = pool.slots[index]
  if discardConnection or pool.closed: slot.client.close()
  slot.busy = false
  if pool.closed: return
  while pool.waiters.len > 0:
    let waiter = pool.waiters[0]
    pool.waiters.delete(0)
    if waiter.future.finished: continue
    slot.busy = true
    slot.origin = waiter.origin
    waiter.future.complete(index)
    break

proc acquire(pool: ConnectionPool, origin: string,
             cancellation: CancellationToken): Future[int] {.async.} =
  cancellation.checkCancellation()
  if pool.closed: raise discordError(deClosed, "Discord connection pool is closed")
  for index, slot in pool.slots:
    if not slot.busy and slot.origin == origin:
      slot.busy = true
      return index
  for index, slot in pool.slots:
    if not slot.busy:
      slot.busy = true
      slot.origin = origin
      return index
  if pool.slots.len < pool.maximum:
    let slot = PoolSlot(client: newAsyncHttpClient(userAgent = "discordrest/0.1.0", maxRedirects = 0),
                        origin: origin, busy: true)
    pool.slots.add slot
    return pool.slots.high

  let waiter = PoolWaiter(future: newFuture[int]("discordrest.pool.acquire"), origin: origin)
  pool.waiters.add waiter
  let cancelId = cancellation.onCancel(proc() =
    if not waiter.future.finished:
      waiter.future.fail(discordError(deCancelled, "Discord request cancelled while waiting for a connection"))
  )
  try:
    result = await waiter.future
    cancellation.checkCancellation()
  except CatchableError:
    pool.removeWaiter(waiter)
    # `release` may have handed this waiter a slot before the cancellation was seen;
    # give it back, or the pool loses that connection for good.
    if waiter.future.finished and not waiter.future.failed: pool.release(waiter.future.read)
    raise
  finally:
    cancellation.removeCancelCallback(cancelId)

proc close(pool: ConnectionPool) =
  if pool == nil or pool.closed: return
  pool.closed = true
  for slot in pool.slots: slot.client.close()
  for waiter in pool.waiters:
    if not waiter.future.finished:
      waiter.future.fail(discordError(deClosed, "Discord connection pool is closed"))
  pool.waiters.setLen(0)

proc asyncHttpRequest(pool: ConnectionPool, request: HttpRequest,
                      cancellation: CancellationToken): Future[HttpResponse] {.async.} =
  cancellation.checkCancellation()
  let index = await pool.acquire(originOf(request.url), cancellation)
  let client = pool.slots[index].client
  let cancelId = cancellation.onCancel(proc() = client.close())
  var reusable = false
  try:
    let response = await client.request(
      request.url,
      httpMethod = httpMethodValue(request.httpMethod),
      body = if request.hasBody: request.body else: "",
      headers = makeHeaders(request)
    )
    result.status = int(response.code)
    result.headers = normalizedHeaders(response.headers)
    result.body = await response.body
    reusable = true
  finally:
    cancellation.removeCancelCallback(cancelId)
    pool.release(index, discardConnection = not reusable)

proc newDefaultTransport*(connectionLimit: int): tuple[transport: TransportProc, close: CloseTransportProc] =
  let pool = newConnectionPool(connectionLimit)
  result.transport = proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] =
    asyncHttpRequest(pool, request, cancellation)
  result.close = proc() = pool.close()
