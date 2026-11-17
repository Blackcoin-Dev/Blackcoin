// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <key.h>
#include <primitives/transaction.h>
#include <script/script.h>
#include <script/solver.h>
#include <shadow.h>
#include <test/util/setup_common.h>
#include <util/string.h>
#include <wallet/shadow_pow_claim_recovery_types.h>
#include <wallet/test/util.h>
#include <wallet/transaction.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

#include <map>
#include <memory>
#include <set>
#include <vector>

#ifdef __APPLE__
#include <malloc/malloc.h>
#endif

namespace wallet {
namespace {

CTransactionRef MakeClaim(const std::vector<COutPoint>& inputs, uint32_t salt)
{
    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0, 0});
    CMutableTransaction claim;
    for (const COutPoint& input : inputs) claim.vin.emplace_back(input);
    claim.vout.emplace_back(COIN + salt, CScript{} << OP_TRUE);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    CTransactionRef ref = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*ref));
    return ref;
}

//! The metadata the miner and CommitTransaction give an authored claim.
void SetAuthoredMetadata(CWalletTx& wtx, int64_t relay_birth)
{
    wtx.mapValue["comment"] = "PoW Claim";
    wtx.mapValue[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
    wtx.mapValue[SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] = "321";
    wtx.mapValue[SHADOW_POW_CLAIM_CREATED_TIP_KEY] = uint256{42}.GetHex();
    wtx.mapValue[SHADOW_POW_CLAIM_RELAY_CLOCK_SCHEMA_KEY] = SHADOW_POW_CLAIM_RELAY_CLOCK_SCHEMA_VERSION;
    wtx.mapValue[SHADOW_POW_CLAIM_RELAY_BIRTH_KEY] = ToString(relay_birth);
    wtx.mapValue[SHADOW_POW_CLAIM_RELAY_TXID_KEY] = wtx.GetHash().GetHex();
    wtx.fFromMe = true;
}

void CheckConsistent(const CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    std::string failure;
    BOOST_CHECK_MESSAGE(wallet.CheckShadowPowClaimIndexConsistencyLocked(&failure), failure);
    BOOST_CHECK(wallet.CheckShadowPowNonConfirmedProofIndexLocked());
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(shadow_pow_claim_index_tests, BasicTestingSetup)

// The proof and local-claim memberships, the relay-frontier reverse index and
// the anchor references used to be txid-keyed containers. They are now bits
// and a field on the wallet's record. Their observable answers must follow
// the same events: insertion, metadata change, state change, a full rebuild,
// and removal.
BOOST_AUTO_TEST_CASE(per_record_index_follows_the_record)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    {
        LOCK(wallet.cs_wallet);
        wallet.SetLastBlockProcessed(321, uint256{42});
        wallet.SetupLegacyScriptPubKeyMan();
        BOOST_REQUIRE(wallet.GetOrCreateLegacyScriptPubKeyMan()->AddKeyPubKey(wallet_key, wallet_key.GetPubKey()));
    }
    CMutableTransaction funding;
    for (int i{0}; i < 5; ++i) funding.vout.emplace_back(2 * COIN + i, GetScriptForRawPubKey(wallet_key.GetPubKey()));
    const CTransactionRef funding_ref = MakeTransactionRef(std::move(funding));
    const uint256 funding_txid = funding_ref->GetHash();
    BOOST_REQUIRE(wallet.AddToWallet(funding_ref, TxStateInactive{}));
    const auto anchor = [&](uint32_t n) { return COutPoint{Txid::FromUint256(funding_txid), n}; };

    // A spends anchor 0. B spends anchors 1 and 2 and names anchor 1 twice.
    // C is a sibling of A on anchor 0. D is a proof record with no metadata.
    const CTransactionRef a = MakeClaim({anchor(0)}, 1);
    const CTransactionRef b = MakeClaim({anchor(1), anchor(2), anchor(1)}, 2);
    const CTransactionRef c = MakeClaim({anchor(0)}, 3);
    const CTransactionRef d = MakeClaim({anchor(3)}, 4);
    const auto authored = [](int64_t birth) {
        return [birth](CWalletTx& wtx, bool) { SetAuthoredMetadata(wtx, birth); return true; };
    };
    BOOST_REQUIRE(wallet.AddToWallet(a, TxStateInactive{}, authored(1000)));
    BOOST_REQUIRE(wallet.AddToWallet(b, TxStateInactive{}, authored(2000)));
    BOOST_REQUIRE(wallet.AddToWallet(c, TxStateInactive{}, authored(3000)));
    BOOST_REQUIRE(wallet.AddToWallet(d, TxStateInactive{}));

    const auto check_all_present = [&]() EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet) {
        for (const CTransactionRef& claim : {a, b, c, d}) {
            BOOST_CHECK(wallet.IsIndexedShadowPowClaimLocked(claim->GetHash()));
        }
        BOOST_CHECK(!wallet.IsIndexedShadowPowClaimLocked(funding_txid));
        BOOST_CHECK(!wallet.IsIndexedShadowPowClaimLocked(uint256{99}));
        for (const CTransactionRef& claim : {a, b, c}) {
            BOOST_CHECK(wallet.IsShadowPowLocalClaimIndexedLocked(claim->GetHash()));
            const auto& state = wallet.mapWallet.at(claim->GetHash()).m_shadow_pow_index;
            BOOST_CHECK(state.has_relay_frontier);
            BOOST_CHECK(!state.legacy_relay_frontier);
        }
        // No metadata and not from this wallet: unclassified, so not a local claim.
        BOOST_CHECK(!wallet.IsShadowPowLocalClaimIndexedLocked(d->GetHash()));
        BOOST_CHECK(!wallet.IsShadowPowLocalClaimIndexedLocked(funding_txid));
        BOOST_CHECK(!wallet.IsShadowPowLocalClaimIndexedLocked(uint256{99}));
        BOOST_CHECK_EQUAL(wallet.mapWallet.at(a->GetHash()).m_shadow_pow_relay_frontier.value, 1000 + SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS);
        BOOST_CHECK_EQUAL(wallet.mapWallet.at(b->GetHash()).m_shadow_pow_relay_frontier.value, 2000 + SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS);
        for (uint32_t n{0}; n < 4; ++n) BOOST_CHECK(wallet.IsShadowPowHistoricalAnchorLocked(anchor(n)));
        BOOST_CHECK(!wallet.IsShadowPowHistoricalAnchorLocked(anchor(4)));
        BOOST_CHECK(!wallet.IsShadowPowHistoricalAnchorLocked(COutPoint{a->GetHash(), 0}));
        CheckConsistent(wallet);
    };
    {
        LOCK(wallet.cs_wallet);
        check_all_present();
    }

    // Confirming and unconfirming keeps every membership.
    BOOST_REQUIRE(wallet.AddToWallet(a, TxStateConfirmed{uint256{43}, 322, 1}));
    BOOST_REQUIRE(wallet.AddToWallet(b, TxStateConfirmed{uint256{43}, 322, 2}));
    {
        LOCK(wallet.cs_wallet);
        check_all_present();
    }
    BOOST_REQUIRE(wallet.AddToWallet(b, TxStateInactive{}));

    // A copy of a record carries no index state, and copying onto a record
    // leaves the record's own state alone.
    {
        LOCK(wallet.cs_wallet);
        CWalletTx& live = wallet.mapWallet.at(a->GetHash());
        CWalletTx copy{live.tx, live.m_state};
        copy.CopyFrom(live);
        BOOST_CHECK(!copy.m_shadow_pow_index.proof && !copy.m_shadow_pow_index.claim && !copy.m_shadow_pow_index.has_relay_frontier && !copy.m_shadow_pow_index.proof_inputs_from_vin);
        BOOST_CHECK_EQUAL(copy.m_shadow_pow_relay_frontier.value, 0);
        BOOST_CHECK(copy.mapValue == live.mapValue);
        live.CopyFrom(copy);
        check_all_present();
    }

    // A full rebuild gives the same answers as the incremental updates did.
    {
        LOCK(wallet.cs_wallet);
        wallet.RebuildShadowPowClaimIndexesLocked();
        check_all_present();
        wallet.RebuildShadowPowClaimIndexesLocked();
        check_all_present();
    }

    // Changing the relay clock moves the frontier, and an invalid clock removes it.
    BOOST_REQUIRE(wallet.AddToWallet(c, TxStateInactive{}, [](CWalletTx& wtx, bool) {
        wtx.mapValue[SHADOW_POW_CLAIM_RELAY_BIRTH_KEY] = "3500";
        return true;
    }));
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK_EQUAL(wallet.mapWallet.at(c->GetHash()).m_shadow_pow_relay_frontier.value, 3500 + SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS);
        CheckConsistent(wallet);
    }
    BOOST_REQUIRE(wallet.AddToWallet(c, TxStateInactive{}, [](CWalletTx& wtx, bool) {
        wtx.mapValue[SHADOW_POW_CLAIM_RELAY_BIRTH_KEY] = "03500"; // not canonical: kept verbatim, fails closed
        return true;
    }));
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(wallet.mapWallet.at(c->GetHash()).mapValue.at(SHADOW_POW_CLAIM_RELAY_BIRTH_KEY) == "03500");
        BOOST_CHECK(!wallet.mapWallet.at(c->GetHash()).m_shadow_pow_index.has_relay_frontier);
        BOOST_CHECK(wallet.IsShadowPowLocalClaimIndexedLocked(c->GetHash()));
        CheckConsistent(wallet);
    }

    // Removing records releases exactly their references.
    {
        LOCK(wallet.cs_wallet);
        std::vector<uint256> remove{c->GetHash()};
        std::vector<uint256> removed;
        BOOST_REQUIRE(wallet.ZapSelectTx(remove, removed) == DBErrors::LOAD_OK);
        BOOST_REQUIRE_EQUAL(removed.size(), 1U);
        BOOST_CHECK(!wallet.IsIndexedShadowPowClaimLocked(c->GetHash()));
        BOOST_CHECK(!wallet.IsShadowPowLocalClaimIndexedLocked(c->GetHash()));
        // A still references anchor 0.
        BOOST_CHECK(wallet.IsShadowPowHistoricalAnchorLocked(anchor(0)));
        CheckConsistent(wallet);

        remove = {a->GetHash(), b->GetHash()};
        removed.clear();
        BOOST_REQUIRE(wallet.ZapSelectTx(remove, removed) == DBErrors::LOAD_OK);
        BOOST_REQUIRE_EQUAL(removed.size(), 2U);
        for (uint32_t n{0}; n < 3; ++n) BOOST_CHECK(!wallet.IsShadowPowHistoricalAnchorLocked(anchor(n)));
        BOOST_CHECK(wallet.IsShadowPowHistoricalAnchorLocked(anchor(3)));
        BOOST_CHECK(wallet.IsIndexedShadowPowClaimLocked(d->GetHash()));
        CheckConsistent(wallet);

        wallet.RebuildShadowPowClaimIndexesLocked();
        BOOST_CHECK(wallet.IsShadowPowHistoricalAnchorLocked(anchor(3)));
        for (uint32_t n{0}; n < 3; ++n) BOOST_CHECK(!wallet.IsShadowPowHistoricalAnchorLocked(anchor(n)));
        CheckConsistent(wallet);
    }
}

// Prints what the claim indexes cost per confirmed, self-authored claim.
BOOST_AUTO_TEST_CASE(claim_index_memory_measurement)
{
#ifdef __APPLE__
    constexpr uint32_t CLAIMS{20000};
    const auto heap = [] {
        malloc_statistics_t stats;
        malloc_zone_statistics(nullptr, &stats);
        return std::pair<size_t, size_t>{stats.blocks_in_use, stats.size_in_use};
    };
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    std::vector<CTransactionRef> claims;
    claims.reserve(CLAIMS);
    for (uint32_t i{0}; i < CLAIMS; ++i) {
        claims.push_back(MakeClaim({COutPoint{Txid::FromUint256(uint256{static_cast<uint8_t>(1 + i % 200)}), i}}, i));
    }
    LOCK(wallet.cs_wallet);
    for (uint32_t i{0}; i < CLAIMS; ++i) {
        const auto [it, inserted] = wallet.mapWallet.emplace(std::piecewise_construct, std::forward_as_tuple(claims[i]->GetHash()), std::forward_as_tuple(claims[i], TxStateConfirmed{uint256{7}, static_cast<int>(1000 + i), 1}));
        BOOST_REQUIRE(inserted);
        SetAuthoredMetadata(it->second, 1763000000 + i);
    }
    const auto before = heap();
    wallet.RebuildShadowPowClaimIndexesLocked();
    const auto after = heap();

    // The containers rc12 kept one entry in per confirmed authored claim,
    // with rc12's types, filled the way rc12's index functions filled them.
    struct Rc12PerClaimContainers {
        std::set<uint256> claim_txids;
        std::set<uint256> all_proof_txids;
        std::map<uint256, std::vector<COutPoint>> proof_inputs_by_txid;
        std::map<COutPoint, std::set<uint256>> proof_anchor_txids;
        std::set<std::pair<int64_t, uint256>> schema_relay_frontiers;
        std::map<uint256, std::pair<bool, int64_t>> relay_frontier_by_txid;
    };
    const auto rc12_before = heap();
    auto rc12 = std::make_unique<Rc12PerClaimContainers>();
    for (uint32_t i{0}; i < CLAIMS; ++i) {
        const uint256 txid{claims[i]->GetHash()};
        rc12->all_proof_txids.insert(txid);
        std::vector<COutPoint> inputs;
        inputs.reserve(claims[i]->vin.size());
        for (const CTxIn& input : claims[i]->vin) {
            inputs.push_back(input.prevout);
            rc12->proof_anchor_txids[input.prevout].insert(txid);
        }
        rc12->proof_inputs_by_txid.emplace(txid, std::move(inputs));
        const int64_t frontier{1763000000 + i + SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS};
        rc12->schema_relay_frontiers.emplace(frontier, txid);
        rc12->relay_frontier_by_txid.emplace(txid, std::pair{false, frontier});
        rc12->claim_txids.insert(txid);
    }
    const auto rc12_after = heap();
    BOOST_TEST_MESSAGE(strprintf(
        "claim indexes per confirmed authored claim (%u claims): rc12 containers %.0f heap bytes in %.1f allocations; "
        "now %.0f heap bytes in %.1f allocations plus %u bytes in the record; sizeof(CWalletTx) = %u",
        CLAIMS, double(rc12_after.second - rc12_before.second) / CLAIMS, double(rc12_after.first - rc12_before.first) / CLAIMS,
        double(after.second - before.second) / CLAIMS, double(after.first - before.first) / CLAIMS,
        unsigned(sizeof(CWalletTx::ShadowPowIndexState) + sizeof(CWalletTx::ShadowPowRelayFrontier)), unsigned(sizeof(CWalletTx))));
    BOOST_CHECK((after.second - before.second) * 2 < rc12_after.second - rc12_before.second);

    // Not folded: the reverse map from a payout to its block (see the report
    // for why). Its cost per confirmed synthetic payout, for reference.
    const auto payout_before = heap();
    auto block_by_txid = std::make_unique<std::map<uint256, uint256>>();
    for (uint32_t i{0}; i < CLAIMS; ++i) block_by_txid->emplace(claims[i]->GetHash(), uint256{7});
    const auto payout_after = heap();
    BOOST_TEST_MESSAGE(strprintf("m_confirmed_synthetic_payout_block_by_txid: %.0f heap bytes in %.1f allocations per payout (kept)",
                                 double(payout_after.second - payout_before.second) / CLAIMS, double(payout_after.first - payout_before.first) / CLAIMS));
    std::string failure;
    BOOST_CHECK_MESSAGE(wallet.CheckShadowPowClaimIndexConsistencyLocked(&failure), failure);
    BOOST_CHECK(wallet.IsIndexedShadowPowClaimLocked(claims[CLAIMS / 2]->GetHash()));
    BOOST_CHECK(wallet.IsShadowPowLocalClaimIndexedLocked(claims[CLAIMS / 2]->GetHash()));
#else
    BOOST_TEST_MESSAGE("heap measurement uses malloc_zone_statistics and runs on macOS only");
#endif
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
