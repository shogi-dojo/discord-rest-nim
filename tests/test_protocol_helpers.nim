import std/[asyncdispatch, json, options, os, osproc, strutils, tables, unittest, uri]
import discordrest

proc response(status: int, body: string): HttpResponse =
  HttpResponse(status: status, body: body, headers: initTable[string, string]())

proc decodeForm(body: string): Table[string, string] =
  result = initTable[string, string]()
  for field in body.split('&'):
    let parts = field.split('=', maxsplit = 1)
    if parts.len == 2: result[decodeUrl(parts[0])] = decodeUrl(parts[1])

suite "Discord endpoint helpers":
  test "create message, create DM, and then send into the returned channel":
    var requests: seq[HttpRequest] = @[]
    let client = newDiscordClient("dummy", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        requests.add request
        if request.url.endsWith("/users/@me/channels"):
          return response(200, """{"id":"dm-channel-777","future_field":true}""")
        return response(200, """{"id":"message-888","content":"sent"}""")
    ))
    let dm = waitFor client.createDirectMessageChannel("user-555")
    let sent = waitFor client.createMessage(dm["id"].getStr, %*{"content": "hello"})
    check requests.len == 2
    check requests[0].httpMethod == dhmPost
    check requests[0].url.endsWith("/users/@me/channels")
    check parseJson(requests[0].body) == %*{"recipient_id": "user-555"}
    check requests[1].url.endsWith("/channels/dm-channel-777/messages")
    check sent["id"].getStr == "message-888"
    client.close()

  test "message payload remains caller-owned and pin accepts empty 204":
    var requests: seq[HttpRequest] = @[]
    let client = newDiscordClient("dummy", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        requests.add request
        if request.httpMethod == dhmPut: return response(204, "")
        return response(200, "{}")
    ))
    let payload = %*{
      "content": "@everyone",
      "allowed_mentions": {"parse": []},
      "flags": 4,
      "embeds": [{"url": "https://example.test/gallery", "image": {"url": "https://example.test/a.png"}}],
      "poll": {"question": {"text": "Tea?"}, "answers": [{"poll_media": {"text": "Yes"}}],
               "allow_multiselect": false, "duration": 24}
    }
    discard waitFor client.createMessage("channel-1", payload)
    let pinResult = waitFor client.pinMessage("channel-1", "message-2")
    check pinResult == nil
    check requests[0].httpMethod == dhmPost
    check parseJson(requests[0].body) == payload
    check requests[1].httpMethod == dhmPut
    check requests[1].url.endsWith("/channels/channel-1/messages/pins/message-2")
    check requests[1].hasBody == false
    client.close()

  test "application command list and replacement preserve strings and payload shape":
    var requests: seq[HttpRequest] = @[]
    let client = newDiscordClient("dummy", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        requests.add request
        if request.httpMethod == dhmGet: return response(200, "[]")
        return response(200, "[]")
    ))
    discard waitFor client.listGlobalApplicationCommands("application-snowflake")
    let commands = %*[
      {"name": "launch", "type": 4, "integration_types": [0], "contexts": [0]},
      {"name": "help", "description": "Show help"}
    ]
    discard waitFor client.replaceGlobalApplicationCommands("application-snowflake", commands)
    check requests[0].httpMethod == dhmGet
    check requests[0].url.endsWith("/applications/application-snowflake/commands")
    check requests[1].httpMethod == dhmPut
    check parseJson(requests[1].body) == commands
    client.close()

suite "Discord OAuth helpers":
  test "browser exchange uses form encoding and redirect URI; Activity exchange omits it":
    var requests: seq[HttpRequest] = @[]
    let client = newDiscordClient("must-not-be-used", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        requests.add request
        return response(200, """{"access_token":"provider-token","token_type":"Bearer","scope":"identify"}""")
    ))
    discard waitFor client.exchangeOAuthCode("client + id", "secret&value", "code/with spaces",
                                             some("https://example.test/callback?a=1&b=2"))
    discard waitFor client.exchangeOAuthCode("id", "secret", "activity-code")
    check requests.len == 2
    for request in requests:
      check request.httpMethod == dhmPost
      check request.url == DiscordOAuthTokenUrl
      check request.headers["content-type"] == "application/x-www-form-urlencoded"
      check "authorization" notin request.headers
    let browserForm = decodeForm(requests[0].body)
    check browserForm["client_id"] == "client + id"
    check browserForm["client_secret"] == "secret&value"
    check browserForm["grant_type"] == "authorization_code"
    check browserForm["code"] == "code/with spaces"
    check browserForm["redirect_uri"] == "https://example.test/callback?a=1&b=2"
    check "redirect_uri" notin decodeForm(requests[1].body)
    client.close()

  test "current user request uses Bearer auth and retains snowflake as a string":
    var captured: HttpRequest
    let client = newDiscordClient("bot-secret", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        captured = request
        return response(200, """{"id":"9007199254740993123","username":"player"}""")
    ))
    let user = waitFor client.getCurrentUser("access-token")
    check captured.httpMethod == dhmGet
    check captured.url.endsWith("/users/@me")
    check captured.headers["authorization"] == "Bearer access-token"
    check user["id"].getStr == "9007199254740993123"
    client.close()

  test "OAuth errors do not put submitted credentials in the message":
    let client = newDiscordClient("unused", DiscordClientOptions(
      transport: proc(request: HttpRequest, cancellation: CancellationToken): Future[HttpResponse] {.async.} =
        return response(400, """{"error":"invalid_grant"}""")
    ))
    var caught: ref DiscordError
    try:
      discard waitFor client.exchangeOAuthCode("secret-client-id", "secret-client-value", "secret-code")
    except DiscordError as error:
      caught = error
    check caught != nil and caught.status == 400
    check "secret-client-id" notin caught.msg
    check "secret-client-value" notin caught.msg
    check "secret-code" notin caught.msg
    client.close()

suite "Discord interactions":
  test "Ed25519 verifies exact timestamp plus raw JSON bytes including whitespace and Unicode":
    let root = getTempDir() / ("discordrest-signature-" & $getCurrentProcessId())
    createDir(root)
    let privatePath = root / "private.pem"
    let publicPath = root / "public.der"
    let messagePath = root / "message.bin"
    let signaturePath = root / "signature.bin"
    let openssl =
      if fileExists("/opt/homebrew/opt/openssl@3/bin/openssl"):
        "/opt/homebrew/opt/openssl@3/bin/openssl"
      elif fileExists("/usr/local/opt/openssl@3/bin/openssl"):
        "/usr/local/opt/openssl@3/bin/openssl"
      else:
        "openssl"
    let timestamp = "1730000000"
    let body = "{\n  \"content\": \"mahjong 🀄\",\n  \"ok\": true\n}\n"
    writeFile(messagePath, timestamp & body)
    let generate = execCmdEx(quoteShell(openssl) & " genpkey -algorithm ED25519 -out " & quoteShell(privatePath))
    if generate.exitCode != 0: raise newException(IOError, generate.output)
    let publicDer = execCmdEx(quoteShell(openssl) & " pkey -in " & quoteShell(privatePath) &
                              " -pubout -outform DER -out " & quoteShell(publicPath))
    if publicDer.exitCode != 0: raise newException(IOError, publicDer.output)
    let signing = execCmdEx(quoteShell(openssl) & " pkeyutl -sign -rawin -inkey " & quoteShell(privatePath) &
                            " -in " & quoteShell(messagePath) & " -out " & quoteShell(signaturePath))
    if signing.exitCode != 0: raise newException(IOError, signing.output)
    let der = readFile(publicPath)
    let signature = readFile(signaturePath)
    check der.len >= 32
    let publicHex = toHex(der[der.len - 32 .. ^1])
    let signatureHex = toHex(signature)
    check verifyInteractionSignature(publicHex, signatureHex, timestamp, body)
    check not verifyInteractionSignature(publicHex, signatureHex, timestamp, body.replace("  ", " "))
    check not verifyInteractionSignature(publicHex, signatureHex, timestamp & "0", body)
    check not verifyInteractionSignature(publicHex, signatureHex, "", body)
    check not verifyInteractionSignature("xyz", signatureHex, timestamp, body)
    check not verifyInteractionSignature(publicHex, "0", timestamp, body)
    removeDir(root)

  test "interaction reply builders provide PONG, ephemeral and autocomplete shapes":
    check interactionPong() == %*{"type": 1}
    check interactionMessageResponse("Not linked", ephemeral = true) == %*{
      "type": 4,
      "data": {"content": "Not linked", "flags": 64, "allowed_mentions": {"parse": []}}
    }
    check interactionMessageResponse("Public") == %*{
      "type": 4, "data": {"content": "Public", "allowed_mentions": {"parse": []}}
    }
    let choices = newJArray()
    choices.add %*{"name": "Club", "value": "1"}
    check interactionAutocompleteResponse(choices) == %*{"type": 8, "data": {"choices": choices}}
