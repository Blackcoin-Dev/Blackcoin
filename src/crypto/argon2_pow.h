// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_CRYPTO_ARGON2_POW_H
#define BITCOIN_CRYPTO_ARGON2_POW_H

#include <cstddef>
#include <cstdint>

/** Raw Argon2id (version 0x13) for proof-of-work inputs, which are public.
 *
 * The output is bit-identical to argon2id_hash_raw() for the same arguments.
 * Two costs of the general-purpose entry point are left out, and only here:
 * the working memory is a block owned by the calling thread and reused from
 * hash to hash instead of being allocated and freed each time, and it is not
 * wiped afterwards. Never pass a password, a key or any other secret to this
 * function: use the argon2 API directly for that.
 *
 * Returns an ARGON2_* error code (ARGON2_OK is zero). Not reentrant within a
 * thread; safe to call from any number of threads at once. */
int Argon2idPowHashRaw(uint32_t t_cost, uint32_t m_cost_kib, uint32_t lanes,
                       const unsigned char* input, size_t input_len,
                       const unsigned char* salt, size_t salt_len,
                       unsigned char* out, size_t out_len);

#endif // BITCOIN_CRYPTO_ARGON2_POW_H
