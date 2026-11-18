// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

// AvailableCoins looks each output script up once per call. The result must
// be exactly what a lookup per output gives, which is what these tests
// compute independently, output by output.

#include <addresstype.h>
#include <key.h>
#include <script/script.h>
#include <script/signingprovider.h>
#include <script/solver.h>
#include <test/util/setup_common.h>
#include <util/io_counters.h>
#include <validation.h>
#include <wallet/coincontrol.h>
#include <wallet/spend.h>
#include <wallet/test/util.h>
#include <wallet/transaction.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <map>
#include <memory>
#include <vector>

namespace wallet {
BOOST_AUTO_TEST_SUITE(available_coins_memo_tests)

namespace {

struct MemoSetup : public TestChain100Setup {
    std::unique_ptr<CWallet> wallet;
    std::vector<CScript> scripts; //!< what the outputs pay to
    size_t foreign_outputs{0};
    std::set<COutPoint> added;

    explicit MemoSetup(size_t per_script)
    {
        wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain()), coinbaseKey);
        const CPubKey pubkey = coinbaseKey.GetPubKey();
        CKey other;
        other.MakeNewKey(/*fCompressed=*/true);
        const CScript p2wpkh = GetScriptForDestination(WitnessV0KeyHash(pubkey));
        const std::vector<CScript> mine{
            GetScriptForRawPubKey(pubkey),
            GetScriptForDestination(PKHash(pubkey)),
            p2wpkh,
            GetScriptForDestination(ScriptHash(p2wpkh)),
        };
        const CScript foreign = GetScriptForDestination(PKHash(other.GetPubKey()));
        scripts = mine;
        scripts.push_back(foreign);

        std::vector<uint256> hashes;
        int tip_height;
        {
            LOCK(::cs_main);
            tip_height = m_node.chainman->ActiveChain().Height();
            for (int h = 0; h <= tip_height; ++h) hashes.push_back(m_node.chainman->ActiveChain()[h]->GetBlockHash());
        }
        LOCK(wallet->cs_wallet);
        uint32_t counter{0};
        for (size_t n = 0; n < per_script; ++n) {
            for (size_t s = 0; s < scripts.size(); ++s, ++counter) {
                CMutableTransaction tx;
                tx.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(9)}, counter});
                tx.nLockTime = counter;
                tx.vout.emplace_back(COIN / 10 + counter, scripts[s]);
                const CTransactionRef ref = MakeTransactionRef(tx);
                const int height = 1 + static_cast<int>(counter % 80);
                BOOST_REQUIRE(wallet->AddToWallet(ref, TxStateConfirmed{hashes[height], height, static_cast<int>(counter)}));
                added.insert(COutPoint{ref->GetHash(), 0});
                foreign_outputs += s == mine.size();
            }
        }
    }
};

struct Expected {
    isminetype mine;
    int input_bytes;
    bool solvable;
    bool spendable;
    OutputType type;
};

//! What a lookup of this one output gives, with no memo.
Expected Lookup(const CWallet& wallet, const CTxOut& out, const CCoinControl* control) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    Expected e{};
    e.mine = wallet.IsMine(out);
    const std::unique_ptr<SigningProvider> provider = wallet.GetSolvingProvider(out.scriptPubKey);
    e.input_bytes = CalculateMaximumSignedInputSize(out, COutPoint(), provider.get(), wallet.CanGrindR(), control);
    e.solvable = e.input_bytes > -1;
    e.spendable = ((e.mine & ISMINE_SPENDABLE) != ISMINE_NO) ||
                  (((e.mine & ISMINE_WATCH_ONLY) != ISMINE_NO) && control && control->fAllowWatchOnly && e.solvable);
    std::vector<std::vector<unsigned char>> solutions;
    TxoutType type = Solver(out.scriptPubKey, solutions);
    bool from_p2sh{false};
    if (type == TxoutType::SCRIPTHASH && e.solvable) {
        CScript redeem;
        BOOST_REQUIRE(provider->GetCScript(CScriptID(uint160(solutions[0])), redeem));
        type = Solver(redeem, solutions);
        from_p2sh = true;
    }
    switch (type) {
    case TxoutType::WITNESS_V1_TAPROOT: e.type = OutputType::BECH32M; break;
    case TxoutType::WITNESS_V0_KEYHASH:
    case TxoutType::WITNESS_V0_SCRIPTHASH: e.type = from_p2sh ? OutputType::P2SH_SEGWIT : OutputType::BECH32; break;
    case TxoutType::SCRIPTHASH:
    case TxoutType::PUBKEYHASH: e.type = OutputType::LEGACY; break;
    default: e.type = OutputType::UNKNOWN;
    }
    return e;
}

void CheckAgainstLookups(const CWallet& wallet, const CoinsResult& result, const CCoinControl* control, const std::set<COutPoint>& added, size_t expected_added)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    size_t seen_added{0};
    size_t total{0};
    for (const auto& [type, outputs] : result.coins) {
        for (const COutput& coin : outputs) {
            ++total;
            const Expected e = Lookup(wallet, coin.txout, control);
            BOOST_CHECK(e.mine != ISMINE_NO);
            BOOST_CHECK_EQUAL(coin.input_bytes, e.input_bytes);
            BOOST_CHECK_EQUAL(coin.solvable, e.solvable);
            BOOST_CHECK_EQUAL(coin.spendable, e.spendable);
            BOOST_CHECK(type == e.type);
            seen_added += added.count(coin.outpoint);
        }
    }
    BOOST_CHECK_EQUAL(total, result.Size());
    BOOST_CHECK_EQUAL(seen_added, expected_added);
}

//! Every field two results could differ in, in a canonical order.
std::vector<std::tuple<COutPoint, int, int, bool, bool, CAmount, OutputType>> Flatten(const CoinsResult& result)
{
    std::vector<std::tuple<COutPoint, int, int, bool, bool, CAmount, OutputType>> rows;
    for (const auto& [type, outputs] : result.coins) {
        for (const COutput& c : outputs) rows.emplace_back(c.outpoint, c.depth, c.input_bytes, c.spendable, c.solvable, c.txout.nValue, type);
    }
    std::sort(rows.begin(), rows.end());
    return rows;
}

} // namespace

BOOST_AUTO_TEST_CASE(memo_gives_what_a_lookup_per_output_gives)
{
    constexpr size_t PER_SCRIPT{120};
    MemoSetup setup{PER_SCRIPT};
    CWallet& wallet = *setup.wallet;
    LOCK2(::cs_main, wallet.cs_wallet);

    CoinFilterParams params;
    params.include_immature_coinbase = true;
    const CoinsResult plain = AvailableCoins(wallet, /*coinControl=*/nullptr, /*feerate=*/std::nullopt, params);
    // Four of the five scripts are the wallet's; the foreign one is never returned.
    CheckAgainstLookups(wallet, plain, nullptr, setup.added, 4 * PER_SCRIPT);
    // All four script types are present in the result.
    for (const OutputType type : {OutputType::LEGACY, OutputType::BECH32, OutputType::P2SH_SEGWIT, OutputType::UNKNOWN}) {
        BOOST_CHECK_MESSAGE(plain.coins.count(type), "missing output type bucket");
    }

    // Coin control that bypasses the memo for every output gives the coins a lookup per output gives.
    CCoinControl control;
    control.fAllowWatchOnly = true;
    const CoinsResult bypassed = AvailableCoins(wallet, &control, /*feerate=*/std::nullopt, params);
    CheckAgainstLookups(wallet, bypassed, &control, setup.added, 4 * PER_SCRIPT);
    // (Its input sizes may differ from the plain call's: watch-only use assumes the largest signature.)
    BOOST_CHECK_EQUAL(bypassed.Size(), plain.Size());

    // Coin control with a weight override for one outpoint: that output takes
    // the unmemoized path, the others the memo, and the result is unchanged
    // for every output the override does not name.
    CCoinControl weights;
    const COutPoint overridden = *setup.added.begin();
    weights.SetInputWeight(overridden, 1000);
    const CoinsResult mixed = AvailableCoins(wallet, &weights, /*feerate=*/std::nullopt, params);
    BOOST_CHECK(Flatten(mixed) == Flatten(plain));

    // A feerate adds the bump fee and nothing else about which coins come back.
    const CoinsResult with_feerate = AvailableCoins(wallet, nullptr, CFeeRate{1000}, params);
    BOOST_CHECK_EQUAL(with_feerate.Size(), plain.Size());

    // Limits behave as before: a count cap and a minimum-sum stop.
    CoinFilterParams limited = params;
    limited.max_count = 25;
    BOOST_CHECK_EQUAL(AvailableCoins(wallet, nullptr, std::nullopt, limited).Size(), 25U);
}

BOOST_AUTO_TEST_CASE(memo_is_per_call_and_sees_wallet_changes)
{
    MemoSetup setup{10};
    CWallet& wallet = *setup.wallet;
    LOCK2(::cs_main, wallet.cs_wallet);
    CoinFilterParams params;
    params.include_immature_coinbase = true;
    const size_t before = AvailableCoins(wallet, nullptr, std::nullopt, params).Size();
    // Lock one output: the next call leaves it out. Nothing is remembered between calls.
    const COutPoint locked = *setup.added.begin();
    // (the first added output pays the P2PK script the wallet owns)
    BOOST_REQUIRE(wallet.LockCoin(locked));
    const CoinsResult after = AvailableCoins(wallet, nullptr, std::nullopt, params);
    BOOST_CHECK_EQUAL(after.Size(), before - 1);
    wallet.UnlockCoin(locked);
    BOOST_CHECK_EQUAL(AvailableCoins(wallet, nullptr, std::nullopt, params).Size(), before);
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
