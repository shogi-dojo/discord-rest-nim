## Small Discord endpoint helpers. Application policy and payload construction stay with callers.

import std/[asyncdispatch, json]
import ./[client, types]

proc createMessage*(client: DiscordClient, channelId: string,
                    payload: JsonNode): Future[JsonNode] {.async.} =
  return await client.requestJson(dhmPost, "/channels/" & channelId & "/messages", payload)

proc createDirectMessageChannel*(client: DiscordClient,
                                 userId: string): Future[JsonNode] {.async.} =
  return await client.requestJson(dhmPost, "/users/@me/channels", %*{"recipient_id": userId})

proc pinMessage*(client: DiscordClient, channelId, messageId: string): Future[JsonNode] {.async.} =
  return await client.requestJson(dhmPut,
    "/channels/" & channelId & "/messages/pins/" & messageId)

proc listGlobalApplicationCommands*(client: DiscordClient,
                                   applicationId: string): Future[JsonNode] {.async.} =
  return await client.requestJson(dhmGet, "/applications/" & applicationId & "/commands")

proc replaceGlobalApplicationCommands*(client: DiscordClient, applicationId: string,
                                       commands: JsonNode): Future[JsonNode] {.async.} =
  return await client.requestJson(dhmPut, "/applications/" & applicationId & "/commands", commands)
