# Dependencies

These are the dependencies used by Blackcoin.
You can find installation instructions in the `build-*.md` file for your platform.
"Runtime" and "Version Used" are both in reference to the release binaries.

| Dependency | Minimum required |
| --- | --- |
| [Autoconf](https://www.gnu.org/software/autoconf/) | [2.69](https://github.com/bitcoin/bitcoin/pull/17769) |
| [Automake](https://www.gnu.org/software/automake/) | [1.13](https://github.com/bitcoin/bitcoin/pull/18290) |
| [Clang](https://clang.llvm.org) | [10.0](https://github.com/bitcoin/bitcoin/pull/27682) |
| [GCC](https://gcc.gnu.org) | [9.1](https://github.com/bitcoin/bitcoin/pull/27662) |
| [Python](https://www.python.org) (scripts, tests) | [3.8](https://github.com/bitcoin/bitcoin/pull/27483) |
| [systemtap](https://sourceware.org/systemtap/) ([tracing](tracing.md))| N/A |

## Required

| Dependency | Releases | Version used | Minimum required | Runtime |
| --- | --- | --- | --- | --- |
| [Boost](../depends/packages/boost.mk) | [link](https://www.boost.org/users/download/) | [1.81.0](https://github.com/bitcoin/bitcoin/pull/26557) | [1.64.0](https://github.com/bitcoin/bitcoin/pull/22320) | No |
| [libevent](../depends/packages/libevent.mk) | [link](https://github.com/libevent/libevent/releases) | [2.1.12-stable](https://github.com/bitcoin/bitcoin/pull/21991) | [2.1.8](https://github.com/bitcoin/bitcoin/pull/24681) | No |
| [libcurl](../depends/packages/curl.mk) (node HTTPS bootstrap) | [link](https://curl.se/download.html) | 8.23.0 | 7.77.0 API floor | No (static in depends) |
| [OpenSSL](../depends/packages/openssl.mk) (libcurl TLS backend) | [link](https://openssl-library.org/source/) | 3.5.9 LTS | 3.5.9 for pinned builds | No (static in depends) |
| glibc | [link](https://www.gnu.org/software/libc/) | N/A | [2.27](https://github.com/bitcoin/bitcoin/pull/27029) | Yes |
| Linux Kernel | [link](https://www.kernel.org/) | N/A | [3.17.0](https://github.com/bitcoin/bitcoin/pull/27699) | Yes |

## Optional

### GUI
| Dependency | Releases | Version used | Minimum required | Runtime |
| --- | --- | --- | --- | --- |
| [Fontconfig](../depends/packages/fontconfig.mk) | [link](https://www.freedesktop.org/wiki/Software/fontconfig/) | [2.12.6](https://github.com/bitcoin/bitcoin/pull/23495) | 2.6 | Yes |
| [FreeType](../depends/packages/freetype.mk) | [link](https://freetype.org) | [2.11.0](https://github.com/bitcoin/bitcoin/commit/01544dd78ccc0b0474571da854e27adef97137fb) | 2.3.0 | Yes |
| [qrencode](../depends/packages/qrencode.mk) | [link](https://fukuchi.org/works/qrencode/) | [4.1.1](https://github.com/bitcoin/bitcoin/pull/27312) | | No |
| [Qt](../depends/packages/qt.mk) | [link](https://download.qt.io/archive/qt/) | [5.15.10](https://github.com/bitcoin/bitcoin/pull/28561) | [5.11.3](https://github.com/bitcoin/bitcoin/pull/24132) | No |

### Networking
| Dependency | Releases | Version used | Minimum required | Runtime |
| --- | --- | --- | --- | --- |
| [libnatpmp](../depends/packages/libnatpmp.mk) | [link](https://github.com/miniupnp/libnatpmp/) | commit [07004b9...](https://github.com/bitcoin/bitcoin/pull/25917) | | No |
| [MiniUPnPc](../depends/packages/miniupnpc.mk) | [link](https://miniupnp.tuxfamily.org/) | [2.2.2](https://github.com/bitcoin/bitcoin/pull/20421) | 2.1 | No |

### Notifications
| Dependency | Releases | Version used | Minimum required | Runtime |
| --- | --- | --- | --- | --- |
| [ZeroMQ](../depends/packages/zeromq.mk) | [link](https://github.com/zeromq/libzmq/releases) | [4.3.4](https://github.com/bitcoin/bitcoin/pull/23956) | 4.0.0 | No |

### Wallet
| Dependency | Releases | Version used | Minimum required | Runtime |
| --- | --- | --- | --- | --- |
| [Berkeley DB](../depends/packages/bdb.mk) (legacy wallet) | [link](https://www.oracle.com/technetwork/database/database-technologies/berkeleydb/downloads/index.html) | 4.8.30 | 4.8.x | No |
| [SQLite](../depends/packages/sqlite.mk) | [link](https://sqlite.org) | [3.38.5](https://github.com/bitcoin/bitcoin/pull/25378) | [3.7.17](https://github.com/bitcoin/bitcoin/pull/19077) | No |

Node builds (daemon, Qt, tests, benchmarks and fuzz targets) require libcurl with
OpenSSL. RPC-only CLI builds do not require libcurl. Release builds use the
pinned static `curl` and `openssl` recipes on Linux, macOS and Windows; Perl
5.10 or newer is a build tool for OpenSSL. The 7.77.0 curl floor identifies the
embedded-CA API, not a recommended security baseline for host libraries.

The HTTPS seed trust store is the checked-in Mozilla snapshot in
`share/httpsseed/ca-bundle.pem`, embedded byte-for-byte in `src/httpsseed_ca.h`.
Its dated upstream URL, SHA-256, licenses and maintenance procedure are in
[share/httpsseed/README.md](../share/httpsseed/README.md). The depends curl has
no default CA file/directory or native trust fallback, no threaded resolver,
no compression, and only HTTP/HTTPS protocols plus SOCKS proxy support.
