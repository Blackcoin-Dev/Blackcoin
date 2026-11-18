// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <crypto/argon2_pow.h>

#include <crypto/argon2/argon2.h>

#include <cstdlib>

namespace {
/** One working block per thread, grown on demand and released with the
 * thread. Argon2 writes every block of the first pass before it reads it, so
 * what an earlier hash left behind never reaches the output. */
struct PowArena {
    uint8_t* memory{nullptr};
    size_t size{0};
    ~PowArena() { std::free(memory); }
};
thread_local PowArena t_pow_arena;

int PowArenaAllocate(uint8_t** memory, size_t bytes_to_allocate)
{
    PowArena& arena = t_pow_arena;
    if (arena.size < bytes_to_allocate) {
        std::free(arena.memory);
        arena.memory = static_cast<uint8_t*>(std::malloc(bytes_to_allocate));
        arena.size = arena.memory ? bytes_to_allocate : 0;
    }
    *memory = arena.memory;
    return arena.memory ? ARGON2_OK : ARGON2_MEMORY_ALLOCATION_ERROR;
}

void PowArenaFree(uint8_t* /*memory*/, size_t /*bytes_to_allocate*/)
{
    // The block stays with the thread for its next hash.
}
} // namespace

int Argon2idPowHashRaw(uint32_t t_cost, uint32_t m_cost_kib, uint32_t lanes,
                       const unsigned char* input, size_t input_len,
                       const unsigned char* salt, size_t salt_len,
                       unsigned char* out, size_t out_len)
{
    // The same bounds argon2_hash() applies before it builds its context.
    if (input_len > ARGON2_MAX_PWD_LENGTH) return ARGON2_PWD_TOO_LONG;
    if (salt_len > ARGON2_MAX_SALT_LENGTH) return ARGON2_SALT_TOO_LONG;
    if (out_len > ARGON2_MAX_OUTLEN) return ARGON2_OUTPUT_TOO_LONG;
    if (out_len < ARGON2_MIN_OUTLEN) return ARGON2_OUTPUT_TOO_SHORT;

    argon2_context context{};
    context.out = out;
    context.outlen = static_cast<uint32_t>(out_len);
    // The library reads these two buffers and never writes them unless a
    // CLEAR flag is set, which it is not.
    context.pwd = const_cast<uint8_t*>(input);
    context.pwdlen = static_cast<uint32_t>(input_len);
    context.salt = const_cast<uint8_t*>(salt);
    context.saltlen = static_cast<uint32_t>(salt_len);
    context.secret = nullptr;
    context.secretlen = 0;
    context.ad = nullptr;
    context.adlen = 0;
    context.t_cost = t_cost;
    context.m_cost = m_cost_kib;
    context.lanes = lanes;
    context.threads = lanes;
    context.version = ARGON2_VERSION_13;
    context.allocate_cbk = PowArenaAllocate;
    context.free_cbk = PowArenaFree;
    context.flags = ARGON2_FLAG_PUBLIC_DATA_NO_WIPE;
    return argon2id_ctx(&context);
}
