import std/[json, options]

type
  DiscordErrorKind* = enum
    deHttp,
    deRateLimit,
    deTimeout,
    deCancelled,
    deTransport,
    deInvalidResponse,
    deQueueFull,
    deClosed

  DiscordError* = object of CatchableError
    kind*: DiscordErrorKind
    status*: int
    discordCode*: Option[int64]
    details*: JsonNode
    retryAfterMs*: int

proc discordError*(kind: DiscordErrorKind, message: string, status = 0,
                   discordCode = none(int64), details: JsonNode = nil,
                   retryAfterMs = 0): ref DiscordError =
  new(result)
  result.msg = message
  result.kind = kind
  result.status = status
  result.discordCode = discordCode
  result.details = details
  result.retryAfterMs = retryAfterMs
