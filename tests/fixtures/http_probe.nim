import std/[asyncdispatch, json, os, strutils]
import discordrest

proc main() {.async.} =
  let mode = paramStr(1)
  let port = paramStr(2)
  let isTls = mode == "tls"
  let base = (if isTls: "https" else: "http") & "://127.0.0.1:" & port & "/api/v10"
  let client = newDiscordClient("fixture-bot-token", DiscordClientOptions(
    apiBaseUrl: base,
    requestTimeoutMs: if mode == "timeout": 30 else: 2_000,
    connectionLimit: 4
  ))
  defer: client.close()

  case mode
  of "http":
    let first = await client.requestJson(dhmGet, "/probe/reuse")
    let sent = await client.requestJson(dhmPost, "/channels/channel-1/messages",
      %*{"content": "hello", "allowed_mentions": {"parse": []}})
    let pinned = await client.requestJson(dhmPut, "/channels/channel-1/messages/pins/message-1")
    echo $(%*{"first": first, "sent": sent, "pinned": if pinned == nil: newJNull() else: pinned})
  of "pool":
    var futures: seq[Future[JsonNode]] = @[]
    for index in 0 ..< 8:
      futures.add client.requestJson(dhmGet, "/probe/concurrent/route-" & $index)
    var ids = newJArray()
    for future in futures: ids.add await future
    echo $(%*{"ids": ids})
  of "timeout":
    try:
      discard await client.requestJson(dhmPost, "/channels/accepted/messages", %*{"content": "once"})
      quit("accepted POST unexpectedly completed", 2)
    except DiscordError as error:
      if error.kind != deTimeout: quit("expected timeout, got " & $error.kind, 2)
      echo "timed out"
  of "disconnect":
    try:
      discard await client.requestJson(dhmGet, "/probe/disconnect")
      quit("disconnected request unexpectedly completed", 2)
    except DiscordError as error:
      if error.kind != deTransport: quit("expected transport failure, got " & $error.kind, 2)
      echo "disconnected"
  of "tls":
    try:
      discard await client.requestJson(dhmGet, "/probe/tls")
      quit("untrusted TLS certificate unexpectedly succeeded", 2)
    except DiscordError as error:
      if error.kind != deTransport: quit("expected TLS transport failure, got " & $error.kind, 2)
      echo "tls rejected"
  else:
    quit("unknown probe mode: " & mode, 2)

waitFor main()
