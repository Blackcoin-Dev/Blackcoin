// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <addresstype.h>
#include <coins.h>
#include <consensus/amount.h>
#include <crypto/mldsa.h>
#include <node/quantum_pool.h>
#include <primitives/transaction.h>
#include <script/script.h>
#include <test/util/setup_common.h>
#include <uint256.h>

#include <boost/test/unit_test.hpp>

#include <map>
#include <memory>
#include <vector>

BOOST_FIXTURE_TEST_SUITE(quantum_pool_tests, BasicTestingSetup)

namespace {

std::vector<unsigned char> PubKey(unsigned char tag)
{
    return std::vector<unsigned char>(ML_DSA::PUBLICKEY_BYTES, tag);
}

CScript QcsScript(const std::vector<unsigned char>& staker, const std::vector<unsigned char>& owner)
{
    return GetScriptForDestination(WitnessUnknown{
        QUANTUM_COLDSTAKE_WITNESS_VERSION,
        QuantumColdStakeProgramForPubkeys(staker, owner)});
}

CScript TieredQcsScript(const std::vector<unsigned char>& staker, const std::vector<unsigned char>& owner)
{
    return GetScriptForDestination(WitnessUnknown{
        QUANTUM_COLDSTAKE_WITNESS_VERSION,
        QuantumTieredColdStakeProgramForPubkeys(staker, owner, QUANTUM_TIERED_STATE_BONDED, 40500, 0)});
}

node::QuantumPoolClaim Claim(const COutPoint& outpoint, const std::vector<unsigned char>& staker, const std::vector<unsigned char>& owner)
{
    node::QuantumPoolClaim claim;
    claim.outpoint = outpoint;
    claim.staker_pubkey_hash = node::QuantumPoolHashPubKey(staker);
    claim.owner_pubkey_hash = node::QuantumPoolHashPubKey(owner);
    return claim;
}

node::QuantumPoolClaim TieredClaim(const COutPoint& outpoint, const std::vector<unsigned char>& staker, const std::vector<unsigned char>& owner)
{
    node::QuantumPoolClaim claim = Claim(outpoint, staker, owner);
    claim.tiered = true;
    claim.state = QUANTUM_TIERED_STATE_BONDED;
    claim.unbonding_blocks = 40500;
    claim.unlock_height = 0;
    return claim;
}

class MapCoinsCursor final : public CCoinsViewCursor
{
    using Map = std::map<COutPoint, Coin>;
    const Map& m_map;
    Map::const_iterator m_it;
    size_t& m_entries_read;

public:
    MapCoinsCursor(const Map& map, size_t& entries_read) : CCoinsViewCursor(uint256::ONE), m_map(map), m_it(m_map.begin()), m_entries_read(entries_read) {}

    bool GetKey(COutPoint& key) const override
    {
        if (m_it == m_map.end()) return false;
        key = m_it->first;
        return true;
    }

    bool GetValue(Coin& coin) const override
    {
        if (m_it == m_map.end()) return false;
        ++m_entries_read;
        coin = m_it->second;
        return true;
    }

    bool GetValueAt(const COutPoint& key, Coin& coin) override
    {
        const auto it = m_map.find(key);
        if (it == m_map.end() || it->second.IsSpent()) return false;
        coin = it->second;
        return true;
    }

    bool Valid() const override { return m_it != m_map.end(); }
    void Next() override { ++m_it; }
};

class MapCoinsView final : public CCoinsView
{
    std::map<COutPoint, Coin> m_coins;

public:
    mutable size_t cursor_calls{0};
    mutable size_t cursor_entries_read{0};

    bool GetCoin(const COutPoint& outpoint, Coin& coin) const override
    {
        const auto it = m_coins.find(outpoint);
        if (it == m_coins.end() || it->second.IsSpent()) return false;
        coin = it->second;
        return true;
    }

    uint256 GetBestBlock() const override { return uint256::ONE; }
    std::unique_ptr<CCoinsViewCursor> Cursor() const override
    {
        ++cursor_calls;
        return std::make_unique<MapCoinsCursor>(m_coins, cursor_entries_read);
    }

    void ResetCursorCounts() const
    {
        cursor_calls = 0;
        cursor_entries_read = 0;
    }

    void Add(const COutPoint& outpoint, CAmount amount, const CScript& script)
    {
        m_coins.emplace(outpoint, Coin{CTxOut{amount, script}, /*nHeightIn=*/100, /*fCoinBaseIn=*/false, /*fCoinStakeIn=*/false, /*nTimeIn=*/0});
    }
};

} // namespace

BOOST_AUTO_TEST_CASE(chainstate_share_verifies_discovery_claims)
{
    const auto staker_a = PubKey(0x11);
    const auto owner_a = PubKey(0x21);
    const auto staker_b = PubKey(0x12);
    const auto owner_b = PubKey(0x22);
    const auto staker_tiered = PubKey(0x13);
    const auto owner_tiered = PubKey(0x23);

    const COutPoint out_a{uint256::ONE, 0};
    const COutPoint out_b{uint256::ONE, 1};
    const COutPoint out_tiered{uint256::ONE, 2};
    const COutPoint out_plain{uint256::ONE, 3};

    MapCoinsView view;
    view.Add(out_a, 100 * COIN, QcsScript(staker_a, owner_a));
    view.Add(out_b, 400 * COIN, QcsScript(staker_b, owner_b));
    view.Add(out_tiered, 50 * COIN, TieredQcsScript(staker_tiered, owner_tiered));
    view.Add(out_plain, 999 * COIN, CScript() << OP_TRUE);

    BOOST_CHECK_EQUAL(node::ComputeQuantumColdStakeTotal(view), 550 * COIN);

    const auto claim_a = Claim(out_a, staker_a, owner_a);
    const auto share_a = node::ComputeQuantumPoolShare(view, node::QuantumPoolHashPubKey(staker_a), {claim_a});
    BOOST_CHECK_EQUAL(share_a.total_coldstake, 550 * COIN);
    BOOST_CHECK_EQUAL(share_a.operator_share.verified_value, 100 * COIN);
    BOOST_CHECK_EQUAL(share_a.operator_share.verified_claims, 1);
    BOOST_CHECK_EQUAL(share_a.operator_share.invalid_claims, 0);

    auto forged = Claim(out_a, staker_a, owner_b);
    const auto forged_result = node::VerifyQuantumPoolClaim(view, forged);
    BOOST_CHECK(!forged_result.valid);
    BOOST_CHECK_EQUAL(forged_result.reject_reason, "commitment-mismatch");

    const auto duplicate_share = node::ComputeQuantumPoolShare(view, node::QuantumPoolHashPubKey(staker_a), {claim_a, claim_a});
    BOOST_CHECK_EQUAL(duplicate_share.operator_share.verified_value, 100 * COIN);
    BOOST_CHECK_EQUAL(duplicate_share.operator_share.verified_claims, 1);
    BOOST_CHECK_EQUAL(duplicate_share.operator_share.invalid_claims, 1);

    const auto tiered_claim = TieredClaim(out_tiered, staker_tiered, owner_tiered);
    const auto tiered_result = node::VerifyQuantumPoolClaim(view, tiered_claim);
    BOOST_CHECK(tiered_result.valid);
    BOOST_CHECK_EQUAL(tiered_result.value, 50 * COIN);

    BOOST_CHECK_EQUAL(node::QuantumPoolShareBps(100 * COIN, 500 * COIN), 2000);
    BOOST_CHECK(node::WouldQuantumPoolExceedCap(500 * COIN, 100 * COIN, 1 * COIN));
    BOOST_CHECK(!node::WouldQuantumPoolExceedCap(500 * COIN, 0, 1 * COIN));
}

BOOST_AUTO_TEST_CASE(operator_commitment_eligibility_follows_coins_view)
{
    node::ClearQuantumPoolRegistry();
    const auto staker = PubKey(0x31);
    const auto other_staker = PubKey(0x32);
    const auto owner = PubKey(0x33);
    const uint256 staker_hash = node::QuantumPoolHashPubKey(staker);
    const COutPoint commitment{uint256::ONE, 0};
    const CScript commitment_script = node::QuantumPoolOperatorCommitmentScript(staker);

    MapCoinsView base;
    base.Add(commitment, 10 * COIN, commitment_script);
    base.Add(COutPoint{uint256::ONE, 1}, 500 * COIN, QcsScript(other_staker, owner));
    CCoinsViewCache view{&base};
    BOOST_REQUIRE(node::VerifyQuantumPoolOperatorCommitment(view, staker, commitment));
    node::UpsertQuantumPoolOperator(staker_hash, staker, {}, true, commitment);

    const auto check_eligibility = [&](bool expected) {
        const auto share = node::ComputeQuantumPoolShare(view, staker_hash, {});
        BOOST_CHECK_EQUAL(share.operator_share.operator_commitment_verified, expected);
        BOOST_CHECK(share.operator_share.operator_commitment_outpoint == commitment);
        BOOST_CHECK_EQUAL(node::HasQuantumPoolUnderCapCandidate(view, COIN), expected);
    };
    const auto restore_commitment = [&] {
        view.AddCoin(commitment,
                     Coin{CTxOut{10 * COIN, commitment_script}, 100, false, false, 0},
                     /*possible_overwrite=*/true);
    };

    check_eligibility(true);
    BOOST_REQUIRE(view.SpendCoin(commitment));
    check_eligibility(false);

    // Updating discovery claims must not turn a spent, previously verified
    // commitment back into an eligible candidate.
    node::UpsertQuantumPoolOperator(staker_hash, staker, {}, false);
    check_eligibility(false);
    restore_commitment();
    check_eligibility(true);

    view.AddCoin(commitment,
                 Coin{CTxOut{10 * COIN, node::QuantumPoolOperatorCommitmentScript(other_staker)}, 100, false, false, 0},
                 /*possible_overwrite=*/true);
    check_eligibility(false);

    const CScript unbonding_script = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        QuantumTieredMigrationProgramForPubkey(staker, QUANTUM_TIERED_STATE_UNBONDING, 40500, 40600)});
    view.AddCoin(commitment,
                 Coin{CTxOut{10 * COIN, unbonding_script}, 100, false, false, 0},
                 /*possible_overwrite=*/true);
    check_eligibility(false);
    restore_commitment();
    check_eligibility(true);
    node::ClearQuantumPoolRegistry();
}

BOOST_AUTO_TEST_CASE(pool_share_batch_reuses_one_denominator_scan)
{
    node::ClearQuantumPoolRegistry();
    MapCoinsView view;
    const auto owner = PubKey(0x41);
    const std::vector<std::vector<unsigned char>> stakers{PubKey(0x51), PubKey(0x52), PubKey(0x53)};
    const std::vector<CAmount> amounts{100 * COIN, 400 * COIN, 50 * COIN};
    std::vector<uint256> hashes;
    for (size_t i = 0; i < stakers.size(); ++i) {
        const uint256 hash = node::QuantumPoolHashPubKey(stakers[i]);
        hashes.push_back(hash);
        const COutPoint outpoint{uint256::ONE, static_cast<uint32_t>(i)};
        const COutPoint commitment{uint256::ONE, static_cast<uint32_t>(10 + i)};
        const auto claim = i == 2 ? TieredClaim(outpoint, stakers[i], owner) : Claim(outpoint, stakers[i], owner);
        view.Add(outpoint, amounts[i], node::QuantumPoolScriptForClaim(claim));
        view.Add(commitment, 10 * COIN, node::QuantumPoolOperatorCommitmentScript(stakers[i]));
        std::vector<node::QuantumPoolClaim> claims{claim};
        if (i == 0) {
            claims.push_back(claim); // Duplicate.
            claims.push_back(Claim(COutPoint{uint256::ONE, 1}, stakers[1], owner)); // Another staker.
            claims.push_back(Claim(COutPoint{uint256::ONE, 99}, stakers[i], owner)); // Missing.
        }
        node::UpsertQuantumPoolOperator(hash, stakers[i], claims, true, commitment);
    }
    view.Add(COutPoint{uint256::ONE, 20}, 450 * COIN, QcsScript(PubKey(0x54), owner));
    view.Add(COutPoint{uint256::ONE, 21}, 900 * COIN, CScript() << OP_TRUE);

    // The former loop performs one full cursor walk for every operator.
    std::vector<node::QuantumPoolShare> separate;
    for (const uint256& hash : hashes) {
        separate.push_back(node::ComputeQuantumPoolShare(view, hash, node::GetQuantumPoolClaims(hash)));
    }
    BOOST_CHECK_EQUAL(view.cursor_calls, 3);
    BOOST_CHECK_EQUAL(view.cursor_entries_read, 3 * 8);
    view.ResetCursorCounts();

    const node::QuantumPoolShareCalculator pool_shares{view};
    BOOST_CHECK_EQUAL(view.cursor_calls, 0); // An unused operation does not scan.
    BOOST_CHECK_EQUAL(pool_shares.TotalColdStake(), 1000 * COIN);
    for (size_t i = 0; i < hashes.size(); ++i) {
        const auto share = pool_shares.ComputeShare(hashes[i], node::GetQuantumPoolClaims(hashes[i]));
        const auto& before = separate[i];
        BOOST_CHECK_EQUAL(share.total_coldstake, before.total_coldstake);
        BOOST_CHECK_EQUAL(share.operator_share.verified_value, before.operator_share.verified_value);
        BOOST_CHECK_EQUAL(share.operator_share.verified_value, amounts[i]);
        BOOST_CHECK_EQUAL(share.operator_share.verified_claims, before.operator_share.verified_claims);
        BOOST_CHECK_EQUAL(share.operator_share.verified_claims, 1);
        BOOST_CHECK_EQUAL(share.operator_share.invalid_claims, before.operator_share.invalid_claims);
        BOOST_CHECK_EQUAL(share.operator_share.invalid_claims, i == 0 ? 3 : 0);
        BOOST_CHECK(share.operator_share.staker_pubkey_hash == before.operator_share.staker_pubkey_hash);
        BOOST_CHECK(share.operator_share.staker_pubkey == before.operator_share.staker_pubkey);
        BOOST_CHECK(share.operator_share.operator_commitment_outpoint == before.operator_share.operator_commitment_outpoint);
        BOOST_CHECK_EQUAL(share.operator_share.operator_commitment_verified, before.operator_share.operator_commitment_verified);
        BOOST_CHECK(share.operator_share.operator_commitment_verified);
        BOOST_CHECK_EQUAL(node::QuantumPoolShareBps(share.operator_share.verified_value, share.total_coldstake),
                          node::QuantumPoolShareBps(before.operator_share.verified_value, before.total_coldstake));
        for (const CAmount inflow : {CAmount{0}, COIN, 125 * COIN, 125 * COIN + 1, 1000 * COIN}) {
            BOOST_CHECK_EQUAL(node::WouldQuantumPoolExceedCap(share.total_coldstake, share.operator_share.verified_value, inflow),
                              node::WouldQuantumPoolExceedCap(before.total_coldstake, before.operator_share.verified_value, inflow));
        }
        if (i == 0) {
            BOOST_CHECK(!node::WouldQuantumPoolExceedCap(share.total_coldstake, share.operator_share.verified_value, 125 * COIN));
            BOOST_CHECK(node::WouldQuantumPoolExceedCap(share.total_coldstake, share.operator_share.verified_value, 125 * COIN + 1));
        }
    }
    BOOST_CHECK(pool_shares.HasUnderCapCandidate(COIN));
    BOOST_CHECK(!pool_shares.HasUnderCapCandidate(COIN, {hashes[0], hashes[2]}));
    BOOST_CHECK(!pool_shares.HasUnderCapCandidate(1000 * COIN)); // Visits every candidate.
    BOOST_CHECK_EQUAL(view.cursor_calls, 1);
    BOOST_CHECK_EQUAL(view.cursor_entries_read, 8);

    view.ResetCursorCounts();
    BOOST_CHECK(!node::HasQuantumPoolUnderCapCandidate(view, 1000 * COIN));
    BOOST_CHECK_EQUAL(view.cursor_calls, 1); // Free-function candidate loop also batches.
    BOOST_CHECK_EQUAL(view.cursor_entries_read, 8);
    view.ResetCursorCounts();
    BOOST_CHECK(!node::HasQuantumPoolUnderCapCandidate(view, COIN, hashes));
    BOOST_CHECK_EQUAL(view.cursor_calls, 0);
    node::ClearQuantumPoolRegistry();
}

BOOST_AUTO_TEST_CASE(pool_share_operations_refresh_after_coins_view_changes)
{
    node::ClearQuantumPoolRegistry();
    const auto staker = PubKey(0x61);
    const auto owner = PubKey(0x62);
    const uint256 hash = node::QuantumPoolHashPubKey(staker);
    const COutPoint delegation{uint256::ONE, 0};
    const COutPoint commitment{uint256::ONE, 1};
    const CScript delegation_script = QcsScript(staker, owner);
    const CScript commitment_script = node::QuantumPoolOperatorCommitmentScript(staker);
    MapCoinsView base;
    base.Add(delegation, 100 * COIN, delegation_script);
    base.Add(commitment, 10 * COIN, commitment_script);
    base.Add(COutPoint{uint256::ONE, 2}, 900 * COIN, QcsScript(PubKey(0x63), owner));
    CCoinsViewCache view{&base};
    node::UpsertQuantumPoolOperator(hash, staker, {Claim(delegation, staker, owner)}, true, commitment);

    const auto check_operation = [&](CAmount total, CAmount value, bool eligible) {
        base.ResetCursorCounts();
        // A new calculator belongs to each unchanged-view operation.
        const node::QuantumPoolShareCalculator pool_shares{view};
        const auto share = pool_shares.ComputeShare(hash, node::GetQuantumPoolClaims(hash));
        BOOST_CHECK_EQUAL(pool_shares.TotalColdStake(), total);
        BOOST_CHECK_EQUAL(share.total_coldstake, total);
        BOOST_CHECK_EQUAL(share.operator_share.verified_value, value);
        BOOST_CHECK_EQUAL(share.operator_share.operator_commitment_verified, eligible);
        BOOST_CHECK_EQUAL(pool_shares.HasUnderCapCandidate(COIN), eligible);
        BOOST_CHECK_EQUAL(base.cursor_calls, 1);
    };
    check_operation(1000 * COIN, 100 * COIN, true);
    BOOST_REQUIRE(view.SpendCoin(delegation));
    check_operation(900 * COIN, 0, true);
    BOOST_REQUIRE(view.SpendCoin(commitment));
    check_operation(900 * COIN, 0, false);
    view.AddCoin(delegation, Coin{CTxOut{100 * COIN, delegation_script}, 100, false, false, 0}, true);
    view.AddCoin(commitment, Coin{CTxOut{10 * COIN, commitment_script}, 100, false, false, 0}, true);
    check_operation(1000 * COIN, 100 * COIN, true);
    node::ClearQuantumPoolRegistry();
}

BOOST_AUTO_TEST_SUITE_END()
