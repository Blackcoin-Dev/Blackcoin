package=curl
$(package)_version=8.23.0
$(package)_download_path=https://curl.se/download
$(package)_file_name=curl-$($(package)_version).tar.xz
$(package)_sha256_hash=8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5
$(package)_dependencies=openssl

# HTTP/1.1 + HTTPS + SOCKS only. Direct DNS is pre-resolved by Core's evdns
# adapter. Neither a resolver thread nor an additional DNS library is built.
define $(package)_set_vars
  $(package)_config_opts=--disable-shared --enable-static --with-pic --enable-option-checking=fatal
  $(package)_config_opts+=--with-openssl=$(host_prefix) --disable-openssl-auto-load-config
  $(package)_config_opts+=--without-gnutls --without-mbedtls --without-wolfssl --without-rustls --without-schannel --without-amissl --without-apple-sectrust
  $(package)_config_opts+=--without-ca-bundle --without-ca-path --without-ca-fallback --without-ca-embed --disable-ca-native --disable-ca-search
  $(package)_config_opts+=--disable-ares --disable-threaded-resolver --without-libuv --disable-doh --disable-httpsrr --disable-ech
  $(package)_config_opts+=--without-zlib --without-brotli --without-zstd --without-libpsl --without-libidn2 --without-winidn --without-apple-idn
  $(package)_config_opts+=--without-nghttp2 --without-nghttp3 --without-ngtcp2 --without-quiche --disable-proxy-http3
  $(package)_config_opts+=--disable-ftp --disable-file --disable-ipfs --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp
  $(package)_config_opts+=--disable-pop3 --disable-imap --disable-smtp --disable-gopher --disable-mqtt --disable-websockets
  $(package)_config_opts+=--disable-http-auth --disable-basic-auth --disable-bearer-auth --disable-digest-auth --disable-kerberos-auth --disable-negotiate-auth --disable-ntlm --disable-aws --disable-httpsig --disable-sspi --without-gssapi --disable-gssapi-apple --without-libgsasl --without-libssh --without-libssh2
  $(package)_config_opts+=--disable-cookies --disable-netrc --disable-alt-svc --disable-hsts --disable-unix-sockets
  $(package)_config_opts+=--disable-docs --disable-manual --disable-libcurl-option --disable-dependency-tracking --without-zsh-functions-dir --without-fish-functions-dir
  # curl's OpenSSL probes need the private platform libraries of our static build.
  $(package)_config_env=PKG_CONFIG="pkg-config --static"
  $(package)_build_env=ZERO_AR_DATE=1
  $(package)_cppflags_mingw32=-DCURL_STATICLIB -D_WIN32_WINNT=0x0601
endef

define $(package)_preprocess_cmds
  cp -f $(BASEDIR)/config.guess $(BASEDIR)/config.sub .
endef

define $(package)_config_cmds
  $($(package)_autoconf)
endef

define $(package)_build_cmds
  $(MAKE) -C lib
endef

define $(package)_stage_cmds
  $(MAKE) -C lib DESTDIR=$($(package)_staging_dir) install && \
  $(MAKE) -C include DESTDIR=$($(package)_staging_dir) install && \
  $(MAKE) DESTDIR=$($(package)_staging_dir) install-pkgconfigDATA
endef

define $(package)_postprocess_cmds
  rm -f lib/*.la
endef
