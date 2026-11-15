# stdgo Roadmap & Go Standard Library Gap Analysis

This document provides a comprehensive comparison between the Go standard library (Go 1.22+) and `stdgo`, tracking our implementation status, coverage metrics, architectural boundaries, and prioritized future roadmap.

---

## 1. Executive Summary & Coverage Metrics

`stdgo` aims to bring Go standard library ergonomics, native streaming abstractions (`stdgo.io.Reader` / `stdgo.io.Writer` aligned with Zig 0.17 `std.Io`), and high-utility packages to the Zig (0.17.0) ecosystem.

- **Core Practical / High-Utility Coverage**: **~75%**
  - Essential streaming I/O (`io`, `bytes`, `strings`), context trees (`context`), concurrency primitives (`sync.WaitGroup`, `sync.Once`, `sync.Mutex`, `sync.Pool`, `sync.errgroup`), structured logging (`log/slog`), HTTP client (`net/http`), multipart forms (`mime/multipart`), linear-time regex (`regexp`), compression (`gzip`, `zlib`, `flate`), subprocesses (`os/exec`), filesystem/env (`os`), IP/CIDR networking (`net`), and data-driven templating (`text/template`) are production-ready with comprehensive test suites.
- **Explicit Non-Goals Excluded**: ~20% (Go runtime internals, GC, compiler tools, standalone HTTP server).
- **Remaining Target Gap**: **~5%** (Symmetric/asymmetric cryptography extensions, `html/template`).

```
[========================== 75% Implemented ==========================>][== 5% Gap ==][== 20% Non-Goals ==]
```

---

## 2. Scope Boundaries & Explicit Non-Goals

Per `AGENTS.md`, certain Go packages are intentionally excluded from `stdgo`:

1. **HTTP Server (`net/http.Server`, `Handler`, `ServeMux`)**:
   - **Explicit Non-Goal**: A standalone, high-performance, multithreaded HTTP server is already fully implemented in [lighting](https://github.com/jiacai2050/lighting/). `stdgo.net.http` is **strictly focused on the HTTP client** (`Client`, `Transport`, `ConnPool`, `CookieJar`, `Request`, `Response`).
2. **Go Compiler & AST Toolchain**:
   - `go/ast`, `go/parser`, `go/token`, `go/types`, `go/printer`, `go/build`, `go/doc`.
3. **Go Runtime & Garbage Collector Internals**:
   - `runtime`, `runtime/debug`, `runtime/pprof`, `runtime/trace`, `runtime/metrics`, `runtime/cgo`.
4. **Platform-Specific System Call Duplication**:
   - `syscall` (fully handled by Zig's native `std.posix` and `std.os.windows`).

---

## 3. Current Implementation Status (Completed Modules)

| Go Package | `stdgo` Package | Status | Key Features |
| :--- | :--- | :--- | :--- |
| **`io`** | `stdgo.io` | **100%** | Native `std.Io.Reader`, `Writer`, `Closer`, `Seeker`, `LimitReader`, `TeeReader`, `copy`, `readFull`, `readAtLeast` |
| **`bytes`** | `stdgo.bytes` | **95%** | Sliding-window `Buffer`, slice `Reader`, `Split`, `Join`, `Fields`, `Compare`, `Contains`, `HasPrefix`, `HasSuffix` |
| **`strings`** | `stdgo.strings` | **95%** | High-performance `Builder`, string `Reader`, `Split`, `Join`, `Fields`, `Trim`, `TrimSpace`, `TrimPrefix`, `ReplaceAll`, `Repeat` |
| **`bufio`** | — | — | *Removed*: Superseded by native Zig 0.17 buffered `std.Io.Reader` & `std.Io.Writer` containers |
| **`encoding/binary`** | `stdgo.encoding.binary` | **100%** | `BigEndian`, `LittleEndian`, `NativeEndian`, Protobuf Leb128 `Uvarint` & ZigZag `Varint` |
| **`encoding/base64`** | `stdgo.encoding.base64` | **100%** | RFC 4648 standard, URL-safe, raw without padding; streaming & string encode/decode |
| **`encoding/hex`** | `stdgo.encoding.hex` | **100%** | Fast Hex encode/decode, canonical 16-byte `hex.Dump` table formatter |
| **`encoding/csv`** | `stdgo.encoding.csv` | **100%** | Strict RFC 4180 CSV reader/writer; quote escapes (`""`), multiline records, custom delimiters |
| **`context`** | `stdgo.context` | **90%** | `Background()`, `TODO()`, `WithCancel()`, `WithDeadline()`, `WithValue()`, `Canceled`, `DeadlineExceeded` |
| **`net/url`** | `stdgo.net.url` | **90%** | RFC 3986 URL parser, `QueryEscape` / `QueryUnescape`, `Values` multi-value query map |
| **`net/http` (Client)** | `stdgo.net.http` | **85%** | Ergonomic `Client`, `Get`, `Post`, `PostForm`, `Head`, `Put`, `Delete`, `Patch`; HTTP forward proxy, HTTPS CONNECT tunneling, environment proxy detection (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) & Basic Auth, `ConnPool` (Keep-Alive), `CookieJar`, `CheckRedirect` with cross-origin sanitization, streaming request body (`io.Reader` & Chunked Transfer-Encoding), transparent Gzip decompression, end-to-end `Client.Timeout`, `Request.WithContext` |
| **`mime`** | `stdgo.mime` | **95%** | RFC 1521/2183 `parseMediaType` (type, subtype, params), `formatMediaType`, `typeByExtension` (.json -> application/json), `extensionsByType`, and RFC 2046 `multipart.Writer`/`Reader` |
| **`net/mail`** | `stdgo.net.mail` | **100%** | RFC 5322 email address parsing (`Address`), `parseAddress`, `parseAddressList`, and `readMessage` (MIME header & streaming body) |
| **`path/filepath`** | `stdgo.path` | **85%** | Glob pattern `Match` (`*`, `?`, `[a-z]`, `\\` escapes), cross-platform path separators |
| **`archive/tar`** | `stdgo.archive.tar` | **90%** | POSIX USTAR archive `Reader` and `Writer`, 512-byte alignment, octal headers, trailer handling |
| **`archive/zip`** | `stdgo.archive.zip` | **90%** | ZIP archive `Reader` and `Writer`, tail EOCD locator, Central Directory index, CRC-32 verification |
| **`compress/gzip`** | `stdgo.compress.gzip` | **90%** | RFC 1952 Gzip `Writer` and `Reader`, header metadata, CRC-32 and `ISIZE` verification |
| **`compress/zlib`** | `stdgo.compress.zlib` | **100%** | RFC 1950 ZLIB `Reader` and `Writer`, Adler-32 verification, compression levels 0-9 & Huffman |
| **`compress/flate`**| `stdgo.compress.flate`| **100%** | RFC 1951 Raw Deflate `Reader` and `Writer`, streaming compression levels 0-9 & Huffman |
| **`crypto/sha256`** | `stdgo.crypto.sha256` | **100%** | RFC 6234 SHA-256, `Sum256`, `New` (implements `hash.Hash` & `io.Writer`) |
| **`crypto/md5`** | `stdgo.crypto.md5` | **100%** | RFC 1321 MD5, `Sum`, `New` (implements `hash.Hash` & `io.Writer`) |
| **`crypto/hmac`** | `stdgo.crypto.hmac` | **100%** | RFC 2104 Keyed-Hash Message Authentication Code; `New(h1, h2, key)`, `sha256`, `md5` shortcuts |
| **`hash`** | `stdgo.hash` | **100%** | `Hash`, `Hash32`, `Hash64` VTable interfaces conforming to Go's streaming hash model |
| **`math/rand`** | `stdgo.math.rand` | **85%** | Pseudo-random number generator (SplitMix64): `Uint64`, `Intn`, `Float64`, `Shuffle` |
| **`time`** | `stdgo.time` | **95%** | Composite unit string parser `ParseDuration` (`"2h45m"`), `Duration`, `Time`, `sleep`, civil calendar breakdown (`year`, `month`, `day`, `weekday`, `hour`, `minute`, `second`, `nanosecond`, `yearDay`), layout-based `format` & `parse` (`RFC3339`, `RFC1123`, `DateTime`, `Kitchen`), `date` construction, `Location` (UTC, `fixedZone`) |
| **`time/rate`** | `stdgo.time.rate` | **100%** | Token bucket rate limiter (`Limiter`), burst capacity, `allow`, `allowN`, `reserve`, `reserveN`, `wait`, `waitN`, `every(d)`, `inf`, integrated with `context.Context` and `std.Io` |
| **`slices`** | `stdgo.slices` | **95%** | Go 1.21+ generic algorithms: `Sort`, `BinarySearch`, `Reverse`, `Compact`, `Clone`, `Equal`, `Contains`, `Index` |
| **`sync`** | `stdgo.sync` | **90%** | Atomic lock-free `WaitGroup`, atomic 3-state `Once`, `Mutex`, generic `Pool(T)` |
| **`sync/errgroup`** | `stdgo.sync.errgroup` | **95%** | Task concurrency, first-error capture, `WithContext` broadcast cancellation, `SetLimit` limiter |
| **`log/slog`** | `stdgo.log.slog` | **90%** | Go 1.21 structured logging: `Level`, `Attr`, `Handler` VTable (`TextHandler`, `JSONHandler`), `Logger.With` |
| **`regexp`** | `stdgo.regexp` | **85%** | Linear-time Pike VM / Thompson NFA bytecode execution with $O(N \times L)$ guarantee |
| **`flag`** | `stdgo.flag` | **90%** | `FlagSet`, flag pointers (`Bool`, `Int`, `String`, `Float`), `--help` generation |
| **`text/tabwriter`** | `stdgo.text.tabwriter`| **90%** | Elastic Tabstops column alignment, padding, right-align, vertical `Debug` bar separator |
| **`container/ring`** | `stdgo.container.ring`| **100%** | Bidirectional circular buffer `Ring(T)` |
| **`container/heap`** | `stdgo.container.heap`| **100%** | Min/Max binary heap `Heap(T, lessFn)` |
| **`container/list`** | `stdgo.container.list`| **100%** | Doubly-linked list `List(T)` (`pushFront`, `pushBack`, `insertAfter`, `remove`, `moveToFront`) |
| **`maps`** | `stdgo.maps` | **100%** | Go 1.21 generic map utilities: `clone`, `copy`, `equal`, `equalFunc`, `deleteFunc`, `keys`, `values` |
| **`net` (IP/CIDR/HostPort)** | `stdgo.net` | **95%** | `IP` (IPv4/IPv6, `isLoopback`, `isPrivate`), `IPMask`, `IPNet` (`contains`), `parseIp`, `parseCidr`, `splitHostPort`, `joinHostPort` |
| **`os/exec`** | `stdgo.os.exec` | **95%** | Subprocess management: `command`, `commandContext` (timeout/cancellation), piped `*io.Reader`/`*io.Writer`, `output`, `combinedOutput` |
| **`os` (File/Env)** | `stdgo.os` | **95%** | Stream-oriented `File` (`*io.Reader`/`*io.Writer`), `open`, `create`, `readFile`, `writeFile`, `mkdirAll`, `remove`, `readDir`, explicit `getenv`/`lookupEnv` |
| **`text/template`** | `stdgo.text.template` | **100%** | Data-driven templating: `Template`, `parse`, `execute`, `executeTemplate`, fields (`.Name`), pipelines (`| upper`), `if-else` ladder, `with` scope, `range`/`for` loops with payload capture (`|item, idx|`), Zig-style bindings (`const x = ...`, `var x = ...`), quoted identifiers (`.@"content-type"`), sub-template composition (`define`, `template`, `block`), custom functions (`addFunc`, `funcMap`), built-in math/logic/comparison/printf funcs, `Must` |
| **`html/template`** | `stdgo.html.template` | **100%** | Context-aware auto-escaping against XSS: HTML body entity escaping, attribute escaping, URL scheme sanitization (`#ZgotmplZ`), JS literal escaping (`\x3c/script\x3e`), CSS/comment protection, safe wrapper types (`HTML`, `JS`, `CSS`, `URL`, `HTMLAttr`), template composition |
| **`database/sql`** | `stdgo.database.sql` | **100%** | Generic SQL connection pool (`DB`), single-row scanner (`Row`, `queryRow`, `ErrNoRows`), transactions (`Tx`, `beginTx`, `TxOptions`, `IsolationLevel`), prepared statements (`Stmt`), result cursors (`Rows`, `rows.err()`, `rows.lastError()`), pluggable `Driver`/`Conn` VTable, thread-safe pool management (`max_open`, `max_idle`, `conn_max_lifetime`, `DBStats`), bad connection auto-retry (`driver.ErrBadConn`), out-of-band query interruption (`interrupt`, `interruptAll`), and lazy optional real `SQLiteDriver` adapter (`-Dsqlite=true` via `nDimensional/zig-sqlite`) |
| **`encoding/json`** | `stdgo.encoding.json` | **95%** | Streaming `Decoder` (`token`, `more`, `decode`), `Encoder` (`encode`, `setIndent`), `marshal`, `marshalIndent`, `unmarshal`, `valid` |
| **`bufio`** | `stdgo.bufio` | **100%** | Streaming tokenization (`Scanner`), customizable `SplitFunc`, `scanLines` (cross-chunk `\r\n` / `\n`), `scanWords`, `scanBytes`, `scanRunes` (UTF-8), dynamic sliding buffer up to `max_token_size` |
| **`sync/semaphore`** | `stdgo.sync.semaphore` | **100%** | Weighted semaphore (`Weighted`), FIFO fairness, `acquire(ctx, n)`, `tryAcquire(n)`, `release(n)`, integrated with `Context` and `std.Io` cooperative sleep |
| **`net/textproto`** | `stdgo.net.textproto` | **100%** | Line-oriented network protocol helpers: `readLine`, `readContinuedLine` (RFC 822), `readMIMEHeader`, `readDotBytes` (SMTP/NNTP dot-stuffing unescaping), `dotWriter`, `canonicalMIMEHeaderKey` |
| **`encoding/base32`** | `stdgo.encoding.base32` | **100%** | RFC 4648 Base32 encoding/decoding, `StdEncoding`, `HexEncoding`, `withPadding`, `noPadding` (TOTP secrets) |

---

## 4. Gap Analysis: Missing Packages by Domain

### 4.1 Data Formats & Serialization
- [ ] **`encoding/xml` & `encoding/asn1`**:
  - *Current State*: Not implemented. (Lower priority, XML usage is declining).

### 4.2 Cryptography & Security
- [ ] **`crypto/cipher` & `crypto/aes`**:
  - *Current State*: Missing symmetric encryption stream abstractions.
  - *Target*: `cipher.Block`, `cipher.Stream`, `cipher.AEAD` (GCM mode, CBC mode, CTR mode).
- [ ] **`crypto/ed25519`**:
  - *Current State*: Missing standalone Go-style API (though Zig std has underlying primitive).
  - *Target*: `GenerateKey`, `Sign`, `Verify`.
- [ ] **`crypto/rsa` & `crypto/ecdsa`**:
  - *Current State*: Not implemented.
- [ ] **`crypto/x509`**:
  - *Current State*: Basic root bundle verification in TLS; lacks full X.509 certificate parser and CSR generator.

### 4.3 Operating System & Subprocesses
- [x] **`os` File & Environment Helpers**:
  - *Current State*: `os.File` implementing `stdgo.io.Reader`, `stdgo.io.Writer`, `stdgo.io.Seeker`, `stdgo.io.Closer`; environment manipulation (`os.getenv`, `os.lookupEnv`, `os.environ` via explicit `Environ.Map`), directory operations (`readDir`, `mkdirAll`, `remove`, `stat`).

### 4.4 Networking Primitives
- [x] **`net` (IP/CIDR Utilities)**:
  - *Current State*: `net.IP`, `net.IPMask`, `net.IPNet`, `net.parseIp`, `net.parseCidr`, `net.splitHostPort`, `net.joinHostPort`.
- [ ] **`net.http` (HTTP/2)**:
  - *Current State*: HTTP/1.1 complete; HTTP/2 (ALPN framing/multiplexing) is intentionally deferred.

### 4.5 Templating & Text
- [x] **`text/template`**:
  - *Current State*: Full data-driven templating engine with whitespace trimming (`{{-`, `-}}`), multi-branch `{{ else if ... }}`, scope re-binding `{{ with ... }}`, Zig-style variable declarations (`const x = ...`, `var x = ...`, mutation `x = ...`), payload captures in loops (`{{ for .Items \|item, idx\| }}`), comparison/logic/format built-ins (`eq`, `ne`, `lt`, `le`, `gt`, `ge`, `and`, `or`, `not`, `printf`, `print`, `println`, `index`, `slice`, `add`, `sub`, `mul`).
- [x] **`html/template`**:
  - *Current State*: Context-aware auto-escaping on top of `text/template`, protecting HTML body, attributes, URLs (`#ZgotmplZ`), JS scripts (`\x3c/script\x3e`), and comments, with safe bypass types (`HTML`, `JS`, `CSS`, `URL`, `HTMLAttr`).
- [ ] **`text/template` (Go Syntax Compatibility)**:
  - *Future Work*: Tracked for 100% Go template compatibility: Go-style variable syntax (`$x := expr`, `$x = expr`, `range $idx, $item := expr`).

---

## 5. Prioritized Implementation Roadmap

### Phase 1: High-Utility Core (Completed ✅)
- [x] `container/list`
- [x] `os/exec`
- [x] `encoding/json` (Streaming Decoder/Encoder)
- [x] `maps` (Generic)
- [x] `net` (IP & CIDR Primitives)
- [x] `compress/zlib` & `compress/flate`
- [x] `os` (File & Env)
- [x] `text/template`
- [x] `html/template`
- [x] `database/sql`

### Phase 2: Security & Crypto Extensions (Next Focus)
1. **`crypto/cipher` & `crypto/aes`**:
   - Standard block cipher modes (GCM, CBC, CTR) wrapping TigerStyle-verified memory boundaries.
2. **`crypto/ed25519`**:
   - Fast, high-security Ed25519 signature generation and verification.
3. **`net/http` Client Advanced TLS**:
   - mTLS client certificate configuration and custom verification callbacks.

### Phase 3: Specialized Ecosystem Packages
1. **`html/template`**:
   - Context-aware HTML sanitization and auto-escaping.
2. **`database/sql` driver abstraction**:
   - Generic database connection pool, statement caching, and transaction interfaces.
3. **`testing` (Table-Driven Helpers)**:
   - Go-style subtest organization and assertions.
4. **`net/http` HTTP/2 Transport**:
   - Multiplexed framing layer for HTTP/2 client connections.
