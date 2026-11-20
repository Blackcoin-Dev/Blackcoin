// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/coin_facts.h>

#include <chain.h>
#include <script/script.h>

#include <array>
#include <cstring>

namespace wallet {
namespace {
/** VARINT(n) as the coins database key holds it (see WriteVarInt). Returns
 * the number of bytes written. */
size_t EncodeKeyVarInt(uint32_t n, std::array<unsigned char, 5>& out)
{
    std::array<unsigned char, 5> tmp{};
    size_t len{0};
    for (;;) {
        tmp[len] = static_cast<unsigned char>((n & 0x7F) | (len ? 0x80 : 0x00));
        if (n <= 0x7F) break;
        n = (n >> 7) - 1;
        ++len;
    }
    const size_t size{len + 1};
    for (size_t i = 0; i < size; ++i) out[i] = tmp[len - i];
    return size;
}
} // namespace

uint32_t ConfirmedCoinTime(int32_t tx_version, uint32_t tx_time, uint32_t block_time)
{
    return tx_version < 2 ? tx_time : block_time;
}

std::optional<Coin> DeriveConfirmedCoin(const CTxOut& txout, const ConfirmedTxFacts& tx, const CBlockIndex* tip)
{
    AssertLockHeld(::cs_main);
    if (tx.coinbase || !tip || tx.block_height < 0 || tx.block_height > tip->nHeight ||
        txout.scriptPubKey.IsUnspendable()) return std::nullopt;
    const CBlockIndex* block = tip->GetAncestor(tx.block_height);
    if (!block || block->GetBlockHash() != tx.block_hash) return std::nullopt;
    return Coin(txout, tx.block_height, /*fCoinBaseIn=*/false, tx.coinstake,
                ConfirmedCoinTime(tx.version, tx.time, block->nTime));
}

bool ChainstateKeyLess(const COutPoint& a, const COutPoint& b)
{
    const int hash_order = std::memcmp(a.hash.begin(), b.hash.begin(), uint256::size());
    if (hash_order != 0) return hash_order < 0;
    if (a.n == b.n) return false;
    std::array<unsigned char, 5> key_a{}, key_b{};
    const size_t size_a = EncodeKeyVarInt(a.n, key_a);
    const size_t size_b = EncodeKeyVarInt(b.n, key_b);
    return std::lexicographical_compare(key_a.begin(), key_a.begin() + size_a,
                                        key_b.begin(), key_b.begin() + size_b);
}

std::vector<unsigned char> ChainstateKeyBytes(const COutPoint& outpoint)
{
    std::vector<unsigned char> key;
    key.reserve(1 + uint256::size() + 5);
    key.push_back('C');
    key.insert(key.end(), outpoint.hash.begin(), outpoint.hash.end());
    std::array<unsigned char, 5> index{};
    const size_t size = EncodeKeyVarInt(outpoint.n, index);
    key.insert(key.end(), index.begin(), index.begin() + size);
    return key;
}

OrderedCoinReader::OrderedCoinReader(std::vector<COutPoint> outpoints)
    : m_outpoints(std::move(outpoints)), m_coins(m_outpoints.size())
{
    m_cursor.Reset(m_outpoints.size(), [&](uint32_t i) -> const COutPoint& { return m_outpoints[i]; });
}

} // namespace wallet
