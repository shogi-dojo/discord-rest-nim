import std/[asyncdispatch, json, options, strutils, tables, unittest]
import discordrest

proc response(status: int, body: string,
              headers = initTable[string, string]()): HttpResponse =
  HttpResponse(status: status, headers: headers, body: body)

suite "Discord HTTP client":
  test "uses explicit methods, bot auth and JSON while preserving unknown response fields":
    var requests: seq[HttpRequest] = @[]
    let client = newDiscordClient("dummy-bot-token", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        requests.add request
        return response(200, """{"id":"9007199254740993123","future":{"value":true}}""")
    ))
    let result = waitFor client.requestJson(dhmPost, "/channels/12/messages", %*{"content": "hello"})
    check result["id"].getStr == "9007199254740993123"
    check result["future"]["value"].getBool
    check requests.len == 1
    check requests[0].httpMethod == dhmPost
    check requests[0].url == "https://discord.com/api/v10/channels/12/messages"
    check requests[0].headers["authorization"] == "Bot dummy-bot-token"
    check requests[0].headers["content-type"] == "application/json"
    check parseJson(requests[0].body) == %*{"content": "hello"}
    client.close()

  test "supports Bearer user auth and accepts 204 without trying to decode a body":
    var requests: seq[HttpRequest] = @[]
    let client = newDiscordClient("unused-bot-token", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        requests.add request
        return response(204, "")
    ))
    let result = waitFor client.requestJson(dhmPut, "/pins/123", nil, bearerAuth("user-access-token"))
    check result == nil
    check requests[0].httpMethod == dhmPut
    check requests[0].headers["authorization"] == "Bearer user-access-token"
    check "content-type" notin requests[0].headers
    client.close()

  test "keeps structured Discord error status, code and details without echoing credentials":
    let client = newDiscordClient("private-token-sentinel", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        return response(403, """{"code": 50013, "message": "Missing Permissions", "errors": {"field": "reason"}}""")
    ))
    var failure: ref DiscordError
    try:
      discard waitFor client.requestJson(dhmPost, "/channels/12/messages", %*{"content": "private-body"})
    except DiscordError as error:
      failure = error
    check failure != nil
    check failure.kind == deHttp
    check failure.status == 403
    check failure.discordCode == some(50013'i64)
    check failure.details["errors"]["field"].getStr == "reason"
    check "private-token-sentinel" notin failure.msg
    check "private-body" notin failure.msg
    client.close()

  test "classifies malformed successful JSON and closes the transport once":
    var closes = 0
    let client = newDiscordClient("token", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        return response(200, "not-json")
      ,
      closeTransport: proc() = inc closes
    ))
    var failure: ref DiscordError
    try:
      discard waitFor client.requestJson(dhmGet, "/users/@me")
    except DiscordError as error:
      failure = error
    check failure != nil and failure.kind == deInvalidResponse
    client.close()
    client.close()
    check closes == 1
    try:
      discard waitFor client.requestJson(dhmGet, "/users/@me")
    except DiscordError as error:
      check error.kind == deClosed

  test "times out one network attempt and does not retry an ambiguous POST":
    var attempts = 0
    let client = newDiscordClient("token", DiscordClientOptions(
      requestTimeoutMs: 5,
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc attempts
        await sleepAsync(100)
        return response(200, "{}")
    ))
    var failure: ref DiscordError
    try:
      discard waitFor client.requestJson(dhmPost, "/channels/12/messages", %*{"content": "once"})
    except DiscordError as error:
      failure = error
    check failure != nil and failure.kind == deTimeout
    check attempts == 1
    client.close()

  test "rejects a caller-cancelled request before transport submission":
    var attempts = 0
    let token = newCancellationToken()
    let client = newDiscordClient("token", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        inc attempts
        return response(200, "{}")
    ))
    token.cancel()
    var failure: ref DiscordError
    try:
      discard waitFor client.requestJson(dhmGet, "/users/@me", cancellation = token)
    except DiscordError as error:
      failure = error
    check failure != nil and failure.kind == deCancelled
    check attempts == 0
    client.close()
