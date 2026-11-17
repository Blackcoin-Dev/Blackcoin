// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/txvaluemap.h>

#include <primitives/transaction.h>
#include <random.h>
#include <streams.h>
#include <test/util/random.h>
#include <test/util/setup_common.h>
#include <util/fs.h>
#include <util/strencodings.h>
#include <util/string.h>
#include <validation.h>
#include <wallet/db.h>
#include <wallet/shadow_pow_claim_recovery_types.h>
#include <wallet/test/util.h>
#include <wallet/transaction.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>

#include <boost/test/unit_test.hpp>

#include <cstdlib>
#include <map>
#include <string>
#include <vector>

#ifdef __APPLE__
#include <malloc/malloc.h>
#endif

namespace wallet {
namespace {

/**
 * The wallet transaction record exactly as rc12 and earlier hold and write it:
 * the metadata is a std::map<std::string, std::string> and the serializer is
 * the one CWalletTx had before the metadata was packed. It is the reference
 * for "the bytes on disk did not change".
 */
struct ReferenceWalletTx {
    mapValue_t mapValue;
    std::vector<std::pair<std::string, std::string>> vOrderForm;
    unsigned int fTimeReceivedIsTxTime{0};
    unsigned int nTimeReceived{0};
    unsigned int nTimeSmart{0};
    bool fFromMe{false};
    int64_t nOrderPos{-1};
    CTransactionRef tx;
    TxState m_state{TxStateInactive{}};

    template <typename Stream>
    void Serialize(Stream& s) const
    {
        mapValue_t mapValueCopy = mapValue;

        mapValueCopy["fromaccount"] = "";
        if (nOrderPos != -1) {
            mapValueCopy["n"] = ToString(nOrderPos);
        }
        if (nTimeSmart) {
            mapValueCopy["timesmart"] = strprintf("%u", nTimeSmart);
        }

        std::vector<uint8_t> dummy_vector1;
        std::vector<uint8_t> dummy_vector2;
        bool dummy_bool = false;
        uint256 serializedHash = TxStateSerializedBlockHash(m_state);
        int serializedIndex = TxStateSerializedIndex(m_state);
        s << TX_WITH_WITNESS(tx) << serializedHash << dummy_vector1 << serializedIndex << dummy_vector2 << mapValueCopy << vOrderForm << fTimeReceivedIsTxTime << nTimeReceived << fFromMe << dummy_bool;
    }
};

std::vector<unsigned char> Bytes(const DataStream& stream)
{
    const auto* begin = UCharCast(stream.data());
    return {begin, begin + stream.size()};
}

template <typename T>
std::vector<unsigned char> SerializeBytes(const T& object)
{
    DataStream stream;
    stream << object;
    return Bytes(stream);
}

CTransactionRef MakeTx(uint32_t salt)
{
    CMutableTransaction mtx;
    mtx.nVersion = 2;
    mtx.vin.emplace_back(COutPoint{Txid::FromUint256(uint256{static_cast<uint8_t>(1 + salt % 250)}), salt});
    mtx.vout.emplace_back(1000 + salt, CScript{} << OP_TRUE);
    mtx.nLockTime = salt;
    return MakeTransactionRef(mtx);
}

ReferenceWalletTx MakeReference(const mapValue_t& values, uint32_t salt)
{
    ReferenceWalletTx reference;
    reference.mapValue = values;
    reference.tx = MakeTx(salt);
    reference.fTimeReceivedIsTxTime = salt % 2;
    reference.nTimeReceived = 1700000000 + salt;
    reference.nTimeSmart = salt % 3 == 0 ? 0 : 1700000000 + salt;
    reference.fFromMe = salt % 2 == 0;
    reference.nOrderPos = salt % 5 == 0 ? -1 : static_cast<int64_t>(salt);
    if (salt % 4 == 1) reference.vOrderForm.emplace_back("Message", "order " + ToString(salt));
    if (salt % 2 == 0) {
        reference.m_state = TxStateConfirmed{uint256{static_cast<uint8_t>(2 + salt % 200)}, static_cast<int>(100 + salt), static_cast<int>(salt % 7)};
    }
    return reference;
}

//! Checks every read path of the packed map against plain lookups in the std::map it must equal.
void CheckReadsLikeMap(const WalletTxValueMap& packed, const mapValue_t& values, const std::vector<std::string>& probe_keys)
{
    BOOST_CHECK_EQUAL(packed.empty(), values.empty());
    BOOST_CHECK_EQUAL(packed.size(), values.size());
    BOOST_CHECK(packed.ToMap() == values);
    BOOST_CHECK(packed == values);
    BOOST_CHECK(values == packed);
    BOOST_CHECK(!(packed != values));
    BOOST_CHECK(static_cast<mapValue_t>(packed) == values);
    BOOST_CHECK(WalletTxValueMap{values} == packed);

    // Iteration: the same pairs in the same order. This is the loop the
    // gettransaction and listtransactions RPCs print the map with.
    auto expected = values.begin();
    size_t visited{0};
    for (const std::pair<const std::string, std::string>& item : packed) {
        BOOST_REQUIRE(expected != values.end());
        BOOST_CHECK(item.first == expected->first);
        BOOST_CHECK(item.second == expected->second);
        ++expected;
        ++visited;
    }
    BOOST_CHECK(expected == values.end());
    BOOST_CHECK_EQUAL(visited, values.size());
    expected = values.begin();
    for (const auto& [key, value] : packed) {
        BOOST_CHECK(key == expected->first && value == expected->second);
        ++expected;
    }

    std::vector<std::string> keys{probe_keys};
    for (const auto& [key, _] : values) {
        keys.push_back(key);
        keys.push_back(key + "x");
        keys.push_back(key.substr(0, key.size() / 2));
    }
    for (size_t id{0}; id < WalletTxValueMap::KnownKeyCount(); ++id) keys.emplace_back(WalletTxValueMap::KnownKey(id));
    for (const std::string& key : keys) {
        const auto raw = values.find(key);
        const auto it = packed.find(key);
        BOOST_CHECK_EQUAL(packed.count(key), values.count(key));
        BOOST_CHECK_EQUAL(it == packed.end(), raw == values.end());
        BOOST_CHECK_EQUAL(packed.Get(key).has_value(), raw != values.end());
        if (raw != values.end()) {
            BOOST_REQUIRE(it != packed.end());
            BOOST_CHECK(it->first == raw->first);
            BOOST_CHECK(it->second == raw->second);
            BOOST_CHECK((*it).second == raw->second);
            BOOST_CHECK(packed.at(key) == raw->second);
            BOOST_CHECK(*packed.Get(key) == raw->second);
        } else {
            BOOST_CHECK_THROW(packed.at(key), std::out_of_range);
        }
        const auto raw_bound = values.lower_bound(key);
        const auto bound = packed.lower_bound(key);
        BOOST_CHECK_EQUAL(bound == packed.end(), raw_bound == values.end());
        if (raw_bound != values.end() && bound != packed.end()) {
            BOOST_CHECK(bound->first == raw_bound->first);
            BOOST_CHECK(bound->second == raw_bound->second);
        }
    }
}

//! Old form and new form write the same bytes; the old bytes load and rewrite unchanged.
//! With full_reads false only whole-map equality is checked on the read side (for the large product of writer combinations).
void CheckSerializesLikeReference(const mapValue_t& values, uint32_t salt, const std::vector<std::string>& probe_keys, bool full_reads = true)
{
    const auto check_reads = [&](const WalletTxValueMap& packed) {
        if (full_reads) {
            CheckReadsLikeMap(packed, values, probe_keys);
        } else {
            BOOST_CHECK(packed.ToMap() == values);
        }
    };
    const ReferenceWalletTx reference{MakeReference(values, salt)};
    const std::vector<unsigned char> reference_bytes{SerializeBytes(reference)};

    // Built in memory the way the wallet builds a new record.
    CWalletTx built{reference.tx, reference.m_state};
    built.mapValue = values;
    built.vOrderForm = reference.vOrderForm;
    built.fTimeReceivedIsTxTime = reference.fTimeReceivedIsTxTime;
    built.nTimeReceived = reference.nTimeReceived;
    built.nTimeSmart = reference.nTimeSmart;
    built.fFromMe = reference.fFromMe;
    built.nOrderPos = reference.nOrderPos;
    BOOST_CHECK(SerializeBytes(built) == reference_bytes);
    check_reads(built.mapValue);

    // Loaded from the bytes an earlier release wrote, then written again.
    CWalletTx loaded{nullptr, TxStateInactive{}};
    DataStream stream{reference_bytes};
    stream >> loaded;
    BOOST_CHECK(stream.empty());
    BOOST_CHECK(SerializeBytes(loaded) == reference_bytes);
    check_reads(loaded.mapValue);
    BOOST_CHECK(loaded.mapValue == built.mapValue);

    // Copies (CopyFrom is what AddToWallet's persist-then-publish paths use).
    CWalletTx copy{reference.tx, reference.m_state};
    copy.CopyFrom(loaded);
    BOOST_CHECK(SerializeBytes(copy) == reference_bytes);
    BOOST_CHECK(copy.mapValue == loaded.mapValue);
}

std::string Hex(uint8_t seed) { return uint256{seed}.GetHex(); }

/** Every pair the wallet's writers produce, grouped the way the writers set them. */
struct WriterGroup {
    const char* name;
    std::vector<std::vector<std::pair<std::string, std::string>>> variants;
};

std::vector<WriterGroup> WriterGroups()
{
    std::vector<WriterGroup> groups;
    // CommitTransaction callers: comment and to.
    groups.push_back({"comment", {{{"comment", "PoW Claim"}}, {{"comment", "PoS Claim"}}, {{"comment", "rent"}, {"to", "landlord"}}, {{"comment", ""}}}});
    // ThreadShadowPoWMiner: authored claim, root or same-anchor refresh.
    groups.push_back({"authored", {
        {{SHADOW_POW_CLAIM_AUTHORED_KEY, "1"}, {SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY, "812345"}, {SHADOW_POW_CLAIM_CREATED_TIP_KEY, Hex(11)}},
        {{SHADOW_POW_CLAIM_AUTHORED_KEY, "1"}, {SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY, "0"}, {SHADOW_POW_CLAIM_CREATED_TIP_KEY, uint256::ZERO.GetHex()}}}});
    groups.push_back({"lineage", {
        {{SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY, SHADOW_POW_CLAIM_LINEAGE_SCHEMA_VERSION}, {SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY, Hex(12)}, {SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY, Hex(13)}, {SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY, "0"}},
        {{SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY, SHADOW_POW_CLAIM_LINEAGE_SCHEMA_VERSION}, {SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY, Hex(12)}, {SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY, Hex(13)}, {SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY, "4294967295"}, {SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY, Hex(14)}}}});
    // CommitTransaction: relay clock.
    groups.push_back({"relay_clock", {
        {{SHADOW_POW_CLAIM_RELAY_CLOCK_SCHEMA_KEY, SHADOW_POW_CLAIM_RELAY_CLOCK_SCHEMA_VERSION}, {SHADOW_POW_CLAIM_RELAY_BIRTH_KEY, "1763400000"}, {SHADOW_POW_CLAIM_RELAY_TXID_KEY, Hex(15)}}}});
    // MarkShadowPowClaimQuarantined and the repair paths.
    groups.push_back({"quarantine", {
        {{SHADOW_POW_QUARANTINE_MARKER_KEY, "1"}},
        {{SHADOW_POW_QUARANTINE_MARKER_KEY, "1"}, {SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY, "812346"}, {SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY, Hex(16)}},
        {{SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY, "812346"}, {SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY, Hex(16)}}}});
    groups.push_back({"branch_quarantine", {
        {{SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY, "812400"}, {SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY, Hex(17)}}}});
    // Explicit adoption.
    groups.push_back({"adoption", {
        {{SHADOW_POW_CLAIM_ADOPTED_KEY, "1"}, {SHADOW_POW_CLAIM_ADOPTION_TIP_KEY, Hex(18)}, {SHADOW_POW_CLAIM_ADOPTION_FINGERPRINT_KEY, Hex(19)}}}});
    // Managed resolution record, draft, authorized and revoked.
    const std::vector<std::pair<std::string, std::string>> resolution{
        {SHADOW_POW_RESOLUTION_SCHEMA_KEY, SHADOW_POW_RESOLUTION_SCHEMA_VERSION}, {SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY, Hex(20)},
        {SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY, "3"}, {SHADOW_POW_RESOLUTION_FINGERPRINT_KEY, Hex(21)},
        {SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY, "812500"}, {SHADOW_POW_RESOLUTION_CREATED_TIME_KEY, "1763400123"},
        {SHADOW_POW_LEGACY_CLEANUP_FOR_KEY, Hex(22)}};
    auto draft = resolution;
    draft.insert(draft.end(), {{SHADOW_POW_RESOLUTION_ORIGIN_KEY, SHADOW_POW_RESOLUTION_ORIGIN_MANUAL}, {SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY, "0"}, {SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY, "0"}});
    auto authorized = resolution;
    authorized.insert(authorized.end(), {{SHADOW_POW_RESOLUTION_ORIGIN_KEY, SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC}, {SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY, "1"}, {SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY, "0"},
        {SHADOW_POW_RESOLUTION_AUTH_SCHEMA_KEY, "1"}, {SHADOW_POW_RESOLUTION_AUTH_PLAN_KEY, Hex(23)}, {SHADOW_POW_RESOLUTION_AUTH_TIP_KEY, Hex(24)},
        {SHADOW_POW_RESOLUTION_AUTH_HEIGHT_KEY, "812501"}, {SHADOW_POW_RESOLUTION_AUTH_GENERATION_KEY, "18446744073709551615"},
        {SHADOW_POW_RESOLUTION_AUTH_ORIGIN_KEY, SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC}, {SHADOW_POW_RESOLUTION_AUTH_WTXID_KEY, Hex(25)}});
    auto revoked = authorized;
    for (auto& [key, value] : revoked) {
        if (key == SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY) value = "0";
        if (key == SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY) value = "1";
    }
    groups.push_back({"resolution", {draft, authorized, revoked,
        {{SHADOW_POW_LEGACY_CLEANUP_FOR_KEY, Hex(22)}},
        {{SHADOW_POW_LEGACY_CLEANUP_FOR_KEY, Hex(22)}, {"qq_shadow_pow_legacy_cleanup_quarantine", "1"}}}});
    // Abandon and reorg provenance.
    groups.push_back({"provenance", {{{"qq_auto_shadow_stale", "1"}}, {{"qq_manual_shadow_abandon", "1"}}, {{"qq_reorg_shadow_resubmit", "1"}}, {{"qq_auto_shadow_stale", "1"}, {"qq_reorg_shadow_resubmit", "1"}}}});
    // QQSIGNAL records.
    groups.push_back({"signal", {{{"qq_shadow_signal_source", "automatic"}}, {{"qq_shadow_signal_source", "manual"}, {"qq_shadow_signal_reorg_height", "812600"}, {"qq_shadow_signal_reorg_hash", Hex(26)}}}});
    // Synthetic payout records.
    groups.push_back({"payout", {{{"qq_synthetic_goldrush_payout", "1"}},
        {{"qq_synthetic_goldrush_payout", "1"}, {"qq_synthetic_goldrush_payout_stale", "1"}, {"qq_synthetic_goldrush_payout_stale_block", Hex(27)}, {"qq_synthetic_goldrush_payout_stale_height", "812700"}}}});
    // Replacement bookkeeping.
    groups.push_back({"replacement", {{{"replaces_txid", Hex(28)}}, {{"replaced_by_txid", Hex(29)}}}});
    return groups;
}

/** Values no writer produces: each must be kept verbatim. */
std::vector<std::string> OddValues()
{
    std::string upper{Hex(30)};
    upper[5] = 'A';
    std::string with_nul{"a"};
    with_nul.push_back('\0');
    with_nul += "b";
    std::string high_bytes;
    for (int c{250}; c < 256; ++c) high_bytes.push_back(static_cast<char>(c));
    return {
        "", " ", "00", "01", "007", "+1", "-1", "-0", " 1", "1 ", "1\n", "0x10", "1e3", "1.0",
        "18446744073709551615", "18446744073709551616", "99999999999999999999", "100000000000000000000", "000000000000000000000",
        "9223372036854775807", "9223372036854775808", "4294967296", "127", "128", "16383", "16384",
        upper, ToUpper(Hex(31)), Hex(32).substr(1), Hex(33) + "0", " " + Hex(34), Hex(35) + " ", "0x" + Hex(36).substr(2),
        std::string(64, 'g'), std::string(64, '0'), std::string(64, 'f'), std::string(63, 'f'), std::string(65, 'f'),
        with_nul, high_bytes, "true", "automatic ", "Manual", std::string(127, 'x'), std::string(128, 'x'), std::string(300, 'y'),
        std::string(16383, 'z'), std::string(16384, 'z'), std::string(70000, 'w'),
    };
}

std::vector<std::string> OddKeys()
{
    std::string with_nul{"qq_shadow_pow_"};
    with_nul.push_back('\0');
    return {
        "", "a", "comment ", "Comment", "commen", "comments", "qq_shadow_pow_", "qq_shadow_pow_future_field", "qq_shadow_pow_authored2",
        "qq_shadow_pow_author", "qq_shadow_pow_zzz_unknown", "qq_shadow_pow_test_oversized", "qq_shadow_powx", "QQ_SHADOW_POW_AUTHORED",
        "qq_synthetic_goldrush_payout_v2", "zz_after_everything", "~", with_nul, std::string(200, 'k'), std::string(1, '\xff'),
        "fromaccountx", "n2", "timesmart_", "spent ",
    };
}

} // namespace

namespace {
mapValue_t ClaimShapedValues(uint32_t i)
{
    // What a confirmed, self-authored Gold Rush claim carries: the miner's
    // pairs, CommitTransaction's relay clock and the first-quarantine pair.
    const auto hash = [&](uint8_t domain) {
        uint256 value;
        for (size_t b{0}; b < 32; ++b) *(value.begin() + b) = static_cast<unsigned char>((i * 2654435761U + domain * 97U + b * 131U) >> (b % 4 * 8));
        return value.GetHex();
    };
    mapValue_t values;
    values["comment"] = "PoW Claim";
    values[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
    values[SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] = ToString(800000 + i);
    values[SHADOW_POW_CLAIM_CREATED_TIP_KEY] = hash(1);
    values[SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY] = SHADOW_POW_CLAIM_LINEAGE_SCHEMA_VERSION;
    values[SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY] = hash(2);
    values[SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY] = hash(3);
    values[SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY] = ToString(i % 3);
    if (i % 3 != 0) values[SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY] = hash(4);
    values[SHADOW_POW_CLAIM_RELAY_CLOCK_SCHEMA_KEY] = SHADOW_POW_CLAIM_RELAY_CLOCK_SCHEMA_VERSION;
    values[SHADOW_POW_CLAIM_RELAY_BIRTH_KEY] = ToString(int64_t{1763000000} + i * 64);
    values[SHADOW_POW_CLAIM_RELAY_TXID_KEY] = hash(5);
    values[SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY] = ToString(800000 + i);
    values[SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY] = hash(1);
    return values;
}

mapValue_t PayoutShapedValues(uint32_t i)
{
    mapValue_t values;
    // AnnotateWalletShadowPayout: comment, encoded payout address, marker.
    values["comment"] = "PoW - Quantum Claim";
    values["to"] = "B" + std::string(33, static_cast<char>('a' + i % 26));
    values["qq_synthetic_goldrush_payout"] = "1";
    return values;
}

#ifdef __APPLE__
struct HeapUse {
    size_t blocks;
    size_t bytes;
};
HeapUse CurrentHeapUse()
{
    malloc_statistics_t stats;
    malloc_zone_statistics(nullptr, &stats);
    return {stats.blocks_in_use, stats.size_in_use};
}
#endif
} // namespace

BOOST_FIXTURE_TEST_SUITE(txvaluemap_tests, BasicTestingSetup)

BOOST_AUTO_TEST_CASE(known_key_table_covers_the_claim_schema)
{
    // The table is checked sorted and unique at compile time. Every durable
    // claim key constant must be in it, or claims silently lose the saving.
    std::set<std::string> known;
    for (size_t id{0}; id < WalletTxValueMap::KnownKeyCount(); ++id) {
        BOOST_CHECK(known.emplace(WalletTxValueMap::KnownKey(id)).second);
    }
    for (const char* key : {
             SHADOW_POW_CLAIM_AUTHORED_KEY, SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY, SHADOW_POW_CLAIM_CREATED_TIP_KEY,
             SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY, SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY,
             SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY, SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY,
             SHADOW_POW_CLAIM_ADOPTED_KEY, SHADOW_POW_CLAIM_ADOPTION_TIP_KEY, SHADOW_POW_CLAIM_ADOPTION_FINGERPRINT_KEY,
             SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY, SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY, SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY,
             SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY, SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY,
             SHADOW_POW_RESOLUTION_SCHEMA_KEY, SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY, SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY,
             SHADOW_POW_RESOLUTION_FINGERPRINT_KEY, SHADOW_POW_RESOLUTION_ORIGIN_KEY, SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY,
             SHADOW_POW_RESOLUTION_CREATED_TIME_KEY, SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY, SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY,
             SHADOW_POW_RESOLUTION_AUTH_SCHEMA_KEY, SHADOW_POW_RESOLUTION_AUTH_PLAN_KEY, SHADOW_POW_RESOLUTION_AUTH_TIP_KEY,
             SHADOW_POW_RESOLUTION_AUTH_HEIGHT_KEY, SHADOW_POW_RESOLUTION_AUTH_GENERATION_KEY, SHADOW_POW_RESOLUTION_AUTH_ORIGIN_KEY,
             SHADOW_POW_RESOLUTION_AUTH_WTXID_KEY, SHADOW_POW_LEGACY_CLEANUP_FOR_KEY, SHADOW_POW_QUARANTINE_MARKER_KEY,
             SHADOW_POW_CLAIM_RELAY_CLOCK_SCHEMA_KEY, SHADOW_POW_CLAIM_RELAY_BIRTH_KEY, SHADOW_POW_CLAIM_RELAY_TXID_KEY}) {
        BOOST_CHECK_MESSAGE(known.count(key) == 1, key);
    }
}

BOOST_AUTO_TEST_CASE(every_writer_combination_serializes_as_before)
{
    const std::vector<WriterGroup> groups{WriterGroups()};
    const std::vector<std::string> probes{OddKeys()};
    // Every choice of "absent or one variant" per group. The full product is
    // 1,166,400 combinations and takes minutes; it runs when
    // RC13_FULL_WRITER_PRODUCT is set. By default every 11th combination is
    // checked: 11 is coprime to every group's choice count, so each pair of
    // choices from two different groups still occurs together.
    const uint32_t stride{std::getenv("RC13_FULL_WRITER_PRODUCT") ? 1U : 11U};
    std::vector<size_t> choice(groups.size(), 0);
    uint32_t combinations{0};
    uint32_t checked{0};
    while (true) {
        mapValue_t values;
        for (size_t g{0}; g < groups.size(); ++g) {
            if (choice[g] == 0) continue;
            for (const auto& [key, value] : groups[g].variants[choice[g] - 1]) values[key] = value;
        }
        if (combinations % stride == 0) {
            CheckSerializesLikeReference(values, combinations, probes, /*full_reads=*/checked % 53 == 0);
            ++checked;
        }
        ++combinations;
        size_t g{0};
        for (; g < groups.size(); ++g) {
            if (++choice[g] <= groups[g].variants.size()) break;
            choice[g] = 0;
        }
        if (g == groups.size()) break;
    }
    BOOST_TEST_MESSAGE("writer combinations: " << combinations << ", checked: " << checked);
    BOOST_CHECK_EQUAL(combinations, 1166400U);
    BOOST_CHECK(checked >= combinations / stride);
}

BOOST_AUTO_TEST_CASE(malformed_and_unknown_entries_are_kept_verbatim)
{
    const std::vector<std::string> odd_values{OddValues()};
    const std::vector<std::string> odd_keys{OddKeys()};
    std::vector<std::string> keys{odd_keys};
    for (size_t id{0}; id < WalletTxValueMap::KnownKeyCount(); ++id) keys.emplace_back(WalletTxValueMap::KnownKey(id));

    uint32_t salt{0};
    // Each key with each odd value, alone and next to a well-formed claim.
    mapValue_t claim;
    for (const WriterGroup& group : WriterGroups()) {
        for (const auto& [key, value] : group.variants.back()) claim[key] = value;
    }
    for (const std::string& key : keys) {
        for (const std::string& value : odd_values) {
            if (value.size() > 20000 && salt % 11 != 0) { ++salt; continue; }
            CheckSerializesLikeReference({{key, value}}, salt++, {});
            mapValue_t mixed{claim};
            mixed[key] = value;
            CheckSerializesLikeReference(mixed, salt++, {});
        }
    }
    // All odd keys and all known keys at once, values rotated through the odd list.
    mapValue_t everything;
    size_t next{0};
    for (const std::string& key : keys) everything[key] = odd_values[next++ % odd_values.size()];
    CheckSerializesLikeReference(everything, salt++, odd_keys);

    // The keys the serializer itself owns never reach the in-memory map, and
    // a stored record that carries them reads and rewrites as before.
    ReferenceWalletTx legacy{MakeReference({{"comment", "x"}, {"spent", "1"}}, 7)};
    DataStream stream;
    stream << legacy;
    CWalletTx loaded{nullptr, TxStateInactive{}};
    stream >> loaded;
    BOOST_CHECK(loaded.mapValue == (mapValue_t{{"comment", "x"}}));
    BOOST_CHECK_EQUAL(loaded.nOrderPos, legacy.nOrderPos);
    BOOST_CHECK_EQUAL(loaded.nTimeSmart, legacy.nTimeSmart);
    legacy.mapValue.erase("spent"); // rc12 drops it on load as well
    BOOST_CHECK(SerializeBytes(loaded) == SerializeBytes(legacy));
}

BOOST_AUTO_TEST_CASE(mutations_match_std_map)
{
    SeedInsecureRand(SeedRand::ZEROS);
    const std::vector<std::string> odd_values{OddValues()};
    std::vector<std::string> keys{OddKeys()};
    for (size_t id{0}; id < WalletTxValueMap::KnownKeyCount(); ++id) keys.emplace_back(WalletTxValueMap::KnownKey(id));
    const auto random_value = [&]() -> std::string {
        switch (InsecureRandRange(6)) {
        case 0: return InsecureRand256().GetHex();
        case 1: return ToString(InsecureRandBits(InsecureRandRange(64) + 1));
        case 2: return "1";
        case 3: return odd_values[InsecureRandRange(odd_values.size() - 3)];
        case 4: return ToUpper(InsecureRand256().GetHex());
        default: return "PoW Claim";
        }
    };
    for (int round{0}; round < 300; ++round) {
        mapValue_t model;
        WalletTxValueMap packed;
        for (int step{0}; step < 60; ++step) {
            const std::string key{keys[InsecureRandRange(keys.size())]};
            switch (InsecureRandRange(9)) {
            case 0:
            case 1:
            case 2: {
                const std::string value{random_value()};
                model[key] = value;
                packed[key] = value;
                break;
            }
            case 3:
                BOOST_CHECK_EQUAL(packed.erase(key), model.erase(key));
                break;
            case 4: {
                const std::string value{random_value()};
                BOOST_CHECK_EQUAL(packed.emplace(key, value), model.emplace(key, value).second);
                break;
            }
            case 5: {
                // operator[] used as a read inserts an empty value, as std::map does.
                const bool differs{packed[key] != "1"};
                BOOST_CHECK_EQUAL(differs, model[key] != "1");
                const std::string read = packed[key];
                BOOST_CHECK(read == model[key]);
                break;
            }
            case 6: {
                if (model.empty()) break;
                auto model_it = model.begin();
                std::advance(model_it, InsecureRandRange(model.size()));
                auto packed_it = packed.find(model_it->first);
                BOOST_REQUIRE(packed_it != packed.end());
                model_it = model.erase(model_it);
                packed_it = packed.erase(packed_it);
                BOOST_CHECK_EQUAL(packed_it == packed.end(), model_it == model.end());
                if (model_it != model.end()) BOOST_CHECK(packed_it->first == model_it->first && packed_it->second == model_it->second);
                break;
            }
            case 7: {
                // Erase everything under the claim prefix by iterator, as SyncMetaData does.
                static const std::string prefix{"qq_shadow_pow_"};
                for (auto it = packed.begin(); it != packed.end();) {
                    if (it->first.rfind(prefix, 0) == 0) { it = packed.erase(it); } else { ++it; }
                }
                for (auto it = model.begin(); it != model.end();) {
                    if (it->first.rfind(prefix, 0) == 0) { it = model.erase(it); } else { ++it; }
                }
                break;
            }
            default:
                if (InsecureRandRange(20) == 0) {
                    model.clear();
                    packed.clear();
                } else {
                    WalletTxValueMap copy{packed};
                    WalletTxValueMap moved{std::move(copy)};
                    packed = moved;
                    BOOST_CHECK(packed == moved);
                }
                break;
            }
            BOOST_REQUIRE(packed == model);
        }
        CheckReadsLikeMap(packed, model, {});
        CheckSerializesLikeReference(model, static_cast<uint32_t>(round), {});
    }
}

BOOST_AUTO_TEST_CASE(packed_values_are_exactly_the_canonical_ones)
{
    // The storage cost tells which form a value took: a packed hash costs
    // 2 + 32 bytes and a packed number 2 + its varint, under a known key.
    const auto cost = [](const std::string& value) {
        WalletTxValueMap map;
        map[SHADOW_POW_CLAIM_CREATED_TIP_KEY] = value;
        BOOST_CHECK(map.at(SHADOW_POW_CLAIM_CREATED_TIP_KEY) == value);
        return map.DynamicMemoryUsage() - sizeof(uint32_t);
    };
    BOOST_CHECK_EQUAL(cost(Hex(1)), 34U);
    BOOST_CHECK_EQUAL(cost(std::string(64, 'f')), 34U);
    BOOST_CHECK_EQUAL(cost(ToUpper(std::string(64, 'f'))), 2U + 1U + 64U);
    BOOST_CHECK_EQUAL(cost(std::string(63, 'f')), 2U + 1U + 63U);
    BOOST_CHECK_EQUAL(cost("0"), 3U);
    BOOST_CHECK_EQUAL(cost("127"), 3U);
    BOOST_CHECK_EQUAL(cost("128"), 4U);
    BOOST_CHECK_EQUAL(cost("18446744073709551615"), 12U);
    BOOST_CHECK_EQUAL(cost("18446744073709551616"), 2U + 1U + 20U);
    BOOST_CHECK_EQUAL(cost("007"), 2U + 1U + 3U);
    BOOST_CHECK_EQUAL(cost("+7"), 2U + 1U + 2U);
    BOOST_CHECK_EQUAL(cost("-7"), 2U + 1U + 2U);
    BOOST_CHECK_EQUAL(cost(" 7"), 2U + 1U + 2U);
    BOOST_CHECK_EQUAL(cost(""), 3U);
    BOOST_CHECK(WalletTxValueMap{}.DynamicMemoryUsage() == 0);

    // Moving a std::map in empties it, and moving a packed map out empties it.
    mapValue_t source{{"comment", "x"}, {SHADOW_POW_CLAIM_AUTHORED_KEY, "1"}};
    const mapValue_t expected{source};
    WalletTxValueMap target;
    target = std::move(source);
    BOOST_CHECK(source.empty());
    BOOST_CHECK(target == expected);
    WalletTxValueMap moved;
    moved = std::move(target);
    BOOST_CHECK(target.empty());
    BOOST_CHECK(moved == expected);
    WalletTxValueMap self{moved};
    self = *&self;
    BOOST_CHECK(self == expected);
    BOOST_CHECK_EQUAL(sizeof(WalletTxValueMap), sizeof(void*));
}

// Not an assertion of exact numbers (the allocator's size classes differ by
// platform): it prints the measurement and checks the saving is the order of
// magnitude the change exists for.
BOOST_AUTO_TEST_CASE(memory_per_claim_measurement)
{
#ifdef __APPLE__
    constexpr uint32_t RECORDS{50000};
    for (const bool claims : {true, false}) {
        std::vector<mapValue_t> before;
        std::vector<WalletTxValueMap> after;
        before.reserve(RECORDS);
        after.reserve(RECORDS);
        size_t pairs{0};

        const HeapUse start{CurrentHeapUse()};
        for (uint32_t i{0}; i < RECORDS; ++i) before.push_back(claims ? ClaimShapedValues(i) : PayoutShapedValues(i));
        const HeapUse with_maps{CurrentHeapUse()};
        for (uint32_t i{0}; i < RECORDS; ++i) {
            after.emplace_back(before[i]);
            pairs += before[i].size();
        }
        const HeapUse with_both{CurrentHeapUse()};

        const double map_bytes{double(with_maps.bytes - start.bytes) / RECORDS};
        const double map_blocks{double(with_maps.blocks - start.blocks) / RECORDS};
        const double packed_bytes{double(with_both.bytes - with_maps.bytes) / RECORDS};
        const double packed_blocks{double(with_both.blocks - with_maps.blocks) / RECORDS};
        BOOST_TEST_MESSAGE(strprintf(
            "%s x %u (%.1f pairs each): std::map %.0f heap bytes in %.1f allocations per record (+%u inline); "
            "packed %.0f heap bytes in %.1f allocations per record (+%u inline); saved %.0f bytes, %.1f allocations per record",
            claims ? "claim-shaped mapValue" : "payout-shaped mapValue", RECORDS, double(pairs) / RECORDS,
            map_bytes, map_blocks, unsigned(sizeof(mapValue_t)), packed_bytes, packed_blocks, unsigned(sizeof(WalletTxValueMap)),
            map_bytes + sizeof(mapValue_t) - packed_bytes - sizeof(WalletTxValueMap), map_blocks - packed_blocks));
        BOOST_CHECK(packed_blocks < 1.01);
        BOOST_CHECK(packed_bytes * (claims ? 5 : 2) < map_bytes);
        for (uint32_t i{0}; i < RECORDS; i += 997) BOOST_CHECK(after[i] == before[i]);
    }
    BOOST_TEST_MESSAGE(strprintf("sizeof(CWalletTx) = %u", unsigned(sizeof(CWalletTx))));
#else
    BOOST_TEST_MESSAGE("heap measurement uses malloc_zone_statistics and runs on macOS only");
#endif
}

BOOST_AUTO_TEST_SUITE_END()

/**
 * Differential test over a wallet database: every transaction record written
 * by the previous format is loaded by this code, written again, and compared
 * byte for byte. By default the records are a few hundred claim, payout,
 * resolution and malformed records built with the reference serializer. Set
 * RC13_DIFF_WALLET to a wallet database file (a copy: it is opened, never
 * modified through this test, but SQLite may touch its journal) to run the
 * same comparison over a real wallet.
 */
BOOST_FIXTURE_TEST_SUITE(txvaluemap_wallet_db_tests, TestChain100Setup)

namespace {
MockableData TxRecords(const MockableData& records)
{
    MockableData result;
    for (const auto& [key, value] : records) {
        DataStream stream{key};
        std::string type;
        try {
            stream >> type;
        } catch (const std::exception&) {
            continue;
        }
        if (type == DBKeys::TX) result.emplace(key, value);
    }
    return result;
}
} // namespace

BOOST_AUTO_TEST_CASE(load_and_rewrite_keeps_every_transaction_record)
{
    MockableData records;
    size_t expected_txs{0};
    if (const char* path = std::getenv("RC13_DIFF_WALLET")) {
        DatabaseOptions options;
        options.require_existing = true;
        DatabaseStatus status;
        bilingual_str error;
        std::unique_ptr<WalletDatabase> database{MakeDatabase(fs::PathFromString(path), options, status, error)};
        BOOST_REQUIRE_MESSAGE(database, error.original);
        std::unique_ptr<DatabaseBatch> batch{database->MakeBatch()};
        std::unique_ptr<DatabaseCursor> cursor{batch->GetNewCursor()};
        BOOST_REQUIRE(cursor);
        while (true) {
            DataStream key, value;
            const DatabaseCursor::Status next{cursor->Next(key, value)};
            if (next == DatabaseCursor::Status::DONE) break;
            BOOST_REQUIRE(next == DatabaseCursor::Status::MORE);
            records.emplace(SerializeData{key.begin(), key.end()}, SerializeData{value.begin(), value.end()});
        }
        expected_txs = TxRecords(records).size();
        BOOST_TEST_MESSAGE(strprintf("RC13_DIFF_WALLET=%s: %u records, %u transaction records", path, unsigned(records.size()), unsigned(expected_txs)));
    } else {
        std::vector<mapValue_t> shapes;
        for (uint32_t i{0}; i < 300; ++i) shapes.push_back(ClaimShapedValues(i));
        for (uint32_t i{0}; i < 300; ++i) shapes.push_back(PayoutShapedValues(i));
        for (const WriterGroup& group : WriterGroups()) {
            for (const auto& variant : group.variants) shapes.emplace_back(variant.begin(), variant.end());
        }
        const std::vector<std::string> odd_values{OddValues()};
        const std::vector<std::string> odd_keys{OddKeys()};
        for (size_t i{0}; i < odd_values.size(); ++i) {
            mapValue_t odd{ClaimShapedValues(static_cast<uint32_t>(1000 + i))};
            odd[SHADOW_POW_CLAIM_CREATED_TIP_KEY] = odd_values[i];
            odd[SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] = odd_values[(i + 7) % odd_values.size()];
            odd[odd_keys[i % odd_keys.size()]] = odd_values[(i + 3) % odd_values.size()];
            shapes.push_back(std::move(odd));
        }
        uint32_t salt{1};
        for (const mapValue_t& values : shapes) {
            ReferenceWalletTx reference{MakeReference(values, salt)};
            // Every record carries its order position, as a wallet that has
            // been loaded once does; otherwise loading reorders and rewrites.
            reference.nOrderPos = salt;
            // Confirmed records sit in blocks of the active chain, so loading
            // keeps their state (a record confirmed in an unknown block is
            // deactivated in memory at load, by rc12 as well). A confirmed
            // synthetic payout that its block does not authenticate is marked
            // stale and rewritten at load, also as before, so payout records
            // stay unconfirmed here.
            const bool payout{values.count("qq_synthetic_goldrush_payout") != 0};
            if (payout) {
                reference.m_state = TxStateInactive{};
            } else if (salt % 2 == 0) {
                const int height{static_cast<int>(1 + salt % 100)};
                const uint256 block_hash{WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain()[height]->GetBlockHash())};
                reference.m_state = TxStateConfirmed{block_hash, height, static_cast<int>(1 + salt % 3)};
            } else if (salt % 4 == 1) {
                reference.m_state = TxStateInactive{/*abandoned=*/true};
            }
            ++salt;
            DataStream key, value;
            key << std::make_pair(DBKeys::TX, reference.tx->GetHash());
            value << reference;
            BOOST_REQUIRE(records.emplace(SerializeData{key.begin(), key.end()}, SerializeData{value.begin(), value.end()}).second);
        }
        expected_txs = shapes.size();
    }
    const MockableData original{TxRecords(records)};
    BOOST_REQUIRE_EQUAL(original.size(), expected_txs);
    BOOST_REQUIRE(expected_txs > 0);

    CWallet wallet{m_node.chain.get(), "", CreateMockableWalletDatabase(records)};
    const DBErrors load_result{wallet.LoadWallet()};
    BOOST_TEST_MESSAGE(strprintf("LoadWallet returned %d", int(load_result)));
    LOCK(wallet.cs_wallet);
    BOOST_CHECK_EQUAL(wallet.mapWallet.size(), expected_txs);

    // Loading alone must not have changed a record that it did not change before.
    const MockableData after_load{TxRecords(GetMockableDatabase(wallet).m_records)};
    size_t changed_by_load{0};
    for (const auto& [key, value] : original) {
        const auto it = after_load.find(key);
        if (it == after_load.end() || it->second != value) ++changed_by_load;
    }
    BOOST_TEST_MESSAGE(strprintf("records changed by loading: %u", unsigned(changed_by_load)));
    if (!std::getenv("RC13_DIFF_WALLET")) BOOST_CHECK_EQUAL(changed_by_load, 0U);

    // Force a rewrite of every transaction record from memory.
    {
        WalletBatch batch{wallet.GetDatabase()};
        for (const auto& [txid, wtx] : wallet.mapWallet) {
            BOOST_REQUIRE(batch.WriteTx(wtx));
        }
    }
    const MockableData rewritten{TxRecords(GetMockableDatabase(wallet).m_records)};
    BOOST_CHECK_EQUAL(rewritten.size(), after_load.size());
    size_t different{0};
    for (const auto& [key, value] : after_load) {
        const auto it = rewritten.find(key);
        if (it == rewritten.end() || it->second != value) ++different;
    }
    BOOST_CHECK_EQUAL(different, 0U);
    size_t different_from_original{0};
    for (const auto& [key, value] : original) {
        const auto it = rewritten.find(key);
        if (it == rewritten.end() || it->second != value) ++different_from_original;
    }
    BOOST_TEST_MESSAGE(strprintf("transaction records: %u, rewritten differently from loaded: %u, from original file: %u",
                                 unsigned(original.size()), unsigned(different), unsigned(different_from_original)));
    BOOST_CHECK_EQUAL(different_from_original, changed_by_load);
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
