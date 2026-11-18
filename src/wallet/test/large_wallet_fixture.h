// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_TEST_LARGE_WALLET_FIXTURE_H
#define BITCOIN_WALLET_TEST_LARGE_WALLET_FIXTURE_H

#include <coins.h>
#include <consensus/amount.h>
#include <key.h>
#include <key_io.h>
#include <node/blockstorage.h>
#include <primitives/transaction.h>
#include <script/descriptor.h>
#include <script/script.h>
#include <script/signingprovider.h>
#include <test/util/setup_common.h>
#include <validation.h>
#include <wallet/context.h>
#include <wallet/test/util.h>
#include <wallet/transaction.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>

#include <boost/test/unit_test.hpp>

#include <cstdlib>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace wallet {
namespace test {

/**
 * How large a wallet to build. The field wallets that stalled on spinning
 * disks held about 140,000 wallet transactions and 124,000 live outputs. The
 * default runs use 5,000 transactions with the same proportions; the full size
 * runs from the test cases labelled "scale" (disabled unless selected by
 * name), or when BLACKCOIN_LARGE_WALLET=full is set in the environment.
 *
 * Every wallet transaction has one output. A live output is unspent in the
 * wallet and is a coin in the chainstate; `coinbase_outputs` of the live ones
 * are coinbase outputs (mature). The other transactions are spent by a live
 * transaction of the wallet and have no coin in the chainstate.
 */
struct LargeWalletSize {
    size_t txs{5000};
    size_t live_outputs{4428};
    size_t coinbase_outputs{36};

    static LargeWalletSize Default() { return {}; }
    static LargeWalletSize Full() { return {140'000, 124'000, 1'000}; }
    static LargeWalletSize FromEnvironment()
    {
        const char* mode = std::getenv("BLACKCOIN_LARGE_WALLET");
        return (mode && std::string{mode} == "full") ? Full() : Default();
    }
};

/** A wallet with a large history, and matching coins in the test chainstate. */
struct LargeWallet {
    std::string name;
    std::shared_ptr<CWallet> wallet;
    CScript script;
    CAmount live_total{0};
    CAmount coinbase_live_total{0};
    size_t txs{0};
    std::set<COutPoint> live;                 //!< unspent outputs, all with a coin in the chainstate
    std::set<uint256> coinbase_txids;         //!< live coinbase transactions
    std::set<uint256> noncoinbase_live_txids; //!< transactions of the live, non-coinbase outputs
};

/**
 * Build the wallet in `setup`'s chain: a real SQLite wallet file (so commits
 * are real commits), all records written in one grouped commit, and the live
 * outputs added to the chainstate and flushed to its database, so that every
 * later lookup reaches the database. The wallet is not registered with the
 * validation interface; it knows the chain tip as its last processed block.
 */
inline LargeWallet BuildLargeWallet(TestChain100Setup& setup, const LargeWalletSize& size, const std::string& name)
{
    BOOST_REQUIRE_GE(size.txs, size.live_outputs);
    BOOST_REQUIRE_GE(size.live_outputs, size.coinbase_outputs);
    // Each dead transaction is spent by one live transaction.
    const size_t dead = size.txs - size.live_outputs;
    BOOST_REQUIRE_GE(size.live_outputs - size.coinbase_outputs, dead);

    // Coinbase outputs of height 1 are deep enough to be mature after these.
    setup.mineBlocks(20);

    LargeWallet out;
    out.name = name;
    out.script = GetScriptForRawPubKey(setup.coinbaseKey.GetPubKey());
    out.txs = size.txs;

    DatabaseOptions options;
    options.require_format = DatabaseFormat::SQLITE;
    DatabaseStatus status;
    bilingual_str error;
    auto database{MakeWalletDatabase(name, options, status, error)};
    BOOST_REQUIRE_MESSAGE(database, error.original);
    out.wallet = std::make_shared<CWallet>(setup.m_node.chain.get(), "", std::move(database));
    CWallet& wallet = *out.wallet;
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);

    CChain& chain = setup.m_node.chainman->ActiveChain();
    std::vector<uint256> block_hashes;
    int tip_height;
    {
        LOCK(::cs_main);
        tip_height = chain.Height();
        for (int h = 0; h <= tip_height; ++h) block_hashes.push_back(chain[h]->GetBlockHash());
    }
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        wallet.SetLastBlockProcessed(tip_height, block_hashes.back());
        // Persist it, so a reopened wallet starts from the tip instead of rescanning.
        wallet.chainStateFlushed(ChainstateRole::NORMAL, chain.GetLocator());
    }
    {
        LOCK(wallet.cs_wallet);
        wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        wallet.SetupDescriptorScriptPubKeyMans();
        FlatSigningProvider provider;
        std::string desc_error;
        std::unique_ptr<Descriptor> desc = Parse("combo(" + EncodeSecret(setup.coinbaseKey) + ")", provider, desc_error, /*require_checksum=*/false);
        BOOST_REQUIRE(desc);
        WalletDescriptor w_desc(std::move(desc), 0, 0, 1, 1);
        BOOST_REQUIRE(wallet.AddWalletDescriptor(w_desc, provider, "", false));
    }

    // Records: a coinbase part, then pairs of (dead parent, live spender),
    // then plain live outputs.
    std::vector<std::pair<COutPoint, Coin>> coins;
    coins.reserve(size.live_outputs);
    uint64_t counter{0};
    const auto value_of = [](uint64_t n) { return static_cast<CAmount>(COIN / 100 * (1 + n % 50)); };
    const auto block_of = [&](uint64_t n) { return 1 + static_cast<int>(n % (tip_height - 10)); };
    const auto add = [&](const CMutableTransaction& mtx, int height, bool coinbase, bool live) {
        const CTransactionRef tx = MakeTransactionRef(mtx);
        const TxState state = TxStateConfirmed{block_hashes[height], height, static_cast<int>(counter % 2000)};
        {
            LOCK(wallet.cs_wallet);
            BOOST_REQUIRE(wallet.AddToWallet(tx, state));
        }
        if (live) {
            const COutPoint outpoint{tx->GetHash(), 0};
            out.live.insert(outpoint);
            out.live_total += tx->vout[0].nValue;
            if (coinbase) {
                out.coinbase_txids.insert(tx->GetHash());
                out.coinbase_live_total += tx->vout[0].nValue;
            } else {
                out.noncoinbase_live_txids.insert(tx->GetHash());
            }
            coins.emplace_back(outpoint, Coin{tx->vout[0], height, coinbase, /*fCoinStakeIn=*/false, /*nTimeIn=*/0});
        }
        return tx;
    };

    {
        LOCK(wallet.cs_wallet);
        // One commit for the whole history instead of one per record.
        std::unique_ptr<DatabaseBulkScope> writes = wallet.GetDatabase().MakeBulkScope();
        for (size_t i = 0; i < size.coinbase_outputs; ++i, ++counter) {
            CMutableTransaction coinbase;
            coinbase.vin.emplace_back(COutPoint{}, CScript{} << 1 << static_cast<int64_t>(counter));
            coinbase.vout.emplace_back(value_of(counter), out.script);
            add(coinbase, /*height=*/1, /*coinbase=*/true, /*live=*/true);
        }
        for (size_t i = 0; i < dead; ++i, counter += 2) {
            CMutableTransaction parent;
            parent.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(1)}, static_cast<uint32_t>(counter)});
            parent.nLockTime = static_cast<uint32_t>(counter);
            parent.vout.emplace_back(value_of(counter), out.script);
            const CTransactionRef parent_ref = add(parent, block_of(counter), false, /*live=*/false);
            CMutableTransaction child;
            child.vin.emplace_back(COutPoint{parent_ref->GetHash(), 0});
            child.nLockTime = static_cast<uint32_t>(counter + 1);
            child.vout.emplace_back(value_of(counter + 1), out.script);
            add(child, block_of(counter) + 1, false, /*live=*/true);
        }
        const size_t placed = out.live.size();
        for (size_t i = placed; i < size.live_outputs; ++i, ++counter) {
            CMutableTransaction plain;
            plain.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(2)}, static_cast<uint32_t>(counter)});
            plain.nLockTime = static_cast<uint32_t>(counter);
            plain.vout.emplace_back(value_of(counter), out.script);
            add(plain, block_of(counter), false, /*live=*/true);
        }
        if (writes) BOOST_REQUIRE(writes->Commit());
    }

    // The chainstate holds exactly the live outputs, all on disk (flushed out
    // of the cache), so a lookup is a database read.
    {
        LOCK(::cs_main);
        CCoinsViewCache& tip = setup.m_node.chainman->ActiveChainstate().CoinsTip();
        for (auto& [outpoint, coin] : coins) tip.AddCoin(outpoint, std::move(coin), /*possible_overwrite=*/false);
        BOOST_REQUIRE(tip.Flush());
    }
    BOOST_REQUIRE_EQUAL(out.live.size(), size.live_outputs);
    return out;
}

} // namespace test
} // namespace wallet

#endif // BITCOIN_WALLET_TEST_LARGE_WALLET_FIXTURE_H
