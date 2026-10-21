## Server-independent Discord interaction signature and response helpers.

import std/[dynlib, json, os, strutils]

type
  EvpPkey = pointer
  EvpMdContext = pointer
  NewRawPublicKeyEx = proc(libctx: pointer, keytype, propq: cstring,
                           key: ptr uint8, keylen: csize_t): EvpPkey {.cdecl.}
  PkeyFree = proc(key: EvpPkey) {.cdecl.}
  MdCtxNew = proc(): EvpMdContext {.cdecl.}
  MdCtxFree = proc(context: EvpMdContext) {.cdecl.}
  DigestVerifyInit = proc(context: EvpMdContext, pctx: ptr pointer, digest: pointer,
                          engine: pointer, key: EvpPkey): cint {.cdecl.}
  DigestVerify = proc(context: EvpMdContext, signature: ptr uint8, signatureLen: csize_t,
                      message: ptr uint8, messageLen: csize_t): cint {.cdecl.}

proc openCrypto3(): LibHandle =
  when defined(macosx):
    let custom = getEnv("OPENSSL_DIR")
    if custom.len > 0: result = loadLib(custom / "lib" / "libcrypto.3.dylib")
    if result == nil: result = loadLib("/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib")
    if result == nil: result = loadLib("/usr/local/opt/openssl@3/lib/libcrypto.3.dylib")
    if result == nil: result = loadLib("libcrypto.3.dylib")
  elif defined(windows):
    result = loadLib("libcrypto-3-x64.dll")
  else:
    result = loadLib("libcrypto.so.3")

proc symbol[T](library: LibHandle, name: string): T =
  cast[T](symAddr(library, name))

proc decodeHex(text: string): seq[byte] =
  if text.len mod 2 != 0: return @[]
  result = newSeq[byte](text.len div 2)
  for index in 0 ..< result.len:
    let highNibble = parseHexInt(text[index * 2 .. index * 2])
    let lowNibble = parseHexInt(text[index * 2 + 1 .. index * 2 + 1])
    result[index] = byte((highNibble shl 4) or lowNibble)

proc isHex(text: string): bool =
  for ch in text:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}: return false
  true

proc verifyInteractionSignature*(publicKeyHex, signatureHex, timestamp,
                                 rawBody: string): bool =
  ## Verify timestamp || rawBody exactly as received, before JSON parsing or normalization.
  if publicKeyHex.len != 64 or signatureHex.len != 128 or timestamp.len == 0 or
     not publicKeyHex.isHex or not signatureHex.isHex:
    return false
  let publicKey = decodeHex(publicKeyHex)
  let signature = decodeHex(signatureHex)
  if publicKey.len != 32 or signature.len != 64: return false
  var signedPayload = timestamp
  signedPayload.add rawBody
  let library = openCrypto3()
  if library == nil: return false
  var key: EvpPkey
  var context: EvpMdContext
  try:
    let createKey = symbol[NewRawPublicKeyEx](library, "EVP_PKEY_new_raw_public_key_ex")
    let freeKey = symbol[PkeyFree](library, "EVP_PKEY_free")
    let createContext = symbol[MdCtxNew](library, "EVP_MD_CTX_new")
    let freeContext = symbol[MdCtxFree](library, "EVP_MD_CTX_free")
    let verifyInit = symbol[DigestVerifyInit](library, "EVP_DigestVerifyInit")
    let verify = symbol[DigestVerify](library, "EVP_DigestVerify")
    if createKey == nil or freeKey == nil or createContext == nil or freeContext == nil or
       verifyInit == nil or verify == nil:
      return false
    key = createKey(nil, "ED25519", nil,
      cast[ptr uint8](unsafeAddr publicKey[0]), csize_t(publicKey.len))
    if key == nil: return false
    context = createContext()
    if context == nil: return false
    if verifyInit(context, nil, nil, nil, key) != 1: return false
    return verify(context, cast[ptr uint8](unsafeAddr signature[0]),
      csize_t(signature.len), cast[ptr uint8](unsafeAddr signedPayload[0]),
      csize_t(signedPayload.len)) == 1
  except CatchableError:
    return false
  finally:
    let freeContext = symbol[MdCtxFree](library, "EVP_MD_CTX_free")
    let freeKey = symbol[PkeyFree](library, "EVP_PKEY_free")
    if context != nil and freeContext != nil: freeContext(context)
    if key != nil and freeKey != nil: freeKey(key)
    unloadLib(library)

proc interactionPong*(): JsonNode = %*{"type": 1}

proc interactionMessageResponse*(content: string, ephemeral = false,
                                 allowedMentions = %*{"parse": []}): JsonNode =
  result = %*{"type": 4, "data": {"content": content, "allowed_mentions": allowedMentions}}
  if ephemeral: result["data"]["flags"] = %64

proc interactionAutocompleteResponse*(choices: JsonNode): JsonNode =
  %*{"type": 8, "data": {"choices": choices}}
