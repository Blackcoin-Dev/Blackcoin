// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <hash.h>
#include <interfaces/chain.h>
#include <key.h>
#include <primitives/block.h>
#include <primitives/transaction.h>
#include <script/script.h>
#include <script/solver.h>
#include <shadow.h>
#include <test/util/setup_common.h>
#include <util/string.h>
#include <util/time.h>
#include <wallet/receive.h>
#include <wallet/shadow_pow_claim_recovery_types.h>
#include <wallet/sqlite.h>
#include <wallet/test/util.h>
#include <wallet/transaction.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>

#include <boost/test/unit_test.hpp>

#include <chrono>
#include <cstdlib>
#include <memory>
#include <set>
#include <vector>

#include <sqlite3.h>

namespace wallet {

struct WalletReorgTestAccess {
    static void RecomputeStakeIndex(CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
    {
        wallet.RecomputeLiveUnspentStakeOutpoints();
    }
    static std::set<COutPoint> LegacyClaimOutpoints(CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
    {
        return wallet.m_live_unspent_legacy_claim_outpoints;
    }
    static const std::set<uint256>& Coinstakes(CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
    {
        return wallet.m_coinstake_txids;
    }
    static const std::set<uint256>& UnconfirmedCoinstakes(CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
    {
        return wallet.m_unconfirmed_coinstake_txids;
    }
    static std::map<std::vector<unsigned char>, int>& RedelegationHistory(CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
    {
        return wallet.m_redelegation_last_win_height;
    }
};

namespace {

uint256 FakeBlockHash(int height)
{
    return (HashWriter{} << std::string{"reorg-scale-block"} << height).GetHash();
}

bool BalancesEqual(const Balance& a, const Balance& b)
{
    return a.m_mine_trusted == b.m_mine_trusted && a.m_mine_untrusted_pending == b.m_mine_untrusted_pending &&
           a.m_mine_immature == b.m_mine_immature && a.m_mine_stake == b.m_mine_stake &&
           a.m_watchonly_trusted == b.m_watchonly_trusted &&
           a.m_watchonly_untrusted_pending == b.m_watchonly_untrusted_pending &&
           a.m_watchonly_immature == b.m_watchonly_immature && a.m_watchonly_stake == b.m_watchonly_stake;
}

/**
 * A wallet shaped like the large field wallets: per block one Gold Rush PoW
 * claim (each spends the previous claim's output) and one synthetic payout
 * record of that block, plus, for the staking nodes of the fleet, a chain of
 * the wallet's own coinstakes. The newest block holds the newest claim and
 * the newest coinstake. Deep outputs have lifecycle memo entries, as they do
 * after the GUI balance has warmed up.
 */
struct ReorgWallet {
    std::shared_ptr<CWallet> wallet;
    CKey key;
    CScript script;
    int tip_height{0};
    std::vector<CTransactionRef> claims;  // claims[h - 1] is confirmed at height h
    std::vector<CTransactionRef> payouts; // likewise
    std::vector<std::pair<int, CTransactionRef>> stakes; // (height, coinstake)
    //! A coinstake of the wallet on a competing block: it spends the tip coinstake's input and is conflicted by the tip.
    CTransactionRef rival_stake;
    CBlock tip_block;

    static CTransactionRef MakeClaim(const COutPoint& input, const CScript& script, uint32_t salt)
    {
        std::vector<unsigned char> proof = GetShadowPrefix();
        proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0, 0});
        CMutableTransaction claim;
        claim.vin.emplace_back(input);
        claim.vout.emplace_back(COIN, script);
        claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
        claim.nLockTime = salt;
        return MakeTransactionRef(std::move(claim));
    }
    static CTransactionRef MakePayout(const CScript& script, int height)
    {
        CMutableTransaction payout;
        payout.vin.emplace_back(COutPoint{}, CScript{} << height << OP_0);
        payout.vout.emplace_back(5 * COIN, script);
        return MakeTransactionRef(std::move(payout));
    }
    static CTransactionRef MakeStake(const COutPoint& input, const CScript& script)
    {
        CMutableTransaction stake;
        stake.vin.emplace_back(input);
        stake.vout.emplace_back(0, CScript{});
        stake.vout.emplace_back(20 * COIN, script);
        return MakeTransactionRef(std::move(stake));
    }
    static CWallet::UpdateWalletTxFn Authored()
    {
        return [](CWalletTx& wtx, bool) {
            wtx.mapValue["comment"] = "PoW Claim";
            wtx.mapValue[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
            wtx.mapValue[SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] = "321";
            wtx.mapValue[SHADOW_POW_CLAIM_CREATED_TIP_KEY] = uint256{42}.GetHex();
            wtx.mapValue[SHADOW_POW_CLAIM_RELAY_CLOCK_SCHEMA_KEY] = SHADOW_POW_CLAIM_RELAY_CLOCK_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_CLAIM_RELAY_BIRTH_KEY] = "1000";
            wtx.mapValue[SHADOW_POW_CLAIM_RELAY_TXID_KEY] = wtx.GetHash().GetHex();
            wtx.fFromMe = true;
            return true;
        };
    }
    static CWallet::UpdateWalletTxFn Synthetic()
    {
        return [](CWalletTx& wtx, bool) {
            wtx.mapValue["qq_synthetic_goldrush_payout"] = "1";
            return true;
        };
    }

    ReorgWallet(interfaces::Chain& chain, const std::string& name, int blocks, int stake_every)
    {
        DatabaseOptions options;
        options.require_format = DatabaseFormat::SQLITE;
        DatabaseStatus status;
        bilingual_str error;
        auto database{MakeWalletDatabase(name, options, status, error)};
        BOOST_REQUIRE_MESSAGE(database, error.original);
        wallet = std::make_shared<CWallet>(&chain, "", std::move(database));
        BOOST_REQUIRE_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
        key.MakeNewKey(/*fCompressed=*/true);
        script = GetScriptForRawPubKey(key.GetPubKey());
        tip_height = blocks;

        LOCK(wallet->cs_wallet);
        // The tip first: the indexes kept while records are added depend on each record's depth.
        wallet->SetLastBlockProcessed(blocks, FakeBlockHash(blocks));
        wallet->SetupLegacyScriptPubKeyMan();
        BOOST_REQUIRE(wallet->GetOrCreateLegacyScriptPubKeyMan()->AddKeyPubKey(key, key.GetPubKey()));

        // One commit for the whole history instead of one per record.
        std::unique_ptr<DatabaseBulkScope> writes = wallet->GetDatabase().MakeBulkScope();
        CMutableTransaction funding;
        funding.vout.emplace_back(COIN, script);
        funding.vout.emplace_back(20 * COIN, script);
        const CTransactionRef funding_ref = MakeTransactionRef(std::move(funding));
        BOOST_REQUIRE(wallet->AddToWallet(funding_ref, TxStateConfirmed{FakeBlockHash(0), 0, 1}));

        COutPoint claim_input{funding_ref->GetHash(), 0};
        COutPoint stake_input{funding_ref->GetHash(), 1};
        claims.reserve(blocks);
        payouts.reserve(blocks);
        for (int height = 1; height <= blocks; ++height) {
            const uint256 hash = FakeBlockHash(height);
            int position{1};
            if (stake_every > 0 && (height % stake_every == 0 || height == blocks)) {
                const CTransactionRef stake = MakeStake(stake_input, script);
                BOOST_REQUIRE(wallet->AddToWallet(stake, TxStateConfirmed{hash, height, position++}));
                if (height == blocks) {
                    CMutableTransaction rival{*stake};
                    rival.nLockTime = 1;
                    rival_stake = MakeTransactionRef(std::move(rival));
                    BOOST_REQUIRE(wallet->AddToWallet(rival_stake, TxStateConflicted{hash, height}));
                }
                stake_input = COutPoint{stake->GetHash(), 1};
                stakes.emplace_back(height, stake);
            }
            const CTransactionRef claim = MakeClaim(claim_input, script, height);
            BOOST_REQUIRE(wallet->AddToWallet(claim, TxStateConfirmed{hash, height, position++}, Authored()));
            claim_input = COutPoint{claim->GetHash(), 0};
            claims.push_back(claim);
            const CTransactionRef payout = MakePayout(script, height);
            BOOST_REQUIRE(wallet->AddToWallet(payout, TxStateConfirmed{hash, height, position++}, Synthetic()));
            payouts.push_back(payout);
        }
        if (writes) BOOST_REQUIRE(writes->Commit());
        writes.reset();

        // What the warmed-up GUI balance holds: an entry per deep unspent output.
        for (int height = 1; height + 100 <= blocks; ++height) {
            WalletOutputLifecycleMemo memo;
            memo.confirmed_block_hash_prefix = FakeBlockHash(height).GetUint64(0);
            memo.confirmed_block_height = height;
            memo.coin_height = height;
            memo.synthetic = true;
            wallet->StoreOutputLifecycleMemo(COutPoint{payouts[height - 1]->GetHash(), 0}, memo);
        }

        CMutableTransaction coinbase;
        coinbase.vin.emplace_back(COutPoint{}, CScript{} << blocks << OP_1);
        coinbase.vout.emplace_back(COIN, CScript{} << OP_TRUE);
        tip_block.vtx.push_back(MakeTransactionRef(std::move(coinbase)));
        if (!stakes.empty() && stakes.back().first == blocks) tip_block.vtx.push_back(stakes.back().second);
        tip_block.vtx.push_back(claims.back());
        tip_block.nTime = GetTime();
    }

    size_t Records() const { return WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.size()); }

    //! Records whose cached amounts are empty (never computed, or invalidated).
    size_t DirtyRecords() const
    {
        LOCK(wallet->cs_wallet);
        size_t dirty{0};
        for (const auto& [txid, wtx] : wallet->mapWallet) dirty += wtx.m_is_cache_empty ? 1 : 0;
        return dirty;
    }

    std::string Describe(const uint256& txid) const
    {
        if (!claims.empty() && claims.back()->GetHash() == txid) return "tip claim";
        if (claims.size() > 1 && claims[claims.size() - 2]->GetHash() == txid) return "claim below the tip";
        if (!payouts.empty() && payouts.back()->GetHash() == txid) return "tip payout";
        if (!stakes.empty() && stakes.back().second->GetHash() == txid) return "tip stake";
        if (stakes.size() > 1 && stakes[stakes.size() - 2].second->GetHash() == txid) return "stake below the tip";
        return "other";
    }

    sqlite3* RawDb() { return static_cast<SQLiteDatabase&>(wallet->GetDatabase()).m_db; }

    //! Everything a disconnect and a reconnect maintain equals what a rebuild from the records gives.
    void CheckAgainstRebuild(const std::string& when)
    {
        const Balance incremental = GetBalance(*wallet);
        LOCK(wallet->cs_wallet);
        std::string failure;
        BOOST_CHECK_MESSAGE(wallet->CheckShadowPowClaimIndexConsistencyLocked(&failure), when + ": " + failure);
        BOOST_CHECK_MESSAGE(wallet->CheckShadowPowNonConfirmedProofIndexLocked(), when);
        for (const int height : {-1, 0, tip_height - 600, tip_height - 2, tip_height - 1, tip_height, tip_height + 5}) {
            BOOST_CHECK_MESSAGE(wallet->GetSyntheticPayoutDigestLocked(height) ==
                                wallet->RecomputeSyntheticPayoutDigestLocked(height, SyntheticPayoutCheckpoint::CURRENT_SCHEMA),
                                when + ": payout digest at " + ToString(height));
        }
        const std::set<COutPoint> live = wallet->GetLiveUnspentStakeOutpoints();
        const std::set<COutPoint> candidates = wallet->GetLiveUnspentStakeCandidateOutpoints();
        const std::set<COutPoint> legacy = WalletReorgTestAccess::LegacyClaimOutpoints(*wallet);
        WalletReorgTestAccess::RecomputeStakeIndex(*wallet);
        for (const COutPoint& o : live) if (!wallet->GetLiveUnspentStakeOutpoints().count(o)) BOOST_TEST_MESSAGE("only incremental: " << o.ToString() << " " << Describe(o.hash));
        for (const COutPoint& o : wallet->GetLiveUnspentStakeOutpoints()) if (!live.count(o)) BOOST_TEST_MESSAGE("only rebuilt: " << o.ToString() << " " << Describe(o.hash));
        BOOST_CHECK_MESSAGE(live == wallet->GetLiveUnspentStakeOutpoints(), when + ": live stake outpoints");
        BOOST_CHECK_MESSAGE(candidates == wallet->GetLiveUnspentStakeCandidateOutpoints(), when + ": stake candidates");
        BOOST_CHECK_MESSAGE(legacy == WalletReorgTestAccess::LegacyClaimOutpoints(*wallet), when + ": legacy claim outpoints");
        // The index of unconfirmed coinstakes is exact, and the sweep that
        // walked it left nothing a sweep over every coinstake would abandon.
        std::set<uint256> unconfirmed;
        for (const uint256& txid : WalletReorgTestAccess::Coinstakes(*wallet)) {
            const CWalletTx& wtx = wallet->mapWallet.at(txid);
            if (!wtx.isConfirmed()) unconfirmed.insert(txid);
            BOOST_CHECK_MESSAGE(!(wallet->GetTxDepthInMainChain(wtx) == 0 && !wtx.isAbandoned()),
                                when + ": orphaned coinstake left unabandoned " + txid.ToString());
        }
        BOOST_CHECK_MESSAGE(unconfirmed == WalletReorgTestAccess::UnconfirmedCoinstakes(*wallet), when + ": unconfirmed coinstake index");
        // The cached amounts that were kept are still right.
        wallet->MarkDirty();
        BOOST_CHECK_MESSAGE(BalancesEqual(incremental, GetBalance(*wallet)), when + ": balance");
    }
};

struct CommitCounter {
    sqlite3* db;
    int commits{0};
    explicit CommitCounter(sqlite3* db_in) : db{db_in}
    {
        sqlite3_commit_hook(db, [](void* arg) -> int { ++*static_cast<int*>(arg); return 0; }, &commits);
    }
    ~CommitCounter() { sqlite3_commit_hook(db, nullptr, nullptr); }
};

struct ReorgOutcome {
    BlockDisconnectWork work;
    size_t records{0};
    size_t dirtied_by_disconnect{0};
    size_t dirtied_by_connect{0};
    int disconnect_commits{0};
    int connect_commits{0};
    int disconnect_rows{0};
    int connect_rows{0};
    double connect_ms{0};
    uint64_t coinstakes_visited_with_win{0};
    int readd_commits{0}, readd_rows{0}, new_commits{0}, new_rows{0};
    double readd_ms{0}, new_ms{0}, foreign_ms{0};
    size_t dirtied_by_mempool{0};
};

ReorgOutcome DisconnectAndReconnectTip(interfaces::Chain& chain, const std::string& name, int blocks, int stake_every)
{
    ReorgWallet fixture{chain, name, blocks, stake_every};
    CWallet& wallet = *fixture.wallet;
    ReorgOutcome outcome;
    outcome.records = fixture.Records();

    const Balance before = GetBalance(wallet); // fills every record's cached amounts (a conflicted record has none)
    BOOST_CHECK_LE(fixture.DirtyRecords(), 1U);
    BOOST_CHECK_GT(before.m_mine_immature, 0);
    const size_t memo_before = WITH_LOCK(wallet.cs_wallet, return wallet.m_output_lifecycle_memo.size());
    BOOST_CHECK_EQUAL(memo_before, static_cast<size_t>(blocks - 100));

    const uint256 tip_hash = FakeBlockHash(blocks);
    const uint256 prev_hash = FakeBlockHash(blocks - 1);
    interfaces::BlockInfo info{tip_hash};
    info.prev_hash = &prev_hash;
    info.height = blocks;
    info.data = &fixture.tip_block;
    info.chain_time_max = fixture.tip_block.GetBlockTime();

    const CTransactionRef claim = fixture.claims.back();
    const CTransactionRef payout = fixture.payouts.back();
    const CTransactionRef stake = fixture.stakes.empty() ? nullptr : fixture.stakes.back().second;
    const CTransactionRef rival = fixture.rival_stake;
    // Two entries of the redelegation win history that no coinstake of the
    // wallet supports: one names the block about to be disconnected, one an
    // older block. Only a win at the disconnected height makes the disconnect
    // recompute the history (which then drops both).
    const std::vector<unsigned char> win_at_tip(32, 0x51), win_below(32, 0x52);
    {
        LOCK(wallet.cs_wallet);
        if (rival) BOOST_CHECK(wallet.mapWallet.at(rival->GetHash()).isConflicted());
        WalletReorgTestAccess::RedelegationHistory(wallet)[win_below] = blocks - 1;
    }

    {
        CommitCounter counter{fixture.RawDb()};
        const int rows = sqlite3_total_changes(fixture.RawDb());
        wallet.blockDisconnected(info);
        outcome.disconnect_commits = counter.commits;
        outcome.disconnect_rows = sqlite3_total_changes(fixture.RawDb()) - rows;
    }
    outcome.dirtied_by_disconnect = fixture.DirtyRecords();
    {
        LOCK(wallet.cs_wallet);
        outcome.work = wallet.m_last_block_disconnect_work;
        BOOST_CHECK(wallet.mapWallet.at(claim->GetHash()).isInactive());
        BOOST_CHECK(!wallet.mapWallet.at(claim->GetHash()).isAbandoned());
        BOOST_CHECK(wallet.mapWallet.at(payout->GetHash()).isInactive());
        if (stake) BOOST_CHECK(wallet.mapWallet.at(stake->GetHash()).isAbandoned());
        // The competing coinstake is no longer conflicted by a block in the
        // chain; an orphan too, it is abandoned and its input released.
        if (rival) BOOST_CHECK(wallet.mapWallet.at(rival->GetHash()).isAbandoned());
        BOOST_CHECK_EQUAL(WalletReorgTestAccess::RedelegationHistory(wallet).count(win_below), 1U);
        BOOST_CHECK_EQUAL(wallet.GetLastBlockHeight(), blocks - 1);
        // Entries below the disconnected height describe blocks that are still in the chain.
        BOOST_CHECK_EQUAL(wallet.m_output_lifecycle_memo.size(), memo_before);
    }
    fixture.CheckAgainstRebuild("after the disconnect");
    (void)GetBalance(wallet); // every cached amount is filled again (an abandoned record has none)
    BOOST_CHECK_LE(fixture.DirtyRecords(), 2U);

    {
        CommitCounter counter{fixture.RawDb()};
        const int rows = sqlite3_total_changes(fixture.RawDb());
        const auto start = std::chrono::steady_clock::now();
        wallet.blockConnected(ChainstateRole::NORMAL, info);
        // The node hands the block's payouts to the wallet from its chainstate;
        // the fake block has none there, so the record is confirmed directly.
        BOOST_REQUIRE(wallet.AddToWallet(payout, TxStateConfirmed{tip_hash, blocks, static_cast<int>(fixture.tip_block.vtx.size())},
                                         ReorgWallet::Synthetic()));
        outcome.connect_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        outcome.connect_commits = counter.commits;
        outcome.connect_rows = sqlite3_total_changes(fixture.RawDb()) - rows;
    }
    outcome.dirtied_by_connect = fixture.DirtyRecords();
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(wallet.mapWallet.at(claim->GetHash()).isConfirmed());
        BOOST_CHECK(wallet.mapWallet.at(payout->GetHash()).isConfirmed());
        if (stake) BOOST_CHECK(wallet.mapWallet.at(stake->GetHash()).isConfirmed());
        if (rival) BOOST_CHECK(wallet.mapWallet.at(rival->GetHash()).isConflicted());
        BOOST_CHECK_EQUAL(wallet.GetLastBlockHeight(), blocks);
    }
    BOOST_CHECK(BalancesEqual(GetBalance(wallet), before));
    fixture.CheckAgainstRebuild("after the reconnect");

    // A second disconnect of the same block, now with a redelegation win
    // recorded at its height: the history is recomputed from the confirmed
    // coinstakes, which is the one case that walks them all.
    {
        LOCK(wallet.cs_wallet);
        WalletReorgTestAccess::RedelegationHistory(wallet)[win_at_tip] = blocks;
    }
    wallet.blockDisconnected(info);
    {
        LOCK(wallet.cs_wallet);
        outcome.coinstakes_visited_with_win = wallet.m_last_block_disconnect_work.coinstakes_visited;
        BOOST_CHECK(WalletReorgTestAccess::RedelegationHistory(wallet).empty());
        BOOST_CHECK_GE(outcome.coinstakes_visited_with_win, WalletReorgTestAccess::Coinstakes(wallet).size());
    }
    fixture.CheckAgainstRebuild("after the second disconnect");

    // The node returns the disconnected block's transactions to its mempool
    // and every wallet hears of each of them; then new ones arrive. Neither
    // callback walks the history: the claim that returns, a claim the wallet
    // has not seen, and a transaction that is not the wallet's.
    const auto mempool_add = [&](const CTransactionRef& tx, int& commits, int& rows, double& ms) {
        CommitCounter counter{fixture.RawDb()};
        const int rows_before = sqlite3_total_changes(fixture.RawDb());
        const auto start = std::chrono::steady_clock::now();
        wallet.transactionAddedToMempool(tx);
        ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        commits = counter.commits;
        rows = sqlite3_total_changes(fixture.RawDb()) - rows_before;
    };
    mempool_add(claim, outcome.readd_commits, outcome.readd_rows, outcome.readd_ms);
    const CTransactionRef next_claim = ReorgWallet::MakeClaim(COutPoint{claim->GetHash(), 0}, fixture.script, blocks + 1);
    mempool_add(next_claim, outcome.new_commits, outcome.new_rows, outcome.new_ms);
    CMutableTransaction foreign;
    foreign.vin.emplace_back(COutPoint{uint256{77}, 0});
    foreign.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    int foreign_commits{0}, foreign_rows{0};
    mempool_add(MakeTransactionRef(std::move(foreign)), foreign_commits, foreign_rows, outcome.foreign_ms);
    BOOST_CHECK_EQUAL(foreign_commits, 0);
    BOOST_CHECK_EQUAL(foreign_rows, 0);
    outcome.dirtied_by_mempool = fixture.DirtyRecords();
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(wallet.mapWallet.count(next_claim->GetHash()) == 1);
        std::string failure;
        BOOST_CHECK_MESSAGE(wallet.CheckShadowPowClaimIndexConsistencyLocked(&failure), failure);
    }
    return outcome;
}

int EnvInt(const char* name, int fallback)
{
    const char* value = std::getenv(name);
    return value && *value ? std::atoi(value) : fallback;
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(reorg_scale_tests, TestChain100Setup)

// Disconnecting and reconnecting the newest block of a wallet with more than
// 100,000 transactions does the same amount of work as on a wallet a
// twentieth of the size: nothing in either callback walks the history.
BOOST_AUTO_TEST_CASE(tip_reorg_work_follows_the_block_not_the_history)
{
    // The sizes can be lowered for a build with SHADOW_POW_CLAIM_INDEX_SELFCHECK,
    // which recounts the whole claim index after every update (quadratic):
    // REORG_SCALE_BLOCKS=1200 REORG_SCALE_SMALL_BLOCKS=300.
    const int large_blocks = EnvInt("REORG_SCALE_BLOCKS", 51000);
    const int small_blocks = EnvInt("REORG_SCALE_SMALL_BLOCKS", 2500);
    BOOST_REQUIRE_GT(small_blocks, 200);
    BOOST_REQUIRE_GT(large_blocks, small_blocks);
    const int stake_every = EnvInt("REORG_SCALE_STAKE_EVERY", 10);

    const ReorgOutcome small = DisconnectAndReconnectTip(*m_node.chain, "reorg-scale-small", small_blocks, stake_every);
    const ReorgOutcome large = DisconnectAndReconnectTip(*m_node.chain, "reorg-scale-large", large_blocks, stake_every);
    for (const ReorgOutcome* outcome : {&small, &large}) {
        BOOST_TEST_MESSAGE("records=" << outcome->records << " disconnect: " << outcome->work.ToString()
                           << " dirtied=" << outcome->dirtied_by_disconnect << " commits=" << outcome->disconnect_commits
                           << " rows=" << outcome->disconnect_rows << "; reconnect: ms=" << outcome->connect_ms
                           << " dirtied=" << outcome->dirtied_by_connect << " commits=" << outcome->connect_commits
                           << " rows=" << outcome->connect_rows
                           << "; mempool: returning claim ms=" << outcome->readd_ms << " commits=" << outcome->readd_commits
                           << " rows=" << outcome->readd_rows << ", new claim ms=" << outcome->new_ms
                           << " commits=" << outcome->new_commits << " rows=" << outcome->new_rows
                           << ", foreign ms=" << outcome->foreign_ms << ", dirty records after=" << outcome->dirtied_by_mempool);
    }
    if (large_blocks >= 51000) BOOST_CHECK_GT(large.records, 100000U);

    // Nothing proportional to the history: the same counts on both wallets.
    BOOST_CHECK_EQUAL(large.work.memo_entries_visited, small.work.memo_entries_visited);
    BOOST_CHECK_EQUAL(large.work.coinstakes_visited, small.work.coinstakes_visited);
    BOOST_CHECK_EQUAL(large.work.payouts_synced, small.work.payouts_synced);
    BOOST_CHECK_EQUAL(large.dirtied_by_disconnect, small.dirtied_by_disconnect);
    BOOST_CHECK_EQUAL(large.dirtied_by_connect, small.dirtied_by_connect);
    BOOST_CHECK_EQUAL(large.disconnect_rows, small.disconnect_rows);
    BOOST_CHECK_EQUAL(large.connect_rows, small.connect_rows);

    // And small in absolute terms: the block has one claim, one coinstake and one payout of the wallet.
    BOOST_CHECK_EQUAL(large.work.memo_entries_visited, 0U);
    BOOST_CHECK_LE(large.work.coinstakes_visited, 4U);
    BOOST_CHECK_GT(large.coinstakes_visited_with_win, small.coinstakes_visited_with_win);
    BOOST_CHECK_EQUAL(large.work.payouts_synced, 1U);
    BOOST_CHECK_LE(large.dirtied_by_disconnect, 8U);
    BOOST_CHECK_LE(large.dirtied_by_connect, 8U);
    BOOST_CHECK_EQUAL(large.disconnect_commits, 1);
    BOOST_CHECK_LE(large.disconnect_rows, 12);
    BOOST_CHECK_LE(large.connect_rows, 12);
    // One commit per wallet transaction that enters the mempool, none otherwise.
    BOOST_CHECK_EQUAL(large.readd_commits, 1);
    BOOST_CHECK_EQUAL(large.new_commits, 1);
    BOOST_CHECK_EQUAL(large.readd_rows, small.readd_rows);
    BOOST_CHECK_EQUAL(large.new_rows, small.new_rows);
    BOOST_CHECK_EQUAL(large.dirtied_by_mempool, small.dirtied_by_mempool);
    BOOST_CHECK_LE(large.dirtied_by_mempool, 12U);
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
