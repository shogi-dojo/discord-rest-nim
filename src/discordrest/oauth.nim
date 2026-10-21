## Discord OAuth code exchange and current-user lookup.
## The versionless token URL and form encoding match Discord's OAuth endpoint contract.

import std/[asyncdispatch, json, options, uri, tables]
import ./[client, errors, transport, types]

const DiscordOAuthTokenUrl* = "https://discord.com/api/oauth2/token"

proc appendFormField(output: var string, key, value: string) =
  if output.len > 0: output.add '&'
  output.add encodeUrl(key)
  output.add '='
  output.add encodeUrl(value)

proc oauthError(response: HttpResponse): ref DiscordError =
  var details: JsonNode
  var code = none(int64)
  try:
    details = parseJson(response.body)
    if details.kind == JObject and details.hasKey("code") and details["code"].kind == JInt:
      code = some(details["code"].getBiggestInt)
  except CatchableError:
    details = nil
  discordError(if response.status == 429: deRateLimit else: deHttp,
    "Discord OAuth HTTP error (" & $response.status & ")", response.status, code, details)

proc exchangeOAuthCode*(client: DiscordClient, clientId, clientSecret, code: string,
                        redirectUri: Option[string] = none(string),
                        cancellation: CancellationToken = nil): Future[JsonNode] {.async.} =
  var form = ""
  appendFormField(form, "client_id", clientId)
  appendFormField(form, "client_secret", clientSecret)
  appendFormField(form, "grant_type", "authorization_code")
  appendFormField(form, "code", code)
  if redirectUri.isSome: appendFormField(form, "redirect_uri", redirectUri.get)
  var headers = initTable[string, string]()
  headers["content-type"] = "application/x-www-form-urlencoded"
  let response = await client.requestRaw(dhmPost, DiscordOAuthTokenUrl, form, true,
    headers, noAuth(), cancellation)
  if response.status < 200 or response.status >= 300:
    raise oauthError(response)
  try:
    return parseJson(response.body)
  except CatchableError:
    raise discordError(deInvalidResponse, "Discord OAuth returned an invalid JSON response", response.status)

proc getCurrentUser*(client: DiscordClient, accessToken: string,
                     cancellation: CancellationToken = nil): Future[JsonNode] {.async.} =
  return await client.requestJson(dhmGet, "/users/@me", auth = bearerAuth(accessToken),
                                  cancellation = cancellation)
