# HTTPS seed TLS dependencies and trust snapshot

The native node adapter uses the pinned static curl 8.23.0 and OpenSSL 3.5.9
LTS recipes on all supported release targets. The upstream release pages and
published security tables were checked on 2026-11-03 UTC. Their current fixes
are included in these versions. This is a dated review, not a future security
guarantee. OpenSSL 3.5 is an LTS branch supported upstream through 2030-04-08.

`provenance.json` pins each downloaded archive and the Mozilla CA snapshot.
OpenSSL and CA hashes were compared with the upstream checksum files; the curl
archive hash was cross-checked against the curl project's `curl-for-win` pin.
The files retain their upstream licenses here (curl license, Apache-2.0 and
MPL-2.0). Root certificates are public data; the bundled Mozilla source file
is distributed under MPL-2.0 as described by curl's CA extraction page.

`ca-bundle.pem` is the unmodified 2026-10-20 curl extraction of Mozilla's
public server-authentication roots (118 certificates). `src/httpsseed_ca.h`
contains these exact bytes, including upstream notices. The transport passes
this memory as `CURLOPT_CAINFO_BLOB` and verifies chain, validity and hostname.
No bundle refresh happens at runtime. A trust failure leaves existing discovery
available. The depends curl disables native trust, default CA file/directory,
OpenSSL default-store fallback and automatic OpenSSL configuration loading.

To update, review current official release/security pages and Mozilla/curl CA
changes; download a dated bundle from https://curl.se/ca/ and verify its
published SHA-256. Review certificates and license changes, update the bundle
and `provenance.json`, then regenerate and verify:

```sh
python3 share/httpsseed/generate_header.py
python3 share/httpsseed/generate_header.py --check
```

Run TLS positive/negative, trust and packaging tests before distributing the
new build. Dependency bumps require updated source hashes and security review.
The generator performs no network requests and refuses a mismatched bundle.
The checked-in header makes builds independent of Python and network access.
