import Init

/-! Deliberately small HTTP/1.1 GET benchmark protocol, not a production HTTP
implementation. Both Lean transports use this exact parser and response code.
No request bodies, transfer coding, HTTP/1.0, TLS or chunked responses. -/
namespace Bench

structure Request where
  target : String
  close : Bool

def response (body : ByteArray) (close := false) (status := "200 OK") : ByteArray :=
  s!"HTTP/1.1 {status}\r\nContent-Length: {body.size}\r\nContent-Type: text/plain\r\nConnection: {if close then "close" else "keep-alive"}\r\n\r\n".toUTF8 ++ body

def payload : ByteArray := (String.ofList (List.replicate 1024 'x')).toUTF8

/-- HTTP optional whitespace is SP / HTAB. Byte-based for Lean 4.26/4.35 compatibility. -/
private def trimOWS (s : String) : String := Id.run do
  let bytes := s.toUTF8
  let mut first := 0
  let mut last := bytes.size
  while first < last && (bytes[first]! == 32 || bytes[first]! == 9) do first := first + 1
  while first < last && (bytes[last - 1]! == 32 || bytes[last - 1]! == 9) do last := last - 1
  return String.fromUTF8! (bytes.extract first last)

private def parseHead (bytes : ByteArray) : Except String Request := do
  let some text := String.fromUTF8? bytes | throw "400 Bad Request"
  let lines := text.splitOn "\r\n"
  let parts := (lines.head!).splitOn " "
  if parts.length != 3 || parts[2]! != "HTTP/1.1" then throw "400 Bad Request"
  if parts[0]! != "GET" then throw "405 Method Not Allowed"
  let target := parts[1]!
  if !target.startsWith "/" then throw "400 Bad Request"
  let mut close := false
  let mut host := false
  let mut contentLength := false
  for line in lines.drop 1 do
    if line.isEmpty then continue
    let kv := line.splitOn ":"
    if kv.length < 2 then throw "400 Bad Request"
    let name := kv.head!
    if name.isEmpty || name != trimOWS name then throw "400 Bad Request"
    let value := (trimOWS (String.intercalate ":" (kv.drop 1))).toLower
    match name.toLower with
    | "host" =>
      if host || value.isEmpty then throw "400 Bad Request"
      host := true
    | "transfer-encoding" => throw "400 Bad Request"
    | "content-length" =>
      if contentLength || value != "0" then throw "400 Bad Request"
      contentLength := true
    | "connection" =>
      if (value.splitOn ",").any (fun option => trimOWS option == "close") then close := true
    | _ => pure ()
  if !host then throw "400 Bad Request"
  return { target, close }

structure Parser where
  pending : ByteArray := .empty
  scanned : Nat := 0

-- Scan only new bytes plus the three-byte overlap; never assume read boundaries
-- coincide with request boundaries. Limit every individual header to 16 KiB.
def feed (state : Parser) (chunk : ByteArray) : Parser × Array (Except String Request) := Id.run do
  let bytes := if state.pending.isEmpty then chunk else state.pending ++ chunk
  let mut start := 0
  let mut i := state.scanned
  let mut requests := #[]
  while i + 3 < bytes.size do
    if i - start >= 16384 then
      return ({}, requests.push (.error "431 Request Header Fields Too Large"))
    if bytes[i]! == 13 && bytes[i+1]! == 10 && bytes[i+2]! == 13 && bytes[i+3]! == 10 then
      let req := parseHead (bytes.extract start i)
      requests := requests.push req
      match req with
      | .error _ => return ({}, requests)
      | .ok req => if req.close then return ({}, requests)
      i := i + 4
      start := i
    else i := i + 1
  let pending := bytes.extract start bytes.size
  if pending.size > 16384 then
    return ({}, requests.push (.error "431 Request Header Fields Too Large"))
  return ({ pending, scanned := pending.size - 3 }, requests)

def chooseResponse (worker : UInt32) (prepared : ByteArray) (req : Request) : ByteArray :=
  if req.target == "/" then
    if req.close then response payload true else prepared
  else if req.target == "/worker" then response s!"{worker}".toUTF8 req.close
  else if req.target.startsWith "/echo/" then response req.target.toUTF8 req.close
  else response "Not found\n".toUTF8 req.close "404 Not Found"

end Bench
