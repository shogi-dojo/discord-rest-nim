import std/[asyncdispatch, asyncfutures, json, options, strutils, tables]
import ./[errors, ratelimits, transport, types]

type
  DiscordAuthKind* = enum
    dakNone,
    dakBot,
    dakBearer

  DiscordAuth* = object
    kind*: DiscordAuthKind
    token*: string

  DiscordClientOptions* = object
    apiBaseUrl*: string
    requestTimeoutMs*: int
    connectionLimit*: int
    transport*: TransportProc
    closeTransport*: CloseTransportProc
    clock*: ClockProc
    sleep*: SleepProc

  DiscordClient* = ref object
    botToken: string
    apiBaseUrl: string
    requestTimeoutMs: int
    transport: TransportProc
    closeTransport: CloseTransportProc
    limiter: RateLimiter
    closed: bool
    active: seq[CancellationToken]

proc noAuth*(): DiscordAuth = DiscordAuth(kind: dakNone)
proc botAuth*(token: string): DiscordAuth = DiscordAuth(kind: dakBot, token: token)
proc bearerAuth*(token: string): DiscordAuth = DiscordAuth(kind: dakBearer, token: token)

proc newDiscordClient*(botToken: string, options = DiscordClientOptions()): DiscordClient =
  var transport = options.transport
  var closeTransport = options.closeTransport
  let connectionLimit = if options.connectionLimit <= 0: 4 else: options.connectionLimit
  if transport == nil:
    let defaults = newDefaultTransport(connectionLimit)
    transport = defaults.transport
    if closeTransport == nil: closeTransport = defaults.close
  if closeTransport == nil: closeTransport = proc() = discard
  result = DiscordClient(
    botToken: botToken,
    apiBaseUrl: if options.apiBaseUrl.len == 0: "https://discord.com/api/v10" else: options.apiBaseUrl.strip(leading = false, trailing = true, chars = {'/'}),
    requestTimeoutMs: if options.requestTimeoutMs <= 0: 10_000 else: options.requestTimeoutMs,
    transport: transport,
    closeTransport: closeTransport,
    limiter: newRateLimiter(options.clock, options.sleep),
    active: @[]
  )

proc removeActive(client: DiscordClient, token: CancellationToken) =
  for index in countdown(client.active.high, 0):
    if client.active[index] == token:
      client.active.delete(index)
      break

proc close*(client: DiscordClient) =
  if client == nil or client.closed: return
  client.closed = true
  for token in client.active: token.cancel()
  client.closeTransport()

proc ensureOpen(client: DiscordClient) =
  if client == nil or client.closed:
    raise discordError(deClosed, "Discord client is closed")

proc requestRaw*(client: DiscordClient, httpMethod: DiscordHttpMethod, url: string, body = "",
                 hasBody = false, headers = initTable[string, string](),
                 auth = noAuth(), cancellation: CancellationToken = nil): Future[HttpResponse] {.async.} =
  client.ensureOpen()
  let token = if cancellation == nil: newCancellationToken() else: cancellation
  token.checkCancellation()
  var requestHeaders = headers
  case auth.kind
  of dakNone: discard
  of dakBot:
    requestHeaders["authorization"] = "Bot " & auth.token
  of dakBearer:
    requestHeaders["authorization"] = "Bearer " & auth.token
  let request = HttpRequest(
    httpMethod: httpMethod,
    url: url,
    headers: requestHeaders,
    body: body,
    hasBody: hasBody
  )
  client.active.add token
  let responseFuture = client.transport(request, token)
  try:
    let finished = await withTimeout(responseFuture, client.requestTimeoutMs)
    if not finished:
      token.cancel()
      raise discordError(deTimeout, "Discord request timed out")
    token.checkCancellation()
    result = await responseFuture
  except DiscordError:
    raise
  except CatchableError as error:
    if token.isCancelled:
      raise discordError(deCancelled, "Discord request cancelled")
    raise discordError(deTransport, "Discord transport failed: " & $error.name)
  finally:
    client.removeActive(token)

proc decodeJsonResponse(response: HttpResponse, retryAfterMs = 0): JsonNode =
  if response.status == 204: return nil
  if response.status < 200 or response.status >= 300:
    var details: JsonNode
    var discordCode = none(int64)
    try:
      details = parseJson(response.body)
      if details.kind == JObject and details.hasKey("code") and details["code"].kind == JInt:
        discordCode = some(details["code"].getBiggestInt)
    except CatchableError:
      details = nil
    let kind = if response.status == 429: deRateLimit else: deHttp
    raise discordError(kind, "Discord HTTP error (" & $response.status & ")",
                       response.status, discordCode, details, retryAfterMs)
  try:
    return parseJson(response.body)
  except CatchableError:
    raise discordError(deInvalidResponse, "Discord returned an invalid JSON response", response.status)

proc requestJson*(client: DiscordClient, httpMethod: DiscordHttpMethod, path: string,
                  body: JsonNode = nil, auth: DiscordAuth = DiscordAuth(kind: dakBot),
                  cancellation: CancellationToken = nil): Future[JsonNode] {.async.} =
  client.ensureOpen()
  let token = if cancellation == nil: newCancellationToken() else: cancellation
  token.checkCancellation()
  var headers = initTable[string, string]()
  var serializedBody = ""
  let hasBody = body != nil
  if hasBody:
    headers["content-type"] = "application/json"
    serializedBody = $body
  let authToken = if auth.kind == dakBot and auth.token.len == 0: botAuth(client.botToken) else: auth
  let url = client.apiBaseUrl & (if path.startsWith("/"): path else: "/" & path)
  client.active.add token
  var attempts429 = 0
  try:
    while true:
      let lease = await client.limiter.acquire(httpMethod, path, token)
      try:
        let response = await client.requestRaw(httpMethod, url, serializedBody, hasBody, headers, authToken, token)
        let retryAfterMs = client.limiter.observe(lease, response)
        if response.status == 429 and attempts429 < 2:
          inc attempts429
          continue
        return decodeJsonResponse(response, retryAfterMs)
      finally:
        client.limiter.release(lease)
  finally:
    client.removeActive(token)

proc isClosed*(client: DiscordClient): bool = client == nil or client.closed
