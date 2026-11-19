// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chain.h>
#include <chainparams.h>
#include <coins.h>
#include <consensus/validation.h>
#include <key.h>
#include <pos.h>
#include <script/solver.h>
#include <shadow.h>
#include <test/util/random.h>
#include <test/util/setup_common.h>
#include <tinyformat.h>
#include <validation.h>
#include <wallet/coincontrol.h>
#include <wallet/staking.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <algorithm>
#include <chrono>
#include <hash.h>
#include <random.h>
#include <wallet/walletdb.h>
#include <set>
#include <string>

#include <boost/test/unit_test.hpp>

namespace wallet {

BOOST_AUTO_TEST_SUITE(payout_digest_tests)

namespace {
// The release up to rc11 hashed the records sorted by txid; reproduced here independently.
std::pair<uint32_t, uint256> OldReleaseDigest(std::vector<SyntheticPayoutRef> refs, int max_height)
{
    refs.erase(std::remove_if(refs.begin(), refs.end(), [&](const SyntheticPayoutRef& r) { return r.height < 0 || r.height > max_height; }), refs.end());
    std::sort(refs.begin(), refs.end(), [](const auto& a, const auto& b) { return a.txid < b.txid; });
    HashWriter hasher{};
    for (const auto& r : refs) hasher << r.txid << r.block_hash << r.stale;
    return {static_cast<uint32_t>(refs.size()), hasher.GetHash()};
}
} // namespace

BOOST_AUTO_TEST_CASE(incremental_digest_equals_full_recompute_after_random_changes)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);

    FastRandomContext rng{/*fDeterministic=*/true};
    std::vector<CTransactionRef> records;
    auto make_record = [&](size_t i) {
        CMutableTransaction tx;
        tx.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(i % 200 + 1)}, static_cast<uint32_t>(i)});
        tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
        return MakeTransactionRef(std::move(tx));
    };
    auto mark = [](TxState state) {
        return [state](CWalletTx& wtx, bool) {
            wtx.mapValue["qq_synthetic_goldrush_payout"] = "1";
            wtx.m_state = state;
            return true;
        };
    };
    auto check = [&] {
        LOCK(wallet.cs_wallet);
        for (const int height : {-1, 0, 3, 17, 40, 41, 1000}) {
            BOOST_CHECK(wallet.GetSyntheticPayoutDigestLocked(height) ==
                        wallet.RecomputeSyntheticPayoutDigestLocked(height, SyntheticPayoutCheckpoint::CURRENT_SCHEMA));
        }
    };
    for (size_t i = 0; i < 400; ++i) {
        const uint64_t op = rng.randrange(10);
        if (records.empty() || op < 5) {
            records.push_back(make_record(records.size()));
            const int height = 1 + static_cast<int>(rng.randrange(40));
            const TxState state = TxStateConfirmed{uint256{static_cast<uint8_t>(height)}, height, 0};
            BOOST_REQUIRE(wallet.AddToWallet(records.back(), state, mark(state)));
        } else if (op < 8) { // reorg: the record leaves its block
            const auto& tx = records[rng.randrange(records.size())];
            const TxState state = TxStateInactive{};
            BOOST_REQUIRE(wallet.AddToWallet(tx, state, mark(state)));
        } else { // reconfirm on a different block and height
            const auto& tx = records[rng.randrange(records.size())];
            const int height = 1 + static_cast<int>(rng.randrange(40));
            const TxState state = TxStateConfirmed{uint256{static_cast<uint8_t>(100 + height)}, height, 0};
            BOOST_REQUIRE(wallet.AddToWallet(tx, state, mark(state)));
        }
        check();
    }
    // Removal.
    std::vector<uint256> txids;
    for (const auto& tx : records) txids.push_back(tx->GetHash());
    {
        LOCK(wallet.cs_wallet);
        std::vector<uint256> erased;
        BOOST_REQUIRE_EQUAL(wallet.ZapSelectTx(txids, erased), DBErrors::LOAD_OK);
    }
    check();
    LOCK(wallet.cs_wallet);
    BOOST_CHECK_EQUAL(wallet.GetSyntheticPayoutDigestLocked(1000).first, 0U);
}

BOOST_AUTO_TEST_CASE(clearing_the_stale_mark_of_a_reconfirmed_payout_updates_the_digest)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    CMutableTransaction tx;
    tx.vin.emplace_back(COutPoint{uint256{9}, 0});
    tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    const CTransactionRef record = MakeTransactionRef(std::move(tx));
    // A deactivated payout record carries the stale mark and is not confirmed.
    BOOST_REQUIRE(wallet.AddToWallet(record, TxStateInactive{}, [](CWalletTx& wtx, bool) {
        wtx.mapValue["qq_synthetic_goldrush_payout"] = "1";
        wtx.mapValue["qq_synthetic_goldrush_payout_stale"] = "1";
        return true;
    }));
    // Its block connects again: the record is confirmed with the mark still on it...
    const uint256 block{7};
    BOOST_REQUIRE(wallet.AddToWallet(record, TxStateConfirmed{block, 5, 0}));
    // ...and the block's annotation clears the mark.
    ShadowSyntheticPayoutTransaction payout;
    payout.tx = record;
    payout.target = CScript{} << OP_TRUE;
    payout.amount = COIN;
    {
        LOCK(wallet.cs_wallet);
        WalletBatch batch(wallet.GetDatabase());
        AnnotateWalletShadowPayout(wallet, payout, batch);
        BOOST_CHECK(wallet.mapWallet.at(record->GetHash()).mapValue.count("qq_synthetic_goldrush_payout_stale") == 0);
        for (const int height : {-1, 4, 5, 1000}) {
            BOOST_CHECK(wallet.GetSyntheticPayoutDigestLocked(height) ==
                        wallet.RecomputeSyntheticPayoutDigestLocked(height, SyntheticPayoutCheckpoint::CURRENT_SCHEMA));
        }
        BOOST_CHECK_EQUAL(wallet.GetSyntheticPayoutDigestLocked(1000).first, 1U);
    }
}

BOOST_AUTO_TEST_CASE(checkpoint_written_by_the_previous_release_is_recognised)
{
    std::vector<SyntheticPayoutRef> refs;
    for (uint8_t i = 1; i <= 50; ++i) refs.push_back(SyntheticPayoutRef{uint256{i}, uint256{static_cast<uint8_t>(100 + i)}, i, i % 7 == 0});
    for (const uint32_t schema : {SyntheticPayoutCheckpoint::LEGACY_SCHEMA, SyntheticPayoutCheckpoint::CURRENT_SCHEMA}) {
        SyntheticPayoutCheckpoint checkpoint;
        checkpoint.schema = schema;
        checkpoint.client_version = CLIENT_VERSION;
        checkpoint.height = 30;
        const auto [count, digest] = schema == SyntheticPayoutCheckpoint::LEGACY_SCHEMA
            ? OldReleaseDigest(refs, 30) : SyntheticPayoutDigest::Compute(refs, 30);
        checkpoint.count = count;
        checkpoint.digest = digest;
        BOOST_CHECK(SyntheticPayoutCheckpointMatches(checkpoint, refs));
        // Any change to a record, in either form, is a mismatch.
        auto changed = refs;
        changed[3].stale = !changed[3].stale;
        BOOST_CHECK(!SyntheticPayoutCheckpointMatches(checkpoint, changed));
        changed = refs;
        changed.erase(changed.begin() + 10);
        BOOST_CHECK(!SyntheticPayoutCheckpointMatches(checkpoint, changed));
        changed = refs;
        changed[40].block_hash = uint256{200}; // above the checkpoint height: not covered
        BOOST_CHECK(SyntheticPayoutCheckpointMatches(checkpoint, changed));
        checkpoint.schema = 3;
        BOOST_CHECK(!SyntheticPayoutCheckpointMatches(checkpoint, refs));
    }
}

namespace {
SyntheticPayoutCheckpoint CheckpointAt(const std::vector<SyntheticPayoutRef>& refs, int height, uint8_t block)
{
    SyntheticPayoutCheckpoint checkpoint;
    checkpoint.schema = SyntheticPayoutCheckpoint::CURRENT_SCHEMA;
    checkpoint.client_version = CLIENT_VERSION;
    checkpoint.height = height;
    checkpoint.block_hash = uint256{block};
    const auto [count, digest] = SyntheticPayoutDigest::Compute(refs, height);
    checkpoint.count = count;
    checkpoint.digest = digest;
    return checkpoint;
}
} // namespace

BOOST_AUTO_TEST_CASE(highest_usable_checkpoint_is_selected)
{
    // Fifty payout records, one per block, at heights 1 to 50.
    std::vector<SyntheticPayoutRef> refs;
    for (uint8_t i = 1; i <= 50; ++i) refs.push_back(SyntheticPayoutRef{uint256{i}, uint256{static_cast<uint8_t>(100 + i)}, i, i % 7 == 0});
    using Verdict = SyntheticPayoutCheckpointVerdict;
    const auto all_active = [](const SyntheticPayoutCheckpoint&) { return Verdict::ACCEPTED; };
    const auto none_active = [](const SyntheticPayoutCheckpoint&) { return Verdict::BLOCK_NOT_ACTIVE; };

    // The wallet's own checkpoint (first) and the flush-anchored one, as LoadWallet passes them.
    const SyntheticPayoutCheckpoint own{CheckpointAt(refs, 50, 150)};
    const SyntheticPayoutCheckpoint flushed{CheckpointAt(refs, 40, 140)};

    BOOST_CHECK(!SelectSyntheticPayoutCheckpoint({}, refs, all_active));

    // A clean stop: both are usable and the higher one wins, in either order.
    BOOST_CHECK(SelectSyntheticPayoutCheckpoint({own, flushed}, refs, all_active) == std::optional<size_t>{0});
    BOOST_CHECK(SelectSyntheticPayoutCheckpoint({flushed, own}, refs, all_active) == std::optional<size_t>{1});
    // Equal heights: the first.
    BOOST_CHECK(SelectSyntheticPayoutCheckpoint({own, own}, refs, all_active) == std::optional<size_t>{0});
    // One record alone, as a wallet of an earlier release has it.
    BOOST_CHECK(SelectSyntheticPayoutCheckpoint({own}, refs, all_active) == std::optional<size_t>{0});
    BOOST_CHECK(SelectSyntheticPayoutCheckpoint({flushed}, refs, all_active) == std::optional<size_t>{0});

    // After a crash the chain restarted at height 40: the blocks above it are not on the
    // active chain, so their records carry no height and the wallet's own checkpoint block
    // is not active. The flush-anchored checkpoint is skipped to, and matches.
    auto restarted = refs;
    for (SyntheticPayoutRef& ref : restarted) {
        if (ref.height > 40) ref.height = -1;
    }
    const auto active_through_40 = [](const SyntheticPayoutCheckpoint& checkpoint) {
        return checkpoint.height <= 40 ? Verdict::ACCEPTED : Verdict::BLOCK_NOT_IN_INDEX;
    };
    BOOST_CHECK(SelectSyntheticPayoutCheckpoint({own, flushed}, restarted, active_through_40) == std::optional<size_t>{1});
    // Accepting the wallet's own checkpoint there merely because of its hash would not help:
    // it does not describe the records that are on the restarted chain.
    BOOST_CHECK(!SyntheticPayoutCheckpointMatches(own, restarted));
    BOOST_CHECK(!SelectSyntheticPayoutCheckpoint({own}, restarted, active_through_40));

    // A reorg across both: no block is active, nothing is usable.
    BOOST_CHECK(!SelectSyntheticPayoutCheckpoint({own, flushed}, refs, none_active));
    // The callback decides for each checkpoint separately.
    size_t asked{0};
    BOOST_CHECK(SelectSyntheticPayoutCheckpoint({own, flushed}, refs, [&](const SyntheticPayoutCheckpoint& checkpoint) {
        ++asked;
        return checkpoint.block_hash == flushed.block_hash ? Verdict::ACCEPTED : Verdict::BLOCK_NOT_ACTIVE;
    }) == std::optional<size_t>{1});
    BOOST_CHECK_EQUAL(asked, 2U);

    // A digest or count that does not match rejects that checkpoint only.
    {
        SyntheticPayoutCheckpoint bad_digest{own};
        bad_digest.digest = uint256{9};
        BOOST_CHECK(SelectSyntheticPayoutCheckpoint({bad_digest, flushed}, refs, all_active) == std::optional<size_t>{1});
        SyntheticPayoutCheckpoint bad_count{flushed};
        ++bad_count.count;
        BOOST_CHECK(SelectSyntheticPayoutCheckpoint({own, bad_count}, refs, all_active) == std::optional<size_t>{0});
        BOOST_CHECK(!SelectSyntheticPayoutCheckpoint({bad_digest, bad_count}, refs, all_active));
    }
    // A record changed at or below the flush-anchored checkpoint rejects both; one changed
    // between the two rejects only the higher.
    {
        auto changed = refs;
        changed[9].stale = !changed[9].stale; // height 10
        BOOST_CHECK(!SelectSyntheticPayoutCheckpoint({own, flushed}, changed, all_active));
        changed = refs;
        changed[44].stale = !changed[44].stale; // height 45
        BOOST_CHECK(SelectSyntheticPayoutCheckpoint({own, flushed}, changed, all_active) == std::optional<size_t>{1});
        // A record added below the checkpoint (a rescan found an older payout).
        changed = refs;
        changed.push_back(SyntheticPayoutRef{uint256{77}, uint256{105}, 5, false});
        BOOST_CHECK(!SelectSyntheticPayoutCheckpoint({own, flushed}, changed, all_active));
    }
    // Another client version, an unknown schema or a negative height is never usable,
    // and never asks about the chain.
    {
        const auto must_not_ask = [](const SyntheticPayoutCheckpoint&) {
            BOOST_ERROR("an unusable checkpoint must not reach the chain lookup");
            return Verdict::ACCEPTED;
        };
        SyntheticPayoutCheckpoint other_version{own};
        other_version.client_version = CLIENT_VERSION + 1;
        SyntheticPayoutCheckpoint other_schema{own};
        other_schema.schema = 3;
        SyntheticPayoutCheckpoint no_height{own};
        no_height.height = -1;
        BOOST_CHECK(!SelectSyntheticPayoutCheckpoint({other_version, other_schema, no_height}, refs, must_not_ask));
        BOOST_CHECK(SelectSyntheticPayoutCheckpoint({other_version, flushed}, refs, all_active) == std::optional<size_t>{1});
    }
}

BOOST_AUTO_TEST_CASE(every_checkpoint_gets_a_verdict_with_its_reason)
{
    using Verdict = SyntheticPayoutCheckpointVerdict;
    std::vector<SyntheticPayoutRef> refs;
    for (uint8_t i = 1; i <= 50; ++i) refs.push_back(SyntheticPayoutRef{uint256{i}, uint256{static_cast<uint8_t>(100 + i)}, i, false});
    const auto all_active = [](const SyntheticPayoutCheckpoint&) { return Verdict::ACCEPTED; };
    const SyntheticPayoutCheckpoint own{CheckpointAt(refs, 50, 150)};
    const SyntheticPayoutCheckpoint flushed{CheckpointAt(refs, 40, 140)};

    const auto verdict = [&](const SyntheticPayoutCheckpoint& checkpoint, const std::vector<SyntheticPayoutRef>& records, Verdict block = Verdict::ACCEPTED) {
        const SyntheticPayoutCheckpointResult result{CheckSyntheticPayoutCheckpoint(checkpoint, records, [block](const SyntheticPayoutCheckpoint&) { return block; })};
        // Every verdict has a description that names the checkpoint height and its count.
        const std::string text{DescribeSyntheticPayoutCheckpointResult(checkpoint, result)};
        BOOST_CHECK_MESSAGE(text.find(strprintf("height %d, %u payout records: ", checkpoint.height, checkpoint.count)) == 0, text);
        BOOST_CHECK_MESSAGE((text.find(": accepted") != std::string::npos) == (result.verdict == Verdict::ACCEPTED), text);
        BOOST_CHECK_MESSAGE((text.find(": rejected, ") != std::string::npos) == (result.verdict != Verdict::ACCEPTED), text);
        return result;
    };
    BOOST_CHECK(verdict(own, refs).verdict == Verdict::ACCEPTED);
    BOOST_CHECK_EQUAL(verdict(own, refs).records_found, 50U);
    BOOST_CHECK(verdict(own, refs, Verdict::BLOCK_NOT_IN_INDEX).verdict == Verdict::BLOCK_NOT_IN_INDEX);
    BOOST_CHECK(verdict(own, refs, Verdict::BLOCK_NOT_ACTIVE).verdict == Verdict::BLOCK_NOT_ACTIVE);
    SyntheticPayoutCheckpoint changed{own};
    changed.schema = 3;
    BOOST_CHECK(verdict(changed, refs).verdict == Verdict::UNKNOWN_SCHEMA);
    changed = own;
    changed.client_version = CLIENT_VERSION - 1;
    BOOST_CHECK(verdict(changed, refs).verdict == Verdict::OTHER_CLIENT_VERSION);
    changed = own;
    changed.height = -1;
    BOOST_CHECK(verdict(changed, refs).verdict == Verdict::NO_HEIGHT);
    changed = own;
    changed.digest = uint256{9};
    BOOST_CHECK(verdict(changed, refs).verdict == Verdict::DIGEST_MISMATCH);
    // A record that left the active chain is a count mismatch, and the count found is reported.
    auto fewer = refs;
    fewer[4].height = -1;
    BOOST_CHECK(verdict(own, fewer).verdict == Verdict::COUNT_MISMATCH);
    BOOST_CHECK_EQUAL(verdict(own, fewer).records_found, 49U);
    BOOST_CHECK(DescribeSyntheticPayoutCheckpointResult(own, verdict(own, fewer)).find("the wallet holds 49 payout records") != std::string::npos);

    // The selection reports every checkpoint, in the order given, also one below the accepted one.
    std::vector<SyntheticPayoutCheckpointResult> results;
    BOOST_CHECK(SelectSyntheticPayoutCheckpoint({own, flushed}, refs, all_active, &results) == std::optional<size_t>{0});
    BOOST_REQUIRE_EQUAL(results.size(), 2U);
    BOOST_CHECK(results[0].verdict == Verdict::ACCEPTED && results[1].verdict == Verdict::ACCEPTED);
    BOOST_CHECK_EQUAL(results[1].records_found, 40U);
    BOOST_CHECK(!SelectSyntheticPayoutCheckpoint({own, flushed}, fewer, all_active, &results));
    BOOST_REQUIRE_EQUAL(results.size(), 2U);
    BOOST_CHECK(results[0].verdict == Verdict::COUNT_MISMATCH && results[1].verdict == Verdict::COUNT_MISMATCH);
    BOOST_CHECK(!SelectSyntheticPayoutCheckpoint({}, refs, all_active, &results));
    BOOST_CHECK(results.empty());
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
