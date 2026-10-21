import std/unittest
import discordrest

suite "discordrest package":
  test "HTTP methods are explicit and serialize by their protocol name":
    check httpMethodName(dhmGet) == "GET"
    check httpMethodName(dhmPost) == "POST"
    check httpMethodName(dhmPut) == "PUT"
