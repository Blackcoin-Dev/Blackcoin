package=openssl
$(package)_version=3.5.9
$(package)_download_path=https://github.com/openssl/openssl/releases/download/openssl-$($(package)_version)
$(package)_file_name=openssl-$($(package)_version).tar.gz
$(package)_sha256_hash=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

# A static default provider supplies TLS/X.509 on every target. There is no
# loadable provider, engine, host configuration, or runtime module dependency.
define $(package)_set_vars
  $(package)_config_opts=--prefix=$(host_prefix) --openssldir=$(host_prefix)/etc/openssl --libdir=lib
  $(package)_config_opts+=no-shared no-module no-dso no-engine no-autoload-config no-pinshared no-tests no-apps no-docs no-zlib
  $(package)_config_opts+=no-ssl3 no-comp
  $(package)_target=linux-generic64
  $(package)_target_x86_64_linux=linux-x86_64
  $(package)_target_aarch64_linux=linux-aarch64
  $(package)_target_riscv64_linux=linux64-riscv64
  $(package)_target_powerpc64_linux=linux-ppc64
  $(package)_target_powerpc64le_linux=linux-ppc64le
  $(package)_target_s390x_linux=linux64-s390x
  $(package)_target_x86_64_darwin=darwin64-x86_64
  $(package)_target_aarch64_darwin=darwin64-arm64
  $(package)_target_x86_64_mingw32=mingw64
  $(package)_target_x86_64_freebsd=BSD-x86_64
  $(package)_target_aarch64_freebsd=BSD-aarch64
  $(package)_target_x86_64_netbsd=BSD-x86_64
  $(package)_target_x86_64_openbsd=BSD-x86_64
  $(package)_cflags+=-fPIC -std=gnu11
  $(package)_cppflags_mingw32=-D_WIN32_WINNT=0x0601
  # Match depends archive normalization and avoid OpenSSL build-time timestamps.
  $(package)_build_env=SOURCE_DATE_EPOCH=946684800 ZERO_AR_DATE=1
  $(package)_config_env=CC="$$($(package)_cc)" AR="$$($(package)_ar)" RANLIB="$$($(package)_ranlib)"
  $(package)_config_env+=CFLAGS="$$($(package)_cflags)" CPPFLAGS="$$($(package)_cppflags) $$($(package)_cppflags_$(host_os))" LDFLAGS="$$($(package)_ldflags)"
endef

define $(package)_config_cmds
  ./Configure $(or $($(package)_target_$(host_arch)_$(host_os)),$($(package)_target)) $($(package)_config_opts)
endef

define $(package)_build_cmds
  $(MAKE) build_libs
endef

define $(package)_stage_cmds
  $(MAKE) DESTDIR=$($(package)_staging_dir) install_dev
endef

define $(package)_postprocess_cmds
  rm -rf bin share etc lib/cmake lib/engines-3 lib/ossl-modules
endef
