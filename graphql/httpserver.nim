# nim-graphql
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[strutils, json, tables],
  chronicles, chronos, chronos/apps/http/[httpserver, shttpserver],
  ./graphql, ./api, ./builtin/json_respstream,
  ./server_common, ./graphiql, zlib/gzip

export shttpserver

type
  ContentType = enum
    ctGraphQl
    ctJson

  GraphqlHttpServerState* {.pure.} = enum
    Closed
    Stopped
    Running

  GraphqlHttpResult*[T] = Result[T, string]

  GraphqlHttpServer* = object of RootObj
    server*: HttpServerRef
    graphql*: GraphqlRef
    savePoint: NameCounter
    defRespHeader: HttpTable

  GraphqlHttpServerRef* = ref GraphqlHttpServer

template exec(executor: untyped) =
  let res = callValidator(ctx, executor)
  if res.isErr:
    return (Http400, jsonErrorResp(res.error))

proc execRequest(server: GraphqlHttpServerRef, ro: RequestObject): (HttpCode, string) {.gcsafe.} =
  let ctx = server.graphql

  # clean up previous garbage before new execution
  ctx.purgeQueries(includeVariables = true)
  ctx.purgeNames(server.savePoint)

  ctx.addVariables(ro.variables)

  let query = toString(ro.query)
  exec parseQuery(query)
  let resp = JsonRespStream.new()
  let opName = if ro.operationName.kind == nkNull:
                 ""
               else:
                 toString(ro.operationName)
  let res = ctx.executeRequest(respStream(resp), opName)
  if res.isErr:
    (Http400, jsonErrorResp(res.error, resp.getBytes()))
  else:
    (Http200, jsonOkResp(resp.getBytes()))

proc getContentTypes(request: HttpRequestRef): set[ContentType] =
  let conType = request.headers.getList("content-type")
  for n in conType:
    if n == "application/graphql":
      result.incl ctGraphql
    elif n == "application/json":
      result.incl ctJson

proc sendResponse(res: string, status: HttpCode,
                  acceptEncoding: set[ContentEncodingFlags],
                  request: HttpRequestRef): Future[HttpResponseRef] {.gcsafe, async.} =

  const chunkSize = 1024 * 4

  if res.len <= chunkSize:
    # don't split it into chunks if it's a small content
    var header = HttpTable.init([("Content-Type", "application/json")])
    if ContentEncodingFlags.Gzip in acceptEncoding:
      header.add("Content-Encoding", "gzip")
    return await request.respond(status, res, header)

  # chunked transfer
  let response = request.getResponse()
  response.status = status
  response.addHeader("Content-Type", "application/json")
  if ContentEncodingFlags.Gzip in acceptEncoding:
    response.addHeader("Content-Encoding", "gzip")

  await response.prepare()

  let maxLen = res.len
  var len = res.len
  while len > chunkSize:
    await response.sendChunk(res[maxLen - len].unsafeAddr, chunkSize)
    len -= chunkSize

  if len > 0:
    await response.sendChunk(res[maxLen - len].unsafeAddr, len)
  await response.finish()
  return response

proc processGraphqlRequest(server: GraphqlHttpServerRef, request: HttpRequestRef): Future[HttpResponseRef] {.gcsafe, async.} =
  let ctx = server.graphql
  let contentTypes = request.getContentTypes()

  var ro = RequestObject.init()
  for k, v in request.query.stringItems():
    let res = ctx.decodeRequest(ro, k, v)
    if res.isErr:
      let error = jsonErrorResp(res.error)
      return await request.respond(Http400, error, server.defRespHeader)

  if request.hasBody:
    let body = await request.getBody()
    if ctGraphql in contentTypes:
      ro.query = toQueryNode(cast[string](body))
    else:
      let res = ctx.parseLiteral(body)
      if res.isErr:
        let error = jsonErrorResp(res.error)
        return await request.respond(Http400, error, server.defRespHeader)
      requestNodeToObject(res.get(), ro)

  let (status, res) = server.execRequest(ro)

  if request.version == HttpVersion10:
    return await request.respond(status, res, server.defRespHeader)

  let acceptEncoding =
    block:
      let res = getContentEncoding(
                                   request.headers.getList("accept-encoding"))
      if res.isErr():
        let error = jsonErrorResp("Incorrect Accept-Encoding value")
        return await request.respond(Http400, error, server.defRespHeader)
      else:
        res.get()

  if ContentEncodingFlags.Gzip in acceptEncoding:
    let res = string.gzip(res)
    if res.isErr:
      let error = jsonErrorResp("compression error")
      return await request.respond(Http400, error, server.defRespHeader)
    else:
      return await sendResponse(res.get(), status, acceptEncoding, request)

  return await sendResponse(res, status, acceptEncoding, request)

proc processUIRequest(server: GraphqlHttpServerRef, request: HttpRequestRef): Future[HttpResponseRef] {.gcsafe, async.} =
  if request.meth != MethodGet:
    let error = jsonErrorResp("path '$1' not found" % [request.uri.path])
    let header = HttpTable.init([
      ("Content-Type", "application/json; charset=utf-8"),
      ("X-Content-Type-Options", "nosniff")
    ])
    return await request.respond(Http405, error, header)

  let header = HttpTable.init([("Content-Type", "text/html")])
  return await request.respond(Http200, graphiql_html, header)

proc routingRequest(server: GraphqlHttpServerRef, r: RequestFence): Future[HttpResponseRef] {.gcsafe, async.} =
  if r.isErr():
    return dumbResponse()

  let request = r.get()
  case request.uri.path
  of "/graphql":
    return await processGraphqlRequest(server, request)
  of "/graphql/ui":
    return await processUIRequest(server, request)
  else:
    let error = jsonErrorResp("path '$1' not found" % [request.uri.path])
    return await request.respond(Http404, error, server.defRespHeader)

proc new*(t: typedesc[GraphqlHttpServerRef],
          graphql: GraphqlRef,
          address: TransportAddress,
          serverIdent: string = "",
          serverFlags = {HttpServerFlags.NotifyDisconnect},
          socketFlags: set[ServerFlags] = {ReuseAddr},
          serverUri = Uri(),
          maxConnections: int = -1,
          backlogSize: int = 100,
          bufferSize: int = 4096,
          httpHeadersTimeout = 10.seconds,
          maxHeadersSize: int = 8192,
          maxRequestBodySize: int = 1_048_576): GraphqlHttpResult[GraphqlHttpServerRef] =
  var server = GraphqlHttpServerRef(
    graphql: graphql,
    savePoint: graphql.getNameCounter,
    defRespHeader: HttpTable.init([("Content-Type", "application/json")])
  )

  proc processCallback(rf: RequestFence): Future[HttpResponseRef] =
    routingRequest(server, rf)

  let sres = HttpServerRef.new(address, processCallback, serverFlags,
                               socketFlags, serverUri, serverIdent,
                               maxConnections, bufferSize, backlogSize,
                               httpHeadersTimeout, maxHeadersSize,
                               maxRequestBodySize)
  if sres.isOk():
    server.server = sres.get()
    ok(server)
  else:
    err("Could not create HTTP server instance: " & sres.error())

proc new*(t: typedesc[GraphqlHttpServerRef],
          graphql: GraphqlRef,
          address: TransportAddress,
          tlsPrivateKey: TLSPrivateKey,
          tlsCertificate: TLSCertificate,
          secureFlags: set[TLSFlags] = {},
          serverIdent: string = "",
          serverFlags = {HttpServerFlags.NotifyDisconnect},
          socketFlags: set[ServerFlags] = {ReuseAddr},
          serverUri = Uri(),
          maxConnections: int = -1,
          backlogSize: int = 100,
          bufferSize: int = 4096,
          httpHeadersTimeout = 10.seconds,
          maxHeadersSize: int = 8192,
          maxRequestBodySize: int = 1_048_576): GraphqlHttpResult[GraphqlHttpServerRef] =
  var server = GraphqlHttpServerRef(
    graphql: graphql,
    savePoint: graphql.getNameCounter,
    defRespHeader: HttpTable.init([("Content-Type", "application/json")])
  )

  proc processCallback(rf: RequestFence): Future[HttpResponseRef] =
    routingRequest(server, rf)

  let sres = SecureHttpServerRef.new(address, processCallback,
                               tlsPrivateKey, tlsCertificate, serverFlags,
                               socketFlags, serverUri, serverIdent, secureFlags,
                               maxConnections, bufferSize, backlogSize,
                               httpHeadersTimeout, maxHeadersSize,
                               maxRequestBodySize)
  if sres.isOk():
    server.server = sres.get()
    ok(server)
  else:
    err("Could not create HTTP server instance: " & sres.error())

proc state*(rs: GraphqlHttpServerRef): GraphqlHttpServerState {.raises: [Defect].} =
  ## Returns current GraphQL server's state.
  case rs.server.state
  of HttpServerState.ServerClosed:
    GraphqlHttpServerState.Closed
  of HttpServerState.ServerStopped:
    GraphqlHttpServerState.Stopped
  of HttpServerState.ServerRunning:
    GraphqlHttpServerState.Running

proc start*(rs: GraphqlHttpServerRef) =
  ## Starts GraphQL server.
  rs.server.start()
  let scheme = rs.server.baseUri.scheme
  notice "GraphQL service started", at = scheme & "://" & $rs.server.address & "/graphql"
  notice "GraphiQL UI ready", at = scheme & "://" & $rs.server.address & "/graphql/ui"

proc stop*(rs: GraphqlHttpServerRef) {.async.} =
  ## Stop GraphQL server from accepting new connections.
  await rs.server.stop()
  notice "GraphQL service stopped", address = $rs.server.address

proc drop*(rs: GraphqlHttpServerRef): Future[void] =
  ## Drop all pending connections.
  rs.server.drop()

proc closeWait*(rs: GraphqlHttpServerRef) {.async.} =
  ## Stop GraphQL server and drop all the pending connections.
  await rs.server.closeWait()
  notice "GraphQL service closed", address = $rs.server.address

proc join*(rs: GraphqlHttpServerRef): Future[void] =
  ## Wait until GraphQL server will not be closed.
  rs.server.join()
