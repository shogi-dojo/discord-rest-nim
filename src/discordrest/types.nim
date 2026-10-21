type
  DiscordHttpMethod* = enum
    dhmGet = "GET"
    dhmPost = "POST"
    dhmPut = "PUT"
    dhmPatch = "PATCH"
    dhmDelete = "DELETE"

proc httpMethodName*(httpMethod: DiscordHttpMethod): string = $httpMethod
