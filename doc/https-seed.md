# HTTPS peer bootstrap

On mainnet, `-httpsseed=1` supplements DNS, fixed seeds and P2P address discovery
with the versioned directory at
`https://projectblackcoin.org/api/bootstrap/v1/peers`. The daemon and Qt use the
same native client. Entries are untrusted address hints. Their advertised service
bits never establish a live peer's chain, QQ eligibility, staking or rewards.
Normal P2P checks remain authoritative, and existing QQ pursuit limits remain.

`-httpsseed=0` disables this source. It is also suppressed by `-dnsseed=0`,
`-dns=0`, any `-connect` setting including `-connect=0`, `-maxconnections=0`,
`-networkactive=0`, non-mainnet networks, and `onlynet` configurations that exclude
both IPv4 and IPv6. HTTPS failure does not disable existing discovery or erase
addresses. On mainnet both the existing blackcoin.nl DNS sources and this HTTPS
source perform independent startup and refresh rounds, including when peers are
healthy. One source's success cannot suppress the other. Each uses a steady-clock
cooldown of 30 minutes plus up to 299 seconds jitter. The initial addrman-based
startup delay remains. DNS always requests legacy-compatible desirable services,
with a separate bounded QQ-filtered lookup when there is a QQ deficit. A missing
base filter response resolves the plain hostname and adds its results as untrusted
legacy service hints without a QQ flag. With a name proxy, DNS uses only the
existing proxied P2P address fetch. DNS hints keep the chain's default P2P port; the HTTPS route
preserves published nondefault ports.
Sleep/wake and network toggles do not reset that cooldown.

The configured Core proxy controls routing. A SOCKS hostname proxy resolves the
HTTPS origin remotely, and failure never falls back to a direct connection.
Randomized SOCKS credentials respect `-proxyrandomize`. Environment proxy and
`NO_PROXY` variables cannot override Core's routing. A hostname proxy cannot
force its origin resolution to one IP family. HTTPS therefore skips an explicit
single-family `-onlynet` restriction when a proxy is in use. Dual-family proxy
configurations remain supported. Returned peer addresses always obey `onlynet`.
Direct requests resolve with cancellable libevent DNS and connect only to allowed
public address families. The HTTPS provider remains one discovery failure domain.

Each attempt has a ten-second monotonic budget covering DNS, proxy, TLS and HTTP.
Shutdown or disabling networking cancels the attempt. A rapid off/on toggle
invalidates the earlier result. HTTP response bodies are bounded to 64 KiB and
headers to 16 KiB; only HTTP 200 JSON is accepted. Redirects, cookies, netrc,
authentication, automatic client certificates, decompression and additional URL
protocols are disabled. No downloader process, wallet or RPC action is involved.

The embedded public CA bundle and OpenSSL-backed libcurl are pinned by the build.
Certificate chain, expiry and hostname verification are mandatory, with TLS 1.2
or newer. There is no runtime URL, CA or certificate-verification override.
Trust failures leave the existing discovery paths available. Trust-bundle
provenance and update policy are recorded with its build resource.

The `blackcoin.bootstrap/1` contract requires `network: "main"`, integer Unix
`generated_at` and `expires_at`, and at most 64 `peers`. A publication lives at
most 120 seconds, with five seconds clock skew tolerance. Peer observations are
at most 900 seconds old. Addresses must be canonical numeric public IPv4 or
native global IPv6, with actual integer ports and known NETWORK/LIMITED/WITNESS
plus QQ service bits. QQ and NETWORK are required, or QQ with LIMITED and WITNESS
when NETWORK is absent. Missing service bits are never synthesized. Scoped, mapped, transition, private and local addresses are
rejected. Duplicate JSON keys, invalid UTF-8 and nesting above 16 are rejected.
Each source contributes at most two addresses per Core network group and one
port per IP. Protected origin addresses must also be excluded by the publisher;
a directory entry does not prove public endpoint reachability.

The C++ test harness injects an isolated endpoint and trust root. Those facilities
have no configuration or RPC entry point in the production client.
