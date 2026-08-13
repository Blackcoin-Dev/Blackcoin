// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/shadow_pow_claim_recovery.h>

#include <chain.h>
#include <chainparams.h>
#include <coins.h>
#include <common/system.h>
#include <hash.h>
#include <key_io.h>
#include <policy/policy.h>
#include <shadow.h>
#include <util/strencodings.h>
#include <util/time.h>
#include <util/translation.h>
#include <validation.h>
#include <wallet/coincontrol.h>
#include <wallet/fees.h>
#include <wallet/spend.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>

#include <algorithm>
#include <limits>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace wallet {
namespace {

bool SafeGraphForAdoption(
    const ShadowPowClaimRecoveryComponent& component,
    std::string& reason_code, std::string& reason);

bool MetadataFlag(const mapValue_t& values, const char* key)
{
    const auto it = values.find(key);
    return it != values.end() && it->second == "1";
}

bool IsRepairableShadowPowRelayFeePolicyRejection(
    const TxValidationState& state)
{
    if (!state.IsInvalid() ||
        state.GetResult() != TxValidationResult::TX_MEMPOOL_POLICY) {
        return false;
    }
    const std::string& reason = state.GetRejectReason();
    return reason == "min fee not met" ||
           reason == "min relay fee not met";
}

bool ParseCanonicalMetadataBool(const mapValue_t& values, const char* key,
                                bool& value)
{
    const auto it = values.find(key);
    if (it == values.end()) {
        value = false;
        return true;
    }
    if (it->second == "0") {
        value = false;
        return true;
    }
    if (it->second == "1") {
        value = true;
        return true;
    }
    return false;
}

bool ParseMetadataHeight(const mapValue_t& values, const char* key, int& value)
{
    const auto it = values.find(key);
    int32_t parsed{-1};
    if (it == values.end() || !ParseInt32(it->second, &parsed) || parsed < 0) {
        return false;
    }
    value = parsed;
    return true;
}

bool ParseMetadataHash(const mapValue_t& values, const char* key, uint256& value)
{
    const auto it = values.find(key);
    if (it == values.end() || it->second.size() != uint256::size() * 2 ||
        !IsHex(it->second)) {
        return false;
    }
    value.SetHex(it->second);
    return !value.IsNull();
}

bool ParseMetadataVout(const mapValue_t& values, const char* key, uint32_t& value)
{
    const auto it = values.find(key);
    return it != values.end() && ParseUInt32(it->second, &value);
}

bool ParseMetadataOrdinal(const mapValue_t& values, const char* key,
                          uint32_t& value)
{
    const auto it = values.find(key);
    return it != values.end() && ParseUInt32(it->second, &value);
}

bool ParsePositiveMetadataTime(const mapValue_t& values, const char* key,
                               int64_t& value)
{
    const auto it = values.find(key);
    int64_t parsed{0};
    if (it == values.end() || !ParseInt64(it->second, &parsed) || parsed <= 0) {
        return false;
    }
    value = parsed;
    return true;
}

bool HasActiveBranchObservation(const mapValue_t& values,
                                const char* height_key,
                                const char* tip_key,
                                const CChain& active_chain)
{
    int height{-1};
    uint256 block_hash;
    if (!ParseMetadataHeight(values, height_key, height) ||
        !ParseMetadataHash(values, tip_key, block_hash) ||
        height > active_chain.Height()) {
        return false;
    }
    const CBlockIndex* observed = active_chain[height];
    return observed && observed->GetBlockHash() == block_hash;
}

ShadowPowClaimRecoveryProvenance ClaimProvenance(
    const CWalletTx& wtx, ShadowPowClaimRecoveryNode& node,
    const uint256* generation_fingerprint = nullptr)
{
    node.authored_metadata_valid =
        ParseMetadataHeight(wtx.mapValue,
                            SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY,
                            node.created_height) &&
        ParseMetadataHash(wtx.mapValue,
                          SHADOW_POW_CLAIM_CREATED_TIP_KEY,
                          node.created_tip);
    if (MetadataFlag(wtx.mapValue, SHADOW_POW_CLAIM_AUTHORED_KEY) &&
        node.authored_metadata_valid) {
        return ShadowPowClaimRecoveryProvenance::EXPLICIT_AUTHORED;
    }

    uint256 adoption_fingerprint;
    const bool adoption_metadata_complete =
        ParseMetadataHash(wtx.mapValue,
                          SHADOW_POW_CLAIM_ADOPTION_TIP_KEY,
                          node.adoption_tip) &&
        ParseMetadataHash(wtx.mapValue,
                          SHADOW_POW_CLAIM_ADOPTION_FINGERPRINT_KEY,
                          adoption_fingerprint);
    node.adoption_generation_fingerprint = adoption_fingerprint;
    node.adoption_metadata_valid =
        adoption_metadata_complete && generation_fingerprint &&
        !generation_fingerprint->IsNull() &&
        adoption_fingerprint == *generation_fingerprint;
    if (MetadataFlag(wtx.mapValue, SHADOW_POW_CLAIM_ADOPTED_KEY) &&
        node.adoption_metadata_valid) {
        return ShadowPowClaimRecoveryProvenance::EXPLICIT_ADOPTED;
    }
    const auto comment = wtx.mapValue.find("comment");
    if (wtx.fFromMe && comment != wtx.mapValue.end() &&
        comment->second == "PoW Claim") {
        return ShadowPowClaimRecoveryProvenance::LEGACY_WALLET_AUTHORED;
    }
    return ShadowPowClaimRecoveryProvenance::UNKNOWN;
}

void ParseClaimLineage(const CWalletTx& wtx,
                       const uint256& generation_fingerprint,
                       ShadowPowClaimRecoveryNode& node)
{
    const mapValue_t& values = wtx.mapValue;
    node.lineage_metadata_present =
        values.count(SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY) != 0 ||
        values.count(SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY) != 0 ||
        values.count(SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY) != 0 ||
        values.count(SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY) != 0 ||
        values.count(SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY) != 0;
    if (!node.lineage_metadata_present) return;

    const auto schema = values.find(SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY);
    uint256 family;
    uint256 root;
    uint256 parent;
    uint32_t ordinal{0};
    const bool common_metadata_valid =
        schema != values.end() &&
        schema->second == SHADOW_POW_CLAIM_LINEAGE_SCHEMA_VERSION &&
        ParseMetadataHash(values, SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY,
                          family) &&
        ParseMetadataHash(values, SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY, root) &&
        ParseMetadataOrdinal(values, SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY,
                             ordinal) &&
        !generation_fingerprint.IsNull() && family == generation_fingerprint;
    const auto parent_value = values.find(
        SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY);
    const bool root_metadata_valid = ordinal == 0 && root == node.txid &&
                                     parent_value == values.end();
    const bool child_metadata_valid = ordinal > 0 &&
        ParseMetadataHash(values, SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY,
                          parent);
    node.lineage_metadata_valid = common_metadata_valid &&
        (root_metadata_valid || child_metadata_valid);
    node.lineage_family_fingerprint = family;
    node.lineage_root_txid = root;
    node.lineage_parent_txid = parent;
    node.lineage_ordinal = ordinal;
}

bool IsExplicitProvenance(ShadowPowClaimRecoveryProvenance provenance)
{
    return provenance == ShadowPowClaimRecoveryProvenance::EXPLICIT_AUTHORED ||
           provenance == ShadowPowClaimRecoveryProvenance::EXPLICIT_ADOPTED;
}

void SortUnique(std::vector<uint256>& values)
{
    std::sort(values.begin(), values.end());
    values.erase(std::unique(values.begin(), values.end()), values.end());
}

uint256 FingerprintComponent(const uint256& active_tip,
                             const ShadowPowClaimRecoveryComponent& component)
{
    HashWriter hasher{};
    hasher << uint8_t{1};
    hasher << active_tip;
    hasher << component.generation_fingerprint;
    hasher << component.anchor;
    hasher << component.anchor_amount;
    hasher << component.anchor_script;
    hasher << static_cast<uint8_t>(component.state);
    hasher << component.anchor_authenticated;
    hasher << component.anchor_unspent;
    hasher << component.anchor_user_locked;
    hasher << component.all_claims_quarantined;
    hasher << component.all_claims_explicitly_provenanced;
    hasher << component.has_live_claim;
    hasher << component.has_transient_claim;
    hasher << component.has_revalidating_unbound_proof;
    hasher << component.has_indeterminate_node;
    hasher << component.has_managed_resolution;
    hasher << component.has_legacy_resolution;
    hasher << component.has_live_resolution;
    hasher << component.all_claims_terminal_on_pinned_tip;
    hasher << component.all_claims_zero_payment_retirable;
    hasher << component.all_claims_expired_locally_retired;
    hasher << component.has_branch_relative_ineligibility;
    hasher << static_cast<uint64_t>(component.descendant_claims);
    hasher << component.minimum_stale_depth;
    hasher << component.stale_depth_known;
    hasher << static_cast<uint64_t>(component.nodes.size());
    for (const ShadowPowClaimRecoveryNode& node : component.nodes) {
        hasher << node.txid;
        hasher << static_cast<uint8_t>(node.kind);
        hasher << static_cast<uint8_t>(node.provenance);
        hasher << static_cast<uint8_t>(node.disposition);
        hasher << node.proof_may_revalidate_on_descendant;
        hasher << node.active_chain_confirmed;
        hasher << node.in_mempool;
        hasher << node.abandoned;
        hasher << node.quarantined;
        hasher << node.expired_locally_retired;
        hasher << node.expected_shape;
        hasher << node.wallet_authored;
        hasher << node.wallet_from_me;
        hasher << node.created_height;
        hasher << node.created_tip;
        hasher << node.authored_metadata_valid;
        hasher << node.authored_tip_active_branch_bound;
        hasher << node.claim_descriptor_valid;
        hasher << node.proof_evaluation_skipped_resolved_anchor;
        hasher << node.proof_version;
        hasher << static_cast<uint8_t>(node.proof_mode);
        hasher << node.proof_origin_bound;
        hasher << node.proof_origin_height;
        hasher << node.proof_origin_previous_block_hash;
        hasher << node.proof_input_bound;
        hasher << node.proof_output_index;
        hasher << node.proof_target;
        hasher << node.proof_payout_script;
        hasher << node.claim_fee;
        hasher << node.exact_authored_carrier_shape;
        hasher << node.relay_ttl_expired;
        hasher << node.relay_expiry_time;
        hasher << node.lineage_metadata_present;
        hasher << node.lineage_metadata_valid;
        hasher << node.lineage_family_fingerprint;
        hasher << node.lineage_root_txid;
        hasher << node.lineage_parent_txid;
        hasher << node.lineage_ordinal;
        hasher << node.adoption_tip;
        hasher << node.adoption_generation_fingerprint;
        hasher << node.adoption_metadata_valid;
        hasher << node.first_quarantine_height;
        hasher << node.branch_quarantine_height;
        hasher << node.stale_depth;
        hasher << node.stale_depth_known;
        hasher << node.resolution_metadata_valid;
        hasher << node.resolution_generation_fingerprint;
        hasher << node.resolution_origin;
        hasher << node.resolution_created_height;
        hasher << node.resolution_created_time;
        hasher << node.resolution_relay_authorized;
        hasher << node.resolution_relay_revoked;
    }
    return hasher.GetHash();
}

uint256 FingerprintClaimGeneration(
    const ShadowPowClaimRecoveryComponent& component)
{
    if (!component.anchor_authenticated || component.anchor.IsNull()) {
        return {};
    }
    return ComputeShadowPowClaimLineageFamilyFingerprint(
        component.anchor, component.anchor_amount, component.anchor_script);
}

struct ManagedResolutionFacts
{
    COutPoint anchor;
    uint256 generation_fingerprint;
    std::string origin;
    int created_height{-1};
    int64_t created_time{0};
    bool relay_authorized{false};
    bool relay_revoked{false};
    CAmount fee{0};
};

/** Parse and authenticate a managed resolution from durable wallet facts.
 * This deliberately does not depend on a surviving unconfirmed claim being
 * present in the current component inventory: an original claim may confirm
 * first while the conflicting resolution record and its rolling budget usage
 * must remain visible across restart and reorg. */
bool ParseManagedResolutionFacts(const CWallet& wallet, const CWalletTx& wtx,
                                 ManagedResolutionFacts& facts)
{
    AssertLockHeld(wallet.cs_wallet);
    if (!wtx.tx ||
        wtx.mapValue.find(SHADOW_POW_RESOLUTION_SCHEMA_KEY) ==
            wtx.mapValue.end() ||
        wtx.mapValue.at(SHADOW_POW_RESOLUTION_SCHEMA_KEY) !=
            SHADOW_POW_RESOLUTION_SCHEMA_VERSION) {
        return false;
    }

    uint256 anchor_hash;
    uint32_t anchor_vout{0};
    const auto origin = wtx.mapValue.find(
        SHADOW_POW_RESOLUTION_ORIGIN_KEY);
    if (origin == wtx.mapValue.end() ||
        (origin->second != SHADOW_POW_RESOLUTION_ORIGIN_MANUAL &&
         origin->second != SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC) ||
        !ParseMetadataHash(wtx.mapValue,
                           SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY,
                           anchor_hash) ||
        !ParseMetadataVout(wtx.mapValue,
                           SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY,
                           anchor_vout) ||
        !ParseMetadataHash(wtx.mapValue,
                           SHADOW_POW_RESOLUTION_FINGERPRINT_KEY,
                           facts.generation_fingerprint) ||
        !ParseMetadataHeight(wtx.mapValue,
                             SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY,
                             facts.created_height) ||
        !ParsePositiveMetadataTime(wtx.mapValue,
                                   SHADOW_POW_RESOLUTION_CREATED_TIME_KEY,
                                   facts.created_time) ||
        !ParseCanonicalMetadataBool(
            wtx.mapValue, SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY,
            facts.relay_authorized) ||
        !ParseCanonicalMetadataBool(
            wtx.mapValue, SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY,
            facts.relay_revoked) ||
        (facts.relay_authorized && facts.relay_revoked)) {
        return false;
    }
    facts.anchor = COutPoint{anchor_hash, anchor_vout};
    facts.origin = origin->second;

    const auto parent = wallet.mapWallet.find(anchor_hash);
    if (parent == wallet.mapWallet.end() || !parent->second.tx ||
        anchor_vout >= parent->second.tx->vout.size()) {
        return false;
    }
    const CTxOut& anchor_output = parent->second.tx->vout[anchor_vout];
    ShadowPowClaimRecoveryComponent generation;
    generation.anchor = facts.anchor;
    generation.anchor_amount = anchor_output.nValue;
    generation.anchor_script = anchor_output.scriptPubKey;
    generation.anchor_authenticated = true;
    if (facts.generation_fingerprint !=
        FingerprintClaimGeneration(generation)) {
        return false;
    }

    const CTransaction& tx = *wtx.tx;
    if (tx.vin.size() != 1 || tx.vin.front().prevout != facts.anchor ||
        tx.vin.front().nSequence != CTxIn::SEQUENCE_FINAL ||
        tx.vout.size() != 1 || tx.vout.front().nValue <= 0 ||
        tx.vout.front().nValue > anchor_output.nValue ||
        tx.vout.front().scriptPubKey != anchor_output.scriptPubKey) {
        return false;
    }
    facts.fee = anchor_output.nValue - tx.vout.front().nValue;
    return facts.fee > 0 && MoneyRange(facts.fee);
}

} // namespace

uint256 ComputeShadowPowClaimLineageFamilyFingerprint(
    const COutPoint& anchor, CAmount anchor_amount,
    const CScript& anchor_script)
{
    if (anchor.IsNull() || anchor_amount <= 0 ||
        !MoneyRange(anchor_amount) || anchor_script.empty()) {
        return {};
    }
    HashWriter hasher{};
    hasher << uint8_t{1};
    hasher << anchor;
    hasher << anchor_amount;
    hasher << anchor_script;
    return hasher.GetHash();
}

ShadowPowClaimRecoveryInventory CWallet::GetShadowPowClaimRecoveryInventory() const
{
    if (!HaveChain() || !chain().isReadyToBroadcast()) {
        ShadowPowClaimRecoveryInventory inventory;
        LOCK(cs_wallet);
        inventory.recovery_database_ambiguous =
            m_shadow_pow_claim_recovery_db_ambiguous ||
            m_locked_coins_db_ambiguous;
        inventory.wallet_processed_tip = m_last_block_processed;
        inventory.wallet_processed_height = m_last_block_processed_height;
        inventory.wallet_generation = GetDatabase().nUpdateCounter.load();
        for (const auto& [txid, wtx] : mapWallet) {
            if (!wtx.tx || GetTxDepthInMainChain(wtx) > 0 ||
                !TransactionHasShadowProof(*wtx.tx)) {
                continue;
            }

            ShadowPowClaimRecoveryNode node;
            node.txid = txid;
            node.kind = ShadowPowClaimRecoveryNodeKind::CLAIM;
            node.provenance = ClaimProvenance(wtx, node);
            node.in_mempool = wtx.InMempool();
            node.quarantined = MetadataFlag(
                wtx.mapValue, SHADOW_POW_QUARANTINE_MARKER_KEY);
            node.wallet_authored = GetDebit(*wtx.tx, ISMINE_SPENDABLE) > 0;
            node.wallet_from_me = wtx.fFromMe;
            node.expected_shape = wtx.tx->vin.size() == 1 &&
                                  !wtx.tx->vin.front().prevout.IsNull() &&
                                  !wtx.tx->IsCoinBase() &&
                                  !wtx.tx->IsCoinStake();
            ParseMetadataHeight(wtx.mapValue,
                                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY,
                                node.first_quarantine_height);

            ShadowPowClaimRecoveryComponent component;
            component.nodes.push_back(node);
            component.claim_txids.push_back(txid);
            component.has_indeterminate_node = true;
            component.all_claims_quarantined = node.quarantined;
            component.all_claims_explicitly_provenanced =
                IsExplicitProvenance(node.provenance);
            component.fingerprint = FingerprintComponent({}, component);
            inventory.components.push_back(std::move(component));
            inventory.unanchored_claim_txids.push_back(txid);
            ++inventory.raw_claim_objects;
            if (wtx.InMempool()) ++inventory.live_claim_objects;
            if (node.quarantined) ++inventory.quarantined_claim_objects;
            ++inventory.blocking_components;
        }
        SortUnique(inventory.unanchored_claim_txids);
        return inventory;
    }

    LOCK2(::cs_main, cs_wallet);
    return GetShadowPowClaimRecoveryInventoryLocked();
}

uint256 CWallet::GetShadowPowClaimCandidateStateFingerprintLocked() const
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(cs_wallet);
    HashWriter hasher{};
    // Relay eligibility changes at a wall-clock boundary without mutating the
    // wallet. Hash that derived phase so snapshot-local family suppression and
    // worker WAIT caches expire into a same-anchor refresh on a stalled tip.
    const int64_t now = GetTime();
    hasher << uint8_t{2};
    hasher << m_coin_lock_generation;
    hasher << m_locked_coins_db_ambiguous;
    size_t candidates{0};
    for (const auto& [txid, wtx] : mapWallet) {
        if (!wtx.tx || GetTxDepthInMainChain(wtx) > 0 ||
            !TransactionHasShadowProof(*wtx.tx)) {
            continue;
        }
        ++candidates;
        hasher << txid;
        hasher << GetTxDepthInMainChain(wtx);
        hasher << wtx.InMempool();
        hasher << wtx.isAbandoned();
        hasher << wtx.fFromMe;
        hasher << wtx.nTimeReceived;
        hasher << (wtx.nTimeReceived <= 0 ||
                   wtx.nTimeReceived <=
                       now - SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS);
        hasher << wtx.mapValue;
    }
    hasher << static_cast<uint64_t>(candidates);
    return hasher.GetHash();
}

ShadowPowClaimRecoveryInventory CWallet::GetShadowPowClaimRecoveryInventoryLocked() const
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(cs_wallet);

    ShadowPowClaimRecoveryInventory inventory;
    ChainstateManager& chainman = chain().chainman();
    const CChain& active_chain = chainman.ActiveChain();
    const CBlockIndex* tip = active_chain.Tip();
    if (tip) {
        inventory.active_tip = tip->GetBlockHash();
        inventory.active_height = tip->nHeight;
    }
    inventory.wallet_processed_tip = m_last_block_processed;
    inventory.wallet_processed_height = m_last_block_processed_height;
    inventory.wallet_generation = GetDatabase().nUpdateCounter.load();
    inventory.candidate_state_fingerprint =
        GetShadowPowClaimCandidateStateFingerprintLocked();
    inventory.recovery_database_ambiguous =
        m_shadow_pow_claim_recovery_db_ambiguous ||
        m_locked_coins_db_ambiguous;
    inventory.wallet_tip_matches = tip &&
                                   m_last_block_processed == inventory.active_tip;

    std::vector<uint256> candidate_claims;
    for (const auto& [txid, wtx] : mapWallet) {
        if (!wtx.tx || GetTxDepthInMainChain(wtx) > 0 ||
            !TransactionHasShadowProof(*wtx.tx)) {
            continue;
        }
        candidate_claims.push_back(txid);
        ++inventory.raw_claim_objects;
        if (wtx.InMempool()) ++inventory.live_claim_objects;
        if (MetadataFlag(wtx.mapValue, SHADOW_POW_QUARANTINE_MARKER_KEY)) {
            ++inventory.quarantined_claim_objects;
        }
    }
    std::sort(candidate_claims.begin(), candidate_claims.end());
    if (candidate_claims.empty()) return inventory;

    // A wallet/chain tip mismatch makes every inference stale. Preserve all
    // locally relevant records as individually blocking, without walking or
    // querying an active-chain view that the wallet has not processed yet.
    if (!inventory.wallet_tip_matches) {
        for (const uint256& txid : candidate_claims) {
            const CWalletTx& wtx = mapWallet.at(txid);
            ShadowPowClaimRecoveryNode node;
            node.txid = txid;
            node.kind = ShadowPowClaimRecoveryNodeKind::CLAIM;
            node.provenance = ClaimProvenance(wtx, node);
            node.in_mempool = wtx.InMempool();
            node.quarantined = MetadataFlag(
                wtx.mapValue, SHADOW_POW_QUARANTINE_MARKER_KEY);
            node.wallet_authored = GetDebit(*wtx.tx, ISMINE_SPENDABLE) > 0;
            node.wallet_from_me = wtx.fFromMe;
            node.expected_shape = wtx.tx->vin.size() == 1 &&
                                  !wtx.tx->vin.front().prevout.IsNull() &&
                                  !wtx.tx->IsCoinBase() &&
                                  !wtx.tx->IsCoinStake();

            ShadowPowClaimRecoveryComponent component;
            component.nodes.push_back(node);
            component.claim_txids.push_back(txid);
            component.has_indeterminate_node = true;
            component.all_claims_quarantined = node.quarantined;
            component.all_claims_explicitly_provenanced =
                IsExplicitProvenance(node.provenance);
            component.fingerprint = FingerprintComponent(
                inventory.active_tip, component);
            inventory.components.push_back(std::move(component));
            inventory.unanchored_claim_txids.push_back(txid);
            ++inventory.blocking_components;
        }
        return inventory;
    }

    struct ClaimPath {
        COutPoint anchor;
        CAmount amount{0};
        CScript script;
        bool authenticated{false};
    };
    std::map<uint256, ClaimPath> paths;

    // Canonicalize each claim to its nearest active-chain-confirmed,
    // wallet-owned ancestor output. Only wallet-authored proof transactions
    // may form the inactive ancestry between a claim and that anchor.
    for (const uint256& candidate_txid : candidate_claims) {
        const CWalletTx* current = &mapWallet.at(candidate_txid);
        std::set<uint256> seen;
        ClaimPath path;
        while (current && current->tx) {
            if (!seen.insert(current->GetHash()).second ||
                current->tx->vin.size() != 1 ||
                current->tx->vin.front().prevout.IsNull()) {
                break;
            }

            const COutPoint prevout = current->tx->vin.front().prevout;
            path.anchor = prevout;
            const auto parent_it = mapWallet.find(prevout.hash);
            if (parent_it == mapWallet.end() || !parent_it->second.tx ||
                prevout.n >= parent_it->second.tx->vout.size()) {
                break;
            }

            const CWalletTx& parent = parent_it->second;
            const CTxOut& parent_output = parent.tx->vout[prevout.n];
            if (GetTxDepthInMainChain(parent) > 0) {
                if ((IsMine(parent_output) & ISMINE_SPENDABLE) != ISMINE_NO) {
                    path.amount = parent_output.nValue;
                    path.script = parent_output.scriptPubKey;
                    path.authenticated = true;
                }
                break;
            }

            if (!TransactionHasShadowProof(*parent.tx) ||
                GetDebit(*parent.tx, ISMINE_SPENDABLE) <= 0) {
                break;
            }
            current = &parent;
        }
        paths.emplace(candidate_txid, std::move(path));
    }

    std::map<COutPoint, std::vector<uint256>> roots_by_anchor;
    for (const uint256& txid : candidate_claims) {
        const ClaimPath& path = paths.at(txid);
        if (path.authenticated && !path.anchor.IsNull()) {
            roots_by_anchor[path.anchor].push_back(txid);
        }
    }

    const CCoinsViewCache& coins_tip = chainman.ActiveChainstate().CoinsTip();
    std::set<uint256> assigned_claims;

    for (const auto& [anchor, canonical_claims] : roots_by_anchor) {
        const ClaimPath& first_path = paths.at(canonical_claims.front());
        ShadowPowClaimRecoveryComponent component;
        component.anchor = anchor;
        component.anchor_amount = first_path.amount;
        component.anchor_script = first_path.script;
        component.anchor_authenticated = true;
        component.anchor_user_locked = IsLockedCoin(anchor);

        Coin anchor_coin;
        if (coins_tip.GetCoin(anchor, anchor_coin) && !anchor_coin.IsSpent()) {
            component.anchor_unspent = true;
            if (anchor_coin.out.nValue != component.anchor_amount ||
                anchor_coin.out.scriptPubKey != component.anchor_script ||
                (IsMine(anchor_coin.out) & ISMINE_SPENDABLE) == ISMINE_NO) {
                component.anchor_authenticated = false;
                component.has_indeterminate_node = true;
            }
        }
        component.generation_fingerprint =
            FingerprintClaimGeneration(component);

        std::set<uint256> graph_txids;
        std::vector<uint256> queue;
        auto enqueue = [&](const uint256& txid) {
            if (mapWallet.count(txid) != 0 && graph_txids.insert(txid).second) {
                queue.push_back(txid);
            }
        };

        for (const uint256& txid : canonical_claims) enqueue(txid);
        const auto anchor_spenders = mapTxSpends.equal_range(anchor);
        for (auto it = anchor_spenders.first; it != anchor_spenders.second; ++it) {
            enqueue(it->second);
        }

        for (size_t cursor = 0; cursor < queue.size(); ++cursor) {
            const uint256 txid = queue[cursor];
            const auto wtx_it = mapWallet.find(txid);
            if (wtx_it == mapWallet.end() || !wtx_it->second.tx) continue;
            // A confirmed winning spender is the outcome boundary for this
            // anchor generation. Keep it in the old component as evidence,
            // but its unconfirmed descendants canonicalize only to its newly
            // confirmed outputs and must not be duplicated here.
            if (GetTxDepthInMainChain(wtx_it->second) > 0) continue;
            for (uint32_t output = 0; output < wtx_it->second.tx->vout.size(); ++output) {
                const auto spenders = mapTxSpends.equal_range(
                    COutPoint{txid, output});
                for (auto it = spenders.first; it != spenders.second; ++it) {
                    enqueue(it->second);
                }
            }
        }

        std::set<uint256> graph_claim_txids;
        for (const uint256& txid : graph_txids) {
            const auto it = mapWallet.find(txid);
            if (it != mapWallet.end() && it->second.tx &&
                TransactionHasShadowProof(*it->second.tx)) {
                graph_claim_txids.insert(txid);
            }
        }

        bool all_claims_terminal{true};
        // Origin expiry removes shadow-reward eligibility but does not make
        // the signed base transaction invalid for direct block inclusion.
        // No unspent claim component may therefore release its anchor merely
        // because its mempool policy window elapsed.
        bool all_claims_zero_payment_retirable{false};
        bool all_claims_expired_locally_retired{true};
        bool have_claim{false};
        bool all_stale_depth_known{true};
        int minimum_stale_depth = std::numeric_limits<int>::max();

        for (const uint256& txid : graph_txids) {
            const CWalletTx& wtx = mapWallet.at(txid);
            const CTransaction& tx = *wtx.tx;
            ShadowPowClaimRecoveryNode node;
            node.txid = txid;
            node.active_chain_confirmed = GetTxDepthInMainChain(wtx) > 0;
            node.in_mempool = wtx.InMempool();
            node.abandoned = wtx.isAbandoned();
            node.wallet_authored = GetDebit(tx, ISMINE_SPENDABLE) > 0;
            node.wallet_from_me = wtx.fFromMe;

            if (TransactionHasShadowProof(tx)) {
                node.kind = ShadowPowClaimRecoveryNodeKind::CLAIM;
                node.provenance = ClaimProvenance(
                    wtx, node, &component.generation_fingerprint);
                ParseClaimLineage(
                    wtx, component.generation_fingerprint, node);
                if (node.authored_metadata_valid &&
                    node.created_height > 0 &&
                    node.created_height - 1 <= active_chain.Height()) {
                    const CBlockIndex* created_parent =
                        active_chain[node.created_height - 1];
                    node.authored_tip_active_branch_bound =
                        created_parent &&
                        created_parent->GetBlockHash() == node.created_tip;
                }
                node.quarantined = MetadataFlag(
                    wtx.mapValue, SHADOW_POW_QUARANTINE_MARKER_KEY);
                node.expired_locally_retired = node.abandoned &&
                    MetadataFlag(
                        wtx.mapValue,
                        SHADOW_POW_CLAIM_EXPIRED_RETIRED_KEY) &&
                    HasActiveBranchObservation(
                        wtx.mapValue,
                        SHADOW_POW_CLAIM_EXPIRED_RETIRED_HEIGHT_KEY,
                        SHADOW_POW_CLAIM_EXPIRED_RETIRED_TIP_KEY,
                        active_chain);
                node.expected_shape = tx.vin.size() == 1 &&
                                      !tx.vin.front().prevout.IsNull() &&
                                      !tx.IsCoinBase() && !tx.IsCoinStake();
                node.relay_ttl_expired =
                    wtx.nTimeReceived <= 0 ||
                    wtx.nTimeReceived <=
                        GetTime() - SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS;
                if (wtx.nTimeReceived > 0) {
                    node.relay_expiry_time =
                        static_cast<int64_t>(wtx.nTimeReceived) +
                        SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS;
                }

                const std::optional<ShadowPowClaimDescriptor> descriptor =
                    GetShadowPowClaimDescriptor(tx);
                if (descriptor) {
                    node.claim_descriptor_valid = true;
                    node.proof_version = descriptor->version;
                    node.proof_mode = descriptor->mode;
                    node.proof_origin_bound = descriptor->origin_bound;
                    node.proof_origin_height = descriptor->origin_height;
                    node.proof_origin_previous_block_hash =
                        descriptor->origin_previous_block_hash;
                    node.proof_input_bound = descriptor->input_bound;
                    node.proof_output_index =
                        descriptor->proof_output_index;
                    node.proof_target = descriptor->target;
                    node.proof_payout_script = descriptor->payout_script;
                }
                const CScript canonical_anchor =
                    CanonicalizeLegacyStakeScript(component.anchor_script);
                const bool version_binding_shape = descriptor &&
                    ((descriptor->version == 2 &&
                      !descriptor->origin_bound &&
                      !descriptor->input_bound) ||
                     (descriptor->version == 3 &&
                      descriptor->origin_bound &&
                      !descriptor->input_bound) ||
                     (descriptor->version == 4 &&
                      descriptor->origin_bound &&
                      descriptor->input_bound &&
                      descriptor->claim_outpoint == component.anchor));
                const Consensus::Params& consensus =
                    Params().GetConsensus();
                const bool version_schedule_shape = descriptor &&
                    node.authored_metadata_valid &&
                    node.created_height > 0 &&
                    ((descriptor->version == 2 &&
                      !consensus.IsShadowCompetingClaimsActive(
                          node.created_height)) ||
                     (descriptor->version == 3 &&
                      consensus.IsShadowCompetingClaimsActive(
                          node.created_height) &&
                      !consensus.IsShadowQQP4Active(
                          node.created_height)) ||
                     (descriptor->version == 4 &&
                      consensus.IsShadowQQP4Active(
                          node.created_height)));
                const bool authored_origin_shape = descriptor &&
                    (!descriptor->origin_bound ||
                     (node.authored_metadata_valid &&
                      node.created_height > 0 &&
                      descriptor->origin_height ==
                          static_cast<uint32_t>(node.created_height) &&
                      descriptor->origin_previous_block_hash ==
                          node.created_tip));
                if (tx.vout.size() == 2 && tx.vout.front().nValue > 0 &&
                    tx.vout.front().nValue <= component.anchor_amount) {
                    node.claim_fee = component.anchor_amount -
                                     tx.vout.front().nValue;
                }
                static constexpr uint32_t SEQUENCE_REPLACEABLE = 0xfffffffd;
                node.exact_authored_carrier_shape =
                    descriptor && version_binding_shape &&
                    version_schedule_shape &&
                    authored_origin_shape &&
                    descriptor->mode == ShadowProofPayloadMode::POW &&
                    descriptor->proof_output_index == 1 &&
                    !canonical_anchor.empty() &&
                    !canonical_anchor.IsUnspendable() &&
                    descriptor->target == canonical_anchor &&
                    IsDirectQuantumMigrationScript(
                        descriptor->payout_script) &&
                    tx.nVersion == CTransaction::CURRENT_VERSION &&
                    tx.vin.size() == 1 &&
                    tx.vin.front().prevout == component.anchor &&
                    tx.vin.front().nSequence == SEQUENCE_REPLACEABLE &&
                    tx.vout.size() == 2 && tx.vout.front().nValue > 0 &&
                    tx.vout.front().nValue <= component.anchor_amount &&
                    tx.vout.front().scriptPubKey == canonical_anchor &&
                    tx.vout[1].nValue == 0 &&
                    node.claim_fee > 0 && MoneyRange(node.claim_fee) &&
                    node.claim_fee <= CENT;

                ParseMetadataHeight(wtx.mapValue,
                                    SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY,
                                    node.first_quarantine_height);

                int branch_height{-1};
                uint256 branch_tip;
                if (ParseMetadataHeight(
                        wtx.mapValue,
                        SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY,
                        branch_height) &&
                    ParseMetadataHash(
                        wtx.mapValue,
                        SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY,
                        branch_tip) &&
                    branch_height <= inventory.active_height) {
                    const CBlockIndex* observed = active_chain[branch_height];
                    if (observed && observed->GetBlockHash() == branch_tip) {
                        node.branch_quarantine_height = branch_height;
                        node.stale_depth = inventory.active_height - branch_height;
                        node.stale_depth_known = true;
                    }
                }

                if (component.anchor_unspent) {
                    std::string reject_reason;
                    const bool gold_rush_active = IsShadowGoldRushRewardActive(
                        Params().GetConsensus(), tip->GetMedianTimePast(),
                        tip->nHeight + 1);
                    CheckShadowPowClaimForMempoolDetailed(
                        tx, tip, coins_tip, gold_rush_active, reject_reason,
                        &node.disposition);
                } else {
                    // A confirmed, authenticated anchor absent from CoinsTip
                    // conclusively resolves this generation. Preserve all
                    // cheap topology/metadata facts, but do not re-run the
                    // memory-hard proof evaluator for inert history. A reorg
                    // restoring the coin takes the normal evaluated path.
                    node.proof_evaluation_skipped_resolved_anchor = true;
                }
                node.proof_may_revalidate_on_descendant =
                    node.disposition ==
                    ShadowPowClaimMempoolDisposition::UNBOUND_PROOF_MAY_REVALIDATE;
                if (node.proof_may_revalidate_on_descendant) {
                    component.has_revalidating_unbound_proof = true;
                    component.has_branch_relative_ineligibility = true;
                }
                if (node.disposition == ShadowPowClaimMempoolDisposition::INVALID_LOCATION ||
                    node.disposition == ShadowPowClaimMempoolDisposition::MALFORMED ||
                    node.disposition == ShadowPowClaimMempoolDisposition::DUPLICATE) {
                    node.expected_shape = false;
                }

                component.claim_txids.push_back(txid);
                assigned_claims.insert(txid);
                have_claim = true;
                component.all_claims_quarantined =
                    component.claim_txids.size() == 1
                        ? node.quarantined
                        : component.all_claims_quarantined && node.quarantined;
                component.all_claims_explicitly_provenanced =
                    component.claim_txids.size() == 1
                        ? IsExplicitProvenance(node.provenance)
                        : component.all_claims_explicitly_provenanced &&
                              IsExplicitProvenance(node.provenance);

                const bool direct_root = tx.vin.size() == 1 &&
                                         tx.vin.front().prevout == anchor;
                if (direct_root) {
                    component.root_claim_txids.push_back(txid);
                } else {
                    ++component.descendant_claims;
                }

                if (!node.wallet_authored || !node.expected_shape) {
                    component.has_indeterminate_node = true;
                }
                if (node.provenance ==
                    ShadowPowClaimRecoveryProvenance::UNKNOWN) {
                    component.has_indeterminate_node = true;
                }
                if (!node.quarantined) {
                    component.has_indeterminate_node = true;
                }
                const bool typed_terminal =
                    IsShadowPowClaimCurrentBranchTerminal(node.disposition);
                if (!typed_terminal) all_claims_terminal = false;
                if (!node.expired_locally_retired) {
                    all_claims_expired_locally_retired = false;
                }

                if (node.in_mempool ||
                    node.disposition == ShadowPowClaimMempoolDisposition::ELIGIBLE) {
                    component.has_live_claim = true;
                } else if (node.proof_may_revalidate_on_descendant) {
                    // This state is deliberately distinct from generic
                    // transient/local-capacity failure: bounded conflict
                    // recovery may be explicitly authorized for it.
                } else if (IsShadowPowClaimMempoolRetryable(node.disposition)) {
                    component.has_transient_claim = true;
                } else if (!typed_terminal) {
                    component.has_indeterminate_node = true;
                }
                if (node.proof_may_revalidate_on_descendant ||
                    node.disposition ==
                        ShadowPowClaimMempoolDisposition::ORIGIN_MISMATCH ||
                    node.disposition ==
                        ShadowPowClaimMempoolDisposition::ALREADY_ACCOUNTED) {
                    component.has_branch_relative_ineligibility = true;
                }

                if (node.stale_depth_known) {
                    minimum_stale_depth = std::min(
                        minimum_stale_depth, node.stale_depth);
                } else {
                    all_stale_depth_known = false;
                }
            } else {
                ManagedResolutionFacts managed_facts;
                const auto schema = wtx.mapValue.find(
                    SHADOW_POW_RESOLUTION_SCHEMA_KEY);
                const bool managed_resolution =
                    ParseManagedResolutionFacts(*this, wtx, managed_facts) &&
                    managed_facts.anchor == anchor &&
                    managed_facts.generation_fingerprint ==
                        component.generation_fingerprint;
                uint256 legacy_claim_txid;
                // Presence of the managed schema is authoritative. A
                // malformed managed record must fail closed and may not fall
                // back to its downgrade cleanup marker as a trusted legacy
                // resolution.
                const bool legacy_marker = schema == wtx.mapValue.end() &&
                    ParseMetadataHash(
                        wtx.mapValue, SHADOW_POW_LEGACY_CLEANUP_FOR_KEY,
                        legacy_claim_txid) &&
                    graph_claim_txids.count(legacy_claim_txid) != 0;
                const bool exact_resolution_shape =
                    tx.vin.size() == 1 && tx.vin.front().prevout == anchor &&
                    tx.vout.size() == 1 && tx.vout.front().nValue > 0 &&
                    tx.vout.front().nValue <= component.anchor_amount &&
                    tx.vout.front().scriptPubKey == component.anchor_script;
                const bool managed_final_sequence =
                    exact_resolution_shape &&
                    tx.vin.front().nSequence == CTxIn::SEQUENCE_FINAL;
                const bool legacy_nonreplaceable_sequence =
                    exact_resolution_shape &&
                    tx.vin.front().nSequence > CTxIn::SEQUENCE_FINAL - 2;

                if (managed_resolution && managed_final_sequence) {
                    node.kind = ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION;
                    node.expected_shape = true;
                    node.resolution_metadata_valid = true;
                    node.resolution_generation_fingerprint =
                        managed_facts.generation_fingerprint;
                    node.resolution_origin = managed_facts.origin;
                    node.resolution_created_height =
                        managed_facts.created_height;
                    node.resolution_created_time = managed_facts.created_time;
                    node.resolution_relay_authorized =
                        managed_facts.relay_authorized;
                    node.resolution_relay_revoked =
                        managed_facts.relay_revoked;
                    component.has_managed_resolution = true;
                    component.resolution_txids.push_back(txid);
                } else if (legacy_marker && legacy_nonreplaceable_sequence) {
                    node.kind = ShadowPowClaimRecoveryNodeKind::LEGACY_RESOLUTION;
                    node.expected_shape = true;
                    component.has_legacy_resolution = true;
                    component.resolution_txids.push_back(txid);
                } else {
                    node.kind = ShadowPowClaimRecoveryNodeKind::ORDINARY;
                    component.ordinary_or_mixed_txids.push_back(txid);
                    component.has_indeterminate_node = true;
                }
                if (node.in_mempool) {
                    component.has_live_resolution = true;
                }
            }
            component.nodes.push_back(std::move(node));
        }

        std::sort(component.nodes.begin(), component.nodes.end(),
                  [](const auto& left, const auto& right) {
                      if (left.txid != right.txid) return left.txid < right.txid;
                      return left.kind < right.kind;
                  });
        SortUnique(component.claim_txids);
        SortUnique(component.root_claim_txids);
        SortUnique(component.ordinary_or_mixed_txids);
        SortUnique(component.resolution_txids);

        component.all_claims_terminal_on_pinned_tip =
            have_claim && all_claims_terminal;
        component.all_claims_zero_payment_retirable =
            have_claim && all_claims_zero_payment_retirable;
        component.all_claims_expired_locally_retired =
            have_claim && all_claims_expired_locally_retired;
        component.stale_depth_known = have_claim && all_stale_depth_known;
        component.minimum_stale_depth = component.stale_depth_known
                                            ? minimum_stale_depth
                                            : 0;

        if (!component.anchor_unspent) {
            component.state = ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN;
            ++inventory.resolved_components;
        } else if (!component.anchor_authenticated ||
                   component.has_indeterminate_node || !have_claim) {
            component.state = ShadowPowClaimRecoveryState::INDETERMINATE;
            ++inventory.blocking_components;
        } else if (component.has_live_claim) {
            component.state = ShadowPowClaimRecoveryState::LIVE;
            ++inventory.blocking_components;
        } else if (component.has_transient_claim) {
            component.state = ShadowPowClaimRecoveryState::TRANSIENT;
            ++inventory.blocking_components;
        } else if (!component.resolution_txids.empty()) {
            component.state = ShadowPowClaimRecoveryState::RESOLUTION_PENDING;
            ++inventory.blocking_components;
        } else if (component.all_claims_zero_payment_retirable &&
                   component.all_claims_expired_locally_retired) {
            component.state =
                ShadowPowClaimRecoveryState::RETIRED_ON_ACTIVE_BRANCH;
            inventory.retired_claim_objects += component.claim_txids.size();
            ++inventory.retired_components;
        } else if (component.all_claims_terminal_on_pinned_tip) {
            component.state = component.has_branch_relative_ineligibility
                                  ? ShadowPowClaimRecoveryState::CURRENT_BRANCH_INELIGIBLE
                                  : ShadowPowClaimRecoveryState::TERMINAL_ON_PINNED_TIP;
            ++inventory.blocking_components;
        } else {
            component.state = ShadowPowClaimRecoveryState::CURRENT_BRANCH_INELIGIBLE;
            ++inventory.blocking_components;
        }

        std::string adoption_reason_code;
        std::string adoption_reason;
        component.adoption_graph_safe = SafeGraphForAdoption(
            component, adoption_reason_code, adoption_reason);
        component.fingerprint = FingerprintComponent(
            inventory.active_tip, component);
        inventory.components.push_back(std::move(component));
    }

    // Claims with missing, malformed, ordinary, or cyclic ancestry remain
    // fail closed, but the inventory must still expose their complete local
    // conflict topology. Group same-input siblings and transitive wallet-known
    // ancestors/descendants into one component instead of manufacturing one
    // apparent action per claim object.
    std::set<uint256> assigned_unanchored_txids;
    for (const uint256& candidate_txid : candidate_claims) {
        if (assigned_claims.count(candidate_txid) != 0 ||
            assigned_unanchored_txids.count(candidate_txid) != 0) {
            continue;
        }

        std::set<uint256> graph_txids;
        std::vector<uint256> queue;
        auto enqueue = [&](const uint256& txid) {
            const auto it = mapWallet.find(txid);
            if (it == mapWallet.end() || !it->second.tx ||
                GetTxDepthInMainChain(it->second) > 0 ||
                (TransactionHasShadowProof(*it->second.tx) &&
                 assigned_claims.count(txid) != 0)) {
                return;
            }
            if (graph_txids.insert(txid).second) queue.push_back(txid);
        };
        enqueue(candidate_txid);

        for (size_t cursor = 0; cursor < queue.size(); ++cursor) {
            const CWalletTx& wtx = mapWallet.at(queue[cursor]);
            for (const CTxIn& input : wtx.tx->vin) {
                const auto siblings = mapTxSpends.equal_range(input.prevout);
                for (auto it = siblings.first; it != siblings.second; ++it) {
                    enqueue(it->second);
                }

                // Walk toward an unconfirmed wallet-known root so starting
                // from a leaf cannot split one malformed forest into several
                // components. A confirmed parent is an anchor observation,
                // not a graph node, and is deliberately not enqueued.
                const auto parent = mapWallet.find(input.prevout.hash);
                if (parent != mapWallet.end() && parent->second.tx &&
                    GetTxDepthInMainChain(parent->second) <= 0) {
                    enqueue(parent->first);
                }
            }
            for (uint32_t output = 0; output < wtx.tx->vout.size(); ++output) {
                const auto descendants = mapTxSpends.equal_range(
                    COutPoint{wtx.GetHash(), output});
                for (auto it = descendants.first; it != descendants.second;
                     ++it) {
                    enqueue(it->second);
                }
            }
        }

        ShadowPowClaimRecoveryComponent component;
        bool have_claim{false};
        for (const uint256& txid : graph_txids) {
            const CWalletTx& wtx = mapWallet.at(txid);
            ShadowPowClaimRecoveryNode node;
            node.txid = txid;
            node.active_chain_confirmed = false;
            node.in_mempool = wtx.InMempool();
            node.wallet_authored =
                GetDebit(*wtx.tx, ISMINE_SPENDABLE) > 0;
            node.wallet_from_me = wtx.fFromMe;

            if (TransactionHasShadowProof(*wtx.tx)) {
                node.kind = ShadowPowClaimRecoveryNodeKind::CLAIM;
                node.provenance = ClaimProvenance(wtx, node);
                node.quarantined = MetadataFlag(
                    wtx.mapValue, SHADOW_POW_QUARANTINE_MARKER_KEY);
                node.expected_shape = wtx.tx->vin.size() == 1 &&
                                      !wtx.tx->vin.front().prevout.IsNull() &&
                                      !wtx.tx->IsCoinBase() &&
                                      !wtx.tx->IsCoinStake();
                ParseMetadataHeight(
                    wtx.mapValue,
                    SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY,
                    node.first_quarantine_height);

                component.claim_txids.push_back(txid);
                inventory.unanchored_claim_txids.push_back(txid);
                assigned_unanchored_txids.insert(txid);
                component.all_claims_quarantined =
                    !have_claim
                        ? node.quarantined
                        : component.all_claims_quarantined && node.quarantined;
                component.all_claims_explicitly_provenanced =
                    !have_claim
                        ? IsExplicitProvenance(node.provenance)
                        : component.all_claims_explicitly_provenanced &&
                              IsExplicitProvenance(node.provenance);
                have_claim = true;

            } else {
                node.kind = ShadowPowClaimRecoveryNodeKind::ORDINARY;
                component.ordinary_or_mixed_txids.push_back(txid);
            }
            component.nodes.push_back(std::move(node));
        }

        const std::set<uint256> component_claims{
            component.claim_txids.begin(), component.claim_txids.end()};
        bool have_common_anchor{false};
        bool common_anchor_matches{true};
        for (const uint256& txid : component.claim_txids) {
            const CWalletTx& wtx = mapWallet.at(txid);
            if (wtx.tx->vin.size() == 1 &&
                component_claims.count(wtx.tx->vin.front().prevout.hash) == 0) {
                component.root_claim_txids.push_back(txid);
                const COutPoint& root_input = wtx.tx->vin.front().prevout;
                if (!have_common_anchor) {
                    component.anchor = root_input;
                    have_common_anchor = true;
                } else if (component.anchor != root_input) {
                    common_anchor_matches = false;
                }
            }
        }
        if (!have_common_anchor || !common_anchor_matches) {
            component.anchor.SetNull();
        }
        component.descendant_claims =
            component.claim_txids.size() - component.root_claim_txids.size();
        std::sort(component.nodes.begin(), component.nodes.end(),
                  [](const auto& left, const auto& right) {
                      if (left.txid != right.txid) return left.txid < right.txid;
                      return left.kind < right.kind;
                  });
        SortUnique(component.claim_txids);
        SortUnique(component.root_claim_txids);
        SortUnique(component.ordinary_or_mixed_txids);
        component.has_indeterminate_node = true;
        component.state = ShadowPowClaimRecoveryState::INDETERMINATE;
        component.fingerprint = FingerprintComponent(
            inventory.active_tip, component);
        inventory.components.push_back(std::move(component));
        ++inventory.blocking_components;
    }

    std::sort(inventory.components.begin(), inventory.components.end(),
              [](const auto& left, const auto& right) {
                  if (left.anchor != right.anchor) return left.anchor < right.anchor;
                  const uint256 left_txid = left.claim_txids.empty()
                                                  ? uint256{}
                                                  : left.claim_txids.front();
                  const uint256 right_txid = right.claim_txids.empty()
                                                   ? uint256{}
                                                   : right.claim_txids.front();
                  return left_txid < right_txid;
              });
    SortUnique(inventory.unanchored_claim_txids);
    return inventory;
}

namespace {

struct ShadowPowClaimRelaySuppression
{
    uint256 active_tip;
    uint64_t wallet_generation{0};
    uint256 candidate_state_fingerprint;
    const std::set<uint256>* relay_txids{nullptr};
    const std::set<uint256>* deferred_family_roots{nullptr};
};

bool IsAuditOnlyForeignShadowPowClaimComponent(
    const ShadowPowClaimRecoveryComponent& component)
{
    if (component.anchor_authenticated) return false;

    bool saw_claim{false};
    for (const ShadowPowClaimRecoveryNode& node : component.nodes) {
        if (node.wallet_authored || node.wallet_from_me ||
            node.provenance !=
                ShadowPowClaimRecoveryProvenance::UNKNOWN) {
            return false;
        }
        if (node.kind == ShadowPowClaimRecoveryNodeKind::CLAIM) {
            saw_claim = true;
        }
    }
    return saw_claim;
}

ShadowPowClaimMiningGate EvaluateShadowPowClaimMiningFamily(
    const ShadowPowClaimRecoveryInventory& inventory,
    const ShadowPowClaimRecoveryComponent& component,
    const ShadowPowClaimRelaySuppression* suppression)
{
    ShadowPowClaimMiningGate gate;
    gate.active_tip = inventory.active_tip;
    gate.active_height = inventory.active_height;
    gate.wallet_generation = inventory.wallet_generation;
    gate.candidate_state_fingerprint =
        inventory.candidate_state_fingerprint;
    gate.recovery_database_ambiguous =
        inventory.recovery_database_ambiguous;
    gate.coherent = inventory.wallet_tip_matches &&
                    !inventory.active_tip.IsNull() &&
                    inventory.active_height >= 0;

    const bool pure_component_shape =
        component.anchor_authenticated && component.anchor_unspent &&
        !component.anchor.IsNull() && component.anchor_amount > 0 &&
        MoneyRange(component.anchor_amount) &&
        !component.generation_fingerprint.IsNull() &&
        !component.claim_txids.empty() &&
        component.nodes.size() == component.claim_txids.size() &&
        component.root_claim_txids.size() == component.claim_txids.size() &&
        component.descendant_claims == 0 &&
        component.ordinary_or_mixed_txids.empty() &&
        component.resolution_txids.empty() &&
        !component.has_managed_resolution &&
        !component.has_legacy_resolution &&
        !component.has_live_resolution;
    if (!pure_component_shape) {
        gate.unsafe_components = 1;
        gate.unsafe_claims = component.claim_txids.size();
        return gate;
    }

    std::map<uint256, const ShadowPowClaimRecoveryNode*> claims;
    std::vector<const ShadowPowClaimRecoveryNode*> implicit_roots;
    std::vector<const ShadowPowClaimRecoveryNode*> schema_roots;
    CScript common_target;
    CScript common_payout;
    bool common_scripts_set{false};
    bool family_safe{true};
    for (const ShadowPowClaimRecoveryNode& node : component.nodes) {
        if (node.kind != ShadowPowClaimRecoveryNodeKind::CLAIM ||
            node.active_chain_confirmed ||
            (node.abandoned && !node.expired_locally_retired) ||
            node.provenance !=
                ShadowPowClaimRecoveryProvenance::EXPLICIT_AUTHORED ||
            !node.authored_metadata_valid || !node.expected_shape ||
            !node.wallet_authored || !node.wallet_from_me ||
            !node.claim_descriptor_valid ||
            !node.exact_authored_carrier_shape ||
            (!node.in_mempool && !node.quarantined) ||
            !claims.emplace(node.txid, &node).second) {
            family_safe = false;
            break;
        }
        if (!common_scripts_set) {
            common_target = node.proof_target;
            common_payout = node.proof_payout_script;
            common_scripts_set = true;
        } else if (node.proof_target != common_target ||
                   node.proof_payout_script != common_payout) {
            family_safe = false;
            break;
        }
        if (node.lineage_metadata_present) {
            if (!node.lineage_metadata_valid) {
                family_safe = false;
                break;
            }
            if (node.lineage_ordinal == 0) {
                schema_roots.push_back(&node);
            }
        } else {
            implicit_roots.push_back(&node);
        }
    }
    if (!family_safe || claims.size() != component.claim_txids.size() ||
        implicit_roots.size() + schema_roots.size() != 1 ||
        !common_scripts_set) {
        gate.unsafe_components = 1;
        gate.unsafe_claims = component.claim_txids.size();
        return gate;
    }

    const bool legacy_implicit_root = !implicit_roots.empty();
    const ShadowPowClaimRecoveryNode& root = legacy_implicit_root
        ? *implicit_roots.front()
        : *schema_roots.front();
    const bool lineage_established = claims.size() > 1;
    const bool qqp4_active = Params().GetConsensus().IsShadowQQP4Active(
        inventory.active_height + 1);
    const bool legacy_singleton_disposition_safe =
        root.disposition ==
            ShadowPowClaimMempoolDisposition::ELIGIBLE ||
        root.disposition ==
            ShadowPowClaimMempoolDisposition::UNBOUND_PROOF_MAY_REVALIDATE ||
        (qqp4_active &&
         root.disposition ==
             ShadowPowClaimMempoolDisposition::UNSUPPORTED_VERSION);
    if (legacy_implicit_root) {
        const bool legacy_v2_root =
            root.proof_version == 2 && !root.proof_origin_bound &&
            !root.proof_input_bound;
        const bool pre_lineage_bound_root =
            (root.proof_version == 3 && root.proof_origin_bound &&
             !root.proof_input_bound) ||
            (root.proof_version == 4 && root.proof_origin_bound &&
             root.proof_input_bound);
        if ((!legacy_v2_root && !pre_lineage_bound_root) ||
            (legacy_v2_root && !lineage_established &&
             (!root.authored_tip_active_branch_bound ||
              !legacy_singleton_disposition_safe))) {
            gate.unsafe_components = 1;
            gate.unsafe_claims = claims.size();
            return gate;
        }
    }

    std::map<uint32_t, const ShadowPowClaimRecoveryNode*> by_ordinal;
    by_ordinal.emplace(0, &root);
    for (const auto& [txid, node] : claims) {
        if (node == &root) continue;
        if (!node->lineage_metadata_valid || node->lineage_ordinal == 0 ||
            node->lineage_family_fingerprint !=
                component.generation_fingerprint ||
            node->lineage_root_txid != root.txid ||
            !by_ordinal.emplace(node->lineage_ordinal, node).second) {
            family_safe = false;
            break;
        }
    }
    if (family_safe && by_ordinal.size() == claims.size() &&
        by_ordinal.size() <=
            static_cast<size_t>(std::numeric_limits<uint32_t>::max())) {
        for (size_t ordinal = 1; ordinal < by_ordinal.size(); ++ordinal) {
            const auto current = by_ordinal.find(
                static_cast<uint32_t>(ordinal));
            const auto parent = by_ordinal.find(
                static_cast<uint32_t>(ordinal - 1));
            if (current == by_ordinal.end() || parent == by_ordinal.end() ||
                current->second->lineage_parent_txid !=
                    parent->second->txid) {
                family_safe = false;
                break;
            }
        }
    } else {
        family_safe = false;
    }
    if (!family_safe) {
        gate.unsafe_components = 1;
        gate.unsafe_claims = claims.size();
        return gate;
    }

    const auto disposition_is_family_safe =
        [&](const ShadowPowClaimRecoveryNode& node) {
            if (node.in_mempool ||
                node.disposition ==
                    ShadowPowClaimMempoolDisposition::ELIGIBLE) {
                return true;
            }
            if (node.proof_version == 2 &&
                node.disposition ==
                    ShadowPowClaimMempoolDisposition::UNBOUND_PROOF_MAY_REVALIDATE) {
                return true;
            }
            if ((node.proof_version == 3 || node.proof_version == 4) &&
                (node.disposition ==
                     ShadowPowClaimMempoolDisposition::ORIGIN_MISMATCH ||
                 node.disposition ==
                     ShadowPowClaimMempoolDisposition::ORIGIN_EXPIRED)) {
                return true;
            }
            return qqp4_active &&
                   (node.proof_version == 2 || node.proof_version == 3) &&
                   node.disposition ==
                       ShadowPowClaimMempoolDisposition::UNSUPPORTED_VERSION;
        };

    size_t live_claims{0};
    size_t eligible_claims{0};
    const ShadowPowClaimRecoveryNode* relay_candidate{nullptr};
    const bool suppression_has_state = suppression &&
        ((suppression->relay_txids &&
          !suppression->relay_txids->empty()) ||
         (suppression->deferred_family_roots &&
          !suppression->deferred_family_roots->empty()));
    const bool suppression_matches_snapshot = suppression_has_state &&
        inventory.active_tip == suppression->active_tip &&
        inventory.wallet_generation == suppression->wallet_generation &&
        inventory.candidate_state_fingerprint ==
            suppression->candidate_state_fingerprint;
    for (const auto& [ordinal, node] : by_ordinal) {
        if (!disposition_is_family_safe(*node)) {
            family_safe = false;
            break;
        }
        if (node->in_mempool) ++live_claims;
        if (node->disposition ==
            ShadowPowClaimMempoolDisposition::ELIGIBLE) {
            ++eligible_claims;
            if (!node->in_mempool && !node->relay_ttl_expired &&
                (!suppression_matches_snapshot ||
                 !suppression->relay_txids ||
                 suppression->relay_txids->count(node->txid) == 0)) {
                relay_candidate = node;
            }
        }
    }
    if (!family_safe) {
        gate.unsafe_components = 1;
        gate.unsafe_claims = claims.size();
        return gate;
    }
    if (live_claims > 1) {
        // Same-anchor siblings conflict on the authenticated input and cannot
        // coexist in the authoritative mempool. Multiple live members inside
        // one family therefore indicate stale or incoherent wallet state,
        // even though independent families may each have one live member.
        gate.unsafe_components = 1;
        gate.unsafe_claims = claims.size();
        return gate;
    }

    const ShadowPowClaimRecoveryNode& head =
        *by_ordinal.rbegin()->second;
    if (head.lineage_ordinal == std::numeric_limits<uint32_t>::max()) {
        gate.unsafe_components = 1;
        gate.unsafe_claims = claims.size();
        return gate;
    }

    gate.live_claims = live_claims;
    gate.eligible_claims = eligible_claims;
    gate.family_claims = claims.size();
    gate.anchor = component.anchor;
    gate.anchor_amount = component.anchor_amount;
    gate.target = common_target;
    gate.payout_script = common_payout;
    gate.generation_fingerprint = component.generation_fingerprint;
    gate.lineage_root_txid = root.txid;
    gate.lineage_head_txid = head.txid;
    gate.next_lineage_ordinal = head.lineage_ordinal + 1;

    const bool defer_family_until_snapshot_changes =
        suppression_matches_snapshot &&
        suppression->deferred_family_roots &&
        suppression->deferred_family_roots->count(
            gate.lineage_root_txid) != 0;
    if (defer_family_until_snapshot_changes) {
        gate.action =
            ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP;
        return gate;
    }

    if (component.anchor_user_locked) {
        gate.action =
            ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP;
    } else if (gate.live_claims != 0) {
        gate.action = ShadowPowClaimMiningGateAction::WAIT_FOR_LIVE;
    } else if (relay_candidate) {
        gate.action = ShadowPowClaimMiningGateAction::RELAY_EXISTING;
        gate.relay_txid = relay_candidate->txid;
        gate.relay_expiry_time = relay_candidate->relay_expiry_time;
    } else {
        gate.action =
            ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR;
    }
    return gate;
}

int ShadowPowClaimMiningActionPriority(
    ShadowPowClaimMiningGateAction action)
{
    switch (action) {
    case ShadowPowClaimMiningGateAction::RELAY_EXISTING:
        return 0;
    case ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR:
        return 1;
    case ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP:
        return 2;
    case ShadowPowClaimMiningGateAction::WAIT_FOR_LIVE:
        return 3;
    default:
        return 4;
    }
}

bool PreferShadowPowClaimMiningFamily(
    const ShadowPowClaimMiningGate& candidate,
    const ShadowPowClaimMiningGate& selected)
{
    const int candidate_priority =
        ShadowPowClaimMiningActionPriority(candidate.action);
    const int selected_priority =
        ShadowPowClaimMiningActionPriority(selected.action);
    if (candidate_priority != selected_priority) {
        return candidate_priority < selected_priority;
    }
    if (candidate.anchor != selected.anchor) {
        return candidate.anchor < selected.anchor;
    }
    if (candidate.generation_fingerprint !=
        selected.generation_fingerprint) {
        return candidate.generation_fingerprint <
               selected.generation_fingerprint;
    }
    if (candidate.lineage_root_txid != selected.lineage_root_txid) {
        return candidate.lineage_root_txid < selected.lineage_root_txid;
    }
    if (candidate.lineage_head_txid != selected.lineage_head_txid) {
        return candidate.lineage_head_txid < selected.lineage_head_txid;
    }
    return candidate.relay_txid < selected.relay_txid;
}

void CopyShadowPowClaimMiningFamilySelection(
    ShadowPowClaimMiningGate& aggregate,
    const ShadowPowClaimMiningGate& selected)
{
    aggregate.action = selected.action;
    aggregate.anchor = selected.anchor;
    aggregate.anchor_amount = selected.anchor_amount;
    aggregate.target = selected.target;
    aggregate.payout_script = selected.payout_script;
    aggregate.generation_fingerprint = selected.generation_fingerprint;
    aggregate.lineage_root_txid = selected.lineage_root_txid;
    aggregate.lineage_head_txid = selected.lineage_head_txid;
    aggregate.next_lineage_ordinal = selected.next_lineage_ordinal;
    aggregate.relay_txid = selected.relay_txid;
    aggregate.relay_expiry_time = selected.relay_expiry_time;
}

bool ShadowPowClaimMiningGateSnapshotMatches(
    const ShadowPowClaimMiningGate& expected,
    const ShadowPowClaimMiningGate& current)
{
    return expected.action == current.action &&
           expected.active_tip == current.active_tip &&
           expected.active_height == current.active_height &&
           expected.wallet_generation == current.wallet_generation &&
           expected.candidate_state_fingerprint ==
               current.candidate_state_fingerprint &&
           expected.coherent == current.coherent &&
           expected.recovery_database_ambiguous ==
               current.recovery_database_ambiguous &&
           expected.unresolved_components ==
               current.unresolved_components &&
           expected.live_claims == current.live_claims &&
           expected.eligible_claims == current.eligible_claims &&
           expected.family_claims == current.family_claims &&
           expected.unsafe_claims == current.unsafe_claims &&
           expected.unsafe_components == current.unsafe_components &&
           expected.anchor == current.anchor &&
           expected.anchor_amount == current.anchor_amount &&
           expected.target == current.target &&
           expected.payout_script == current.payout_script &&
           expected.generation_fingerprint ==
               current.generation_fingerprint &&
           expected.lineage_root_txid == current.lineage_root_txid &&
           expected.lineage_head_txid == current.lineage_head_txid &&
           expected.next_lineage_ordinal ==
               current.next_lineage_ordinal &&
           expected.relay_txid == current.relay_txid &&
           expected.relay_expiry_time == current.relay_expiry_time;
}

bool ShadowPowClaimCachedRelayStateExpired(
    const ShadowPowClaimRecoveryInventory& inventory, int64_t now)
{
    for (const ShadowPowClaimRecoveryComponent& component :
         inventory.components) {
        for (const ShadowPowClaimRecoveryNode& node : component.nodes) {
            if (node.kind == ShadowPowClaimRecoveryNodeKind::CLAIM &&
                !node.in_mempool &&
                node.disposition ==
                    ShadowPowClaimMempoolDisposition::ELIGIBLE &&
                !node.relay_ttl_expired && node.relay_expiry_time > 0 &&
                now >= node.relay_expiry_time) {
                return true;
            }
        }
    }
    return false;
}

bool ShadowPowClaimDeferrableFamilyIntentMatches(
    const ShadowPowClaimMiningGate& expected,
    const ShadowPowClaimMiningGate& current)
{
    const bool deferrable = expected.ShouldRelayExisting() ||
        expected.MayRefreshSameAnchor();
    return deferrable && ShadowPowClaimMiningGateSnapshotMatches(
        expected, current);
}

ShadowPowClaimMiningGate BuildShadowPowClaimMiningGateImpl(
    const ShadowPowClaimRecoveryInventory& inventory,
    const ShadowPowClaimRelaySuppression* suppression = nullptr)
{
    ShadowPowClaimMiningGate gate;
    gate.active_tip = inventory.active_tip;
    gate.active_height = inventory.active_height;
    gate.wallet_generation = inventory.wallet_generation;
    gate.candidate_state_fingerprint =
        inventory.candidate_state_fingerprint;
    gate.recovery_database_ambiguous =
        inventory.recovery_database_ambiguous;
    gate.coherent = inventory.wallet_tip_matches &&
                    !inventory.active_tip.IsNull() &&
                    inventory.active_height >= 0;
    if (!gate.coherent || gate.recovery_database_ambiguous) return gate;

    std::optional<ShadowPowClaimMiningGate> selected;
    for (const ShadowPowClaimRecoveryComponent& component :
         inventory.components) {
        if (component.state ==
                ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN ||
            component.state ==
                ShadowPowClaimRecoveryState::RETIRED_ON_ACTIVE_BRANCH) {
            continue;
        }
        if (IsAuditOnlyForeignShadowPowClaimComponent(component)) {
            continue;
        }
        ++gate.unresolved_components;
        ShadowPowClaimMiningGate family =
            EvaluateShadowPowClaimMiningFamily(
                inventory, component, suppression);
        gate.live_claims += family.live_claims;
        gate.eligible_claims += family.eligible_claims;
        gate.family_claims += family.family_claims;
        gate.unsafe_claims += family.unsafe_claims;
        gate.unsafe_components += family.unsafe_components;
        if (family.action == ShadowPowClaimMiningGateAction::UNSAFE) {
            continue;
        }
        if (!selected ||
            PreferShadowPowClaimMiningFamily(family, *selected)) {
            selected = std::move(family);
        }
    }
    if (gate.unsafe_components != 0) return gate;
    if (gate.unresolved_components == 0) {
        gate.action =
            ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR;
        return gate;
    }
    if (selected) {
        CopyShadowPowClaimMiningFamilySelection(gate, *selected);
    }
    return gate;
}

} // namespace

ShadowPowClaimMiningGate BuildShadowPowClaimMiningGate(
    const ShadowPowClaimRecoveryInventory& inventory)
{
    return BuildShadowPowClaimMiningGateImpl(inventory);
}

bool HasMiningRelevantUnresolvedShadowPowClaimComponent(
    const ShadowPowClaimRecoveryInventory& inventory)
{
    return std::any_of(
        inventory.components.begin(), inventory.components.end(),
        [](const ShadowPowClaimRecoveryComponent& component) {
            if (component.state ==
                    ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN ||
                component.state ==
                    ShadowPowClaimRecoveryState::RETIRED_ON_ACTIVE_BRANCH) {
                return false;
            }
            return !IsAuditOnlyForeignShadowPowClaimComponent(component);
        });
}

bool ShadowPowClaimRelayIntentMatches(
    const ShadowPowClaimMiningGate& expected,
    const ShadowPowClaimMiningGate& current)
{
    return expected.ShouldRelayExisting() &&
           current.ShouldRelayExisting() &&
           ShadowPowClaimMiningGateSnapshotMatches(expected, current);
}

ShadowPowClaimMiningGateAction GetShadowPowClaimMiningGateTelemetryAction(
    const ShadowPowClaimMiningGate& fresh_gate,
    const ShadowPowClaimMiningGate& cached_gate, bool miner_enabled,
    bool claim_in_flight, bool wallet_wide_tip_wait)
{
    if (!miner_enabled || cached_gate.active_tip.IsNull() ||
        !fresh_gate.coherent ||
        fresh_gate.recovery_database_ambiguous ||
        fresh_gate.HasUnsafeClaims() ||
        cached_gate.active_tip != fresh_gate.active_tip ||
        cached_gate.active_height != fresh_gate.active_height) {
        return fresh_gate.action;
    }
    // A new-anchor INPUT_UNAVAILABLE/conflict outcome owns the wallet-wide
    // submission reservation until this exact tip changes. A user may unlock
    // the failed input (or otherwise change a safe wallet snapshot) while the
    // reservation remains active; that must not let a sibling worker grind or
    // submit on the same tip. Safety transitions above still win immediately.
    if (wallet_wide_tip_wait) {
        return ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP;
    }
    if (!claim_in_flight ||
        cached_gate.action !=
            ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP ||
        cached_gate.HasUnsafeClaims() ||
        cached_gate.coherent != fresh_gate.coherent ||
        cached_gate.recovery_database_ambiguous !=
            fresh_gate.recovery_database_ambiguous) {
        return fresh_gate.action;
    }
    if (
        cached_gate.wallet_generation != fresh_gate.wallet_generation ||
        cached_gate.candidate_state_fingerprint.IsNull() ||
        cached_gate.candidate_state_fingerprint !=
            fresh_gate.candidate_state_fingerprint ||
        cached_gate.unresolved_components !=
            fresh_gate.unresolved_components ||
        cached_gate.live_claims != fresh_gate.live_claims ||
        cached_gate.eligible_claims != fresh_gate.eligible_claims ||
        cached_gate.family_claims != fresh_gate.family_claims ||
        cached_gate.unsafe_claims != fresh_gate.unsafe_claims ||
        cached_gate.unsafe_components != fresh_gate.unsafe_components ||
        cached_gate.anchor != fresh_gate.anchor ||
        cached_gate.anchor_amount != fresh_gate.anchor_amount ||
        cached_gate.target != fresh_gate.target ||
        cached_gate.payout_script != fresh_gate.payout_script ||
        cached_gate.generation_fingerprint !=
            fresh_gate.generation_fingerprint ||
        cached_gate.lineage_root_txid != fresh_gate.lineage_root_txid ||
        cached_gate.lineage_head_txid != fresh_gate.lineage_head_txid ||
        cached_gate.next_lineage_ordinal !=
            fresh_gate.next_lineage_ordinal) {
        return fresh_gate.action;
    }
    return ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP;
}

ShadowPowClaimMiningGate CWallet::GetShadowPowClaimMiningGate() const
{
    if (!HaveChain() || !chain().isReadyToBroadcast()) {
        return BuildShadowPowClaimMiningGate(
            GetShadowPowClaimRecoveryInventory());
    }
    LOCK2(::cs_main, cs_wallet);
    return GetShadowPowClaimMiningGateLocked();
}

ShadowPowClaimMiningGate CWallet::GetShadowPowClaimMiningGateLocked() const
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(cs_wallet);
    return GetShadowPowClaimMiningGateFromInventoryLocked(
        GetShadowPowClaimRecoveryInventoryLocked());
}

ShadowPowClaimMiningGate
CWallet::GetShadowPowClaimMiningGateFromInventoryLocked(
    const ShadowPowClaimRecoveryInventory& inventory) const
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(cs_wallet);
    ShadowPowClaimRelaySuppression suppression;
    suppression.active_tip = m_shadow_pow_relay_reject_tip;
    suppression.wallet_generation =
        m_shadow_pow_relay_reject_wallet_generation;
    suppression.candidate_state_fingerprint =
        m_shadow_pow_relay_reject_candidate_state;
    suppression.relay_txids = &m_shadow_pow_relay_reject_txids;
    suppression.deferred_family_roots =
        &m_shadow_pow_relay_wait_roots;
    return BuildShadowPowClaimMiningGateImpl(inventory, &suppression);
}

ShadowPowClaimMiningGateAction
CWallet::GetShadowPowClaimMiningGateTelemetryActionLocked(
    const ShadowPowClaimMiningGate& fresh_gate, bool& miner_enabled,
    interfaces::WalletPowMiningState& miner_state)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(cs_wallet);
    LOCK(m_pow_miner_mutex);
    miner_enabled = m_pow_mining_enabled.load();
    miner_state = m_pow_state.load();
    return GetShadowPowClaimMiningGateTelemetryAction(
        fresh_gate, m_pow_mining_gate, miner_enabled,
        miner_state ==
            interfaces::WalletPowMiningState::CLAIM_IN_FLIGHT,
        m_pow_wallet_wide_tip_wait);
}

bool CWallet::RecordShadowPowClaimRelayPolicyRejection(
    const ShadowPowClaimMiningGate& rejected_gate,
    ShadowPowClaimMiningGate* reselected_gate)
{
    LOCK2(::cs_main, cs_wallet);
    if (!rejected_gate.ShouldRelayExisting() ||
        rejected_gate.recovery_database_ambiguous ||
        !rejected_gate.coherent) {
        return false;
    }
    const CBlockIndex* tip = chain().chainman().ActiveChain().Tip();
    const uint256 active_tip = tip ? tip->GetBlockHash() : uint256{};
    const uint64_t wallet_generation =
        GetDatabase().nUpdateCounter.load();
    const uint256 candidate_state =
        GetShadowPowClaimCandidateStateFingerprintLocked();
    if (!tip || m_last_block_processed != active_tip ||
        m_shadow_pow_claim_recovery_db_ambiguous ||
        active_tip != rejected_gate.active_tip ||
        wallet_generation != rejected_gate.wallet_generation ||
        candidate_state != rejected_gate.candidate_state_fingerprint) {
        m_shadow_pow_relay_reject_inventory.reset();
        return false;
    }
    if (!m_shadow_pow_relay_reject_inventory ||
        m_shadow_pow_relay_reject_inventory->active_tip != active_tip ||
        m_shadow_pow_relay_reject_inventory->wallet_generation !=
            wallet_generation ||
        m_shadow_pow_relay_reject_inventory
                ->candidate_state_fingerprint != candidate_state ||
        ShadowPowClaimCachedRelayStateExpired(
            *m_shadow_pow_relay_reject_inventory, GetTime())) {
        m_shadow_pow_relay_reject_inventory =
            GetShadowPowClaimRecoveryInventoryLocked();
    }
    const ShadowPowClaimRecoveryInventory& inventory =
        *m_shadow_pow_relay_reject_inventory;
    ShadowPowClaimRelaySuppression suppression;
    suppression.active_tip = m_shadow_pow_relay_reject_tip;
    suppression.wallet_generation =
        m_shadow_pow_relay_reject_wallet_generation;
    suppression.candidate_state_fingerprint =
        m_shadow_pow_relay_reject_candidate_state;
    suppression.relay_txids = &m_shadow_pow_relay_reject_txids;
    suppression.deferred_family_roots =
        &m_shadow_pow_relay_wait_roots;
    const ShadowPowClaimMiningGate current =
        BuildShadowPowClaimMiningGateImpl(inventory, &suppression);
    if (!current.ShouldRelayExisting() ||
        current.active_tip != rejected_gate.active_tip ||
        current.wallet_generation != rejected_gate.wallet_generation ||
        current.candidate_state_fingerprint !=
            rejected_gate.candidate_state_fingerprint ||
        current.relay_txid != rejected_gate.relay_txid ||
        current.anchor != rejected_gate.anchor ||
        current.generation_fingerprint !=
            rejected_gate.generation_fingerprint ||
        current.lineage_root_txid != rejected_gate.lineage_root_txid ||
        current.lineage_head_txid != rejected_gate.lineage_head_txid) {
        return false;
    }
    const auto relay = mapWallet.find(current.relay_txid);
    if (relay == mapWallet.end() || !relay->second.tx ||
        relay->second.InMempool() || relay->second.isAbandoned()) {
        return false;
    }
    const MempoolAcceptResult accept =
        chain().chainman().ProcessTransaction(
            relay->second.tx, /*test_accept=*/true);
    if (accept.m_result_type !=
            MempoolAcceptResult::ResultType::INVALID ||
        !IsRepairableShadowPowRelayFeePolicyRejection(accept.m_state)) {
        // Infrastructure/internal failures, an already-known exact
        // transaction, and temporary mempool contention never authorize a
        // sibling. Only a reproducible deterministic policy rejection does.
        return false;
    }
    if (m_shadow_pow_relay_reject_tip != current.active_tip ||
        m_shadow_pow_relay_reject_wallet_generation !=
            current.wallet_generation ||
        m_shadow_pow_relay_reject_candidate_state !=
            current.candidate_state_fingerprint) {
        m_shadow_pow_relay_reject_txids.clear();
        m_shadow_pow_relay_wait_roots.clear();
        m_shadow_pow_relay_reject_tip = current.active_tip;
        m_shadow_pow_relay_reject_wallet_generation =
            current.wallet_generation;
        m_shadow_pow_relay_reject_candidate_state =
            current.candidate_state_fingerprint;
    }
    m_shadow_pow_relay_reject_txids.insert(current.relay_txid);
    if (reselected_gate) {
        suppression.active_tip = current.active_tip;
        suppression.wallet_generation = current.wallet_generation;
        suppression.candidate_state_fingerprint =
            current.candidate_state_fingerprint;
        *reselected_gate =
            BuildShadowPowClaimMiningGateImpl(inventory, &suppression);
    }
    return true;
}

ShadowPowClaimMiningGate
CWallet::DeferShadowPowClaimFamilyForSnapshot(
    const ShadowPowClaimMiningGate& deferred_gate)
{
    LOCK2(::cs_main, cs_wallet);
    return DeferShadowPowClaimFamilyForSnapshotLocked(deferred_gate);
}

ShadowPowClaimMiningGate
CWallet::DeferShadowPowClaimFamilyForSnapshotLocked(
    const ShadowPowClaimMiningGate& deferred_gate)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(cs_wallet);
    const CBlockIndex* tip = chain().chainman().ActiveChain().Tip();
    const uint256 active_tip = tip ? tip->GetBlockHash() : uint256{};
    const uint64_t wallet_generation =
        GetDatabase().nUpdateCounter.load();
    const uint256 candidate_state =
        GetShadowPowClaimCandidateStateFingerprintLocked();
    if ((!deferred_gate.ShouldRelayExisting() &&
         !deferred_gate.MayRefreshSameAnchor()) ||
        !tip ||
        m_last_block_processed != active_tip ||
        m_shadow_pow_claim_recovery_db_ambiguous ||
        active_tip != deferred_gate.active_tip ||
        wallet_generation != deferred_gate.wallet_generation ||
        candidate_state != deferred_gate.candidate_state_fingerprint) {
        m_shadow_pow_relay_reject_inventory.reset();
        return GetShadowPowClaimMiningGateLocked();
    }
    if (!m_shadow_pow_relay_reject_inventory ||
        m_shadow_pow_relay_reject_inventory->active_tip != active_tip ||
        m_shadow_pow_relay_reject_inventory->wallet_generation !=
            wallet_generation ||
        m_shadow_pow_relay_reject_inventory
                ->candidate_state_fingerprint != candidate_state ||
        ShadowPowClaimCachedRelayStateExpired(
            *m_shadow_pow_relay_reject_inventory, GetTime())) {
        m_shadow_pow_relay_reject_inventory =
            GetShadowPowClaimRecoveryInventoryLocked();
    }
    const ShadowPowClaimRecoveryInventory& inventory =
        *m_shadow_pow_relay_reject_inventory;
    ShadowPowClaimRelaySuppression suppression;
    suppression.active_tip = m_shadow_pow_relay_reject_tip;
    suppression.wallet_generation =
        m_shadow_pow_relay_reject_wallet_generation;
    suppression.candidate_state_fingerprint =
        m_shadow_pow_relay_reject_candidate_state;
    suppression.relay_txids = &m_shadow_pow_relay_reject_txids;
    suppression.deferred_family_roots =
        &m_shadow_pow_relay_wait_roots;
    const ShadowPowClaimMiningGate current =
        BuildShadowPowClaimMiningGateImpl(inventory, &suppression);
    if (!ShadowPowClaimDeferrableFamilyIntentMatches(
            deferred_gate, current)) {
        return current;
    }
    if (m_shadow_pow_relay_reject_tip != current.active_tip ||
        m_shadow_pow_relay_reject_wallet_generation !=
            current.wallet_generation ||
        m_shadow_pow_relay_reject_candidate_state !=
            current.candidate_state_fingerprint) {
        m_shadow_pow_relay_reject_txids.clear();
        m_shadow_pow_relay_wait_roots.clear();
        m_shadow_pow_relay_reject_tip = current.active_tip;
        m_shadow_pow_relay_reject_wallet_generation =
            current.wallet_generation;
        m_shadow_pow_relay_reject_candidate_state =
            current.candidate_state_fingerprint;
    }
    m_shadow_pow_relay_wait_roots.insert(
        current.lineage_root_txid);
    suppression.active_tip = current.active_tip;
    suppression.wallet_generation = current.wallet_generation;
    suppression.candidate_state_fingerprint =
        current.candidate_state_fingerprint;
    return BuildShadowPowClaimMiningGateImpl(inventory, &suppression);
}

uint256 ComputeShadowPowClaimRecoveryPlanId(
    const ShadowPowClaimRecoveryPlan& plan,
    const std::vector<uint256>& selectors)
{
    std::vector<uint256> ordered_selectors = selectors;
    SortUnique(ordered_selectors);

    HashWriter hasher{};
    hasher << uint8_t{1};
    hasher << plan.active_tip;
    hasher << plan.active_height;
    hasher << plan.wallet_generation;
    hasher << static_cast<uint8_t>(plan.origin);
    hasher << plan.max_fee_per_resolution;
    hasher << plan.aggregate_batch_fee_cap;
    hasher << plan.fee_rate_atoms_per_k.has_value();
    if (plan.fee_rate_atoms_per_k) {
        hasher << *plan.fee_rate_atoms_per_k;
    }
    hasher << ordered_selectors;
    hasher << static_cast<uint64_t>(plan.actions.size());
    for (const ShadowPowClaimRecoveryAction& action : plan.actions) {
        hasher << action.anchor;
        hasher << action.generation_fingerprint;
        hasher << action.component_fingerprint;
        hasher << action.fee;
        hasher << action.vsize;
        hasher << static_cast<bool>(action.transaction);
        if (action.transaction) {
            // Bind explicit consent to the exact unsigned preview bytes or
            // exact persisted signed bytes, not merely to fee/anchor fields.
            hasher << action.transaction->GetWitnessHash();
        }
        hasher << static_cast<uint8_t>(action.status);
        hasher << action.persisted;
        hasher << action.in_mempool;
        hasher << action.relay_authorized;
        hasher << action.relay_revoked;
    }
    hasher << static_cast<uint64_t>(plan.refused.size());
    for (const ShadowPowClaimRecoveryAction& refused : plan.refused) {
        hasher << refused.anchor;
        hasher << refused.generation_fingerprint;
        hasher << refused.component_fingerprint;
        hasher << static_cast<uint8_t>(refused.component_state);
        hasher << refused.reason_code;
    }
    return hasher.GetHash();
}

namespace {

const char* RecoveryOriginString(ShadowPowClaimRecoveryOrigin origin)
{
    return origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC
               ? SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC
               : SHADOW_POW_RESOLUTION_ORIGIN_MANUAL;
}

bool IsResolutionNode(ShadowPowClaimRecoveryNodeKind kind)
{
    return kind == ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION ||
           kind == ShadowPowClaimRecoveryNodeKind::LEGACY_RESOLUTION;
}

const ShadowPowClaimRecoveryNode* FindNode(
    const ShadowPowClaimRecoveryComponent& component, const uint256& txid)
{
    const auto found = std::find_if(
        component.nodes.begin(), component.nodes.end(),
        [&](const ShadowPowClaimRecoveryNode& node) {
            return node.txid == txid;
        });
    return found == component.nodes.end() ? nullptr : &*found;
}

bool ComponentSelected(const ShadowPowClaimRecoveryComponent& component,
                       const std::set<uint256>& selectors)
{
    if (selectors.empty()) return true;
    return std::any_of(component.nodes.begin(), component.nodes.end(),
                       [&](const ShadowPowClaimRecoveryNode& node) {
                           return selectors.count(node.txid) != 0;
                       });
}

bool SafeClaimGraphForRecovery(
    const ShadowPowClaimRecoveryComponent& component,
    ShadowPowClaimRecoveryOrigin origin, std::string& reason_code,
    std::string& reason)
{
    auto refuse = [&](const char* code, const char* message) {
        reason_code = code;
        reason = message;
        return false;
    };
    if (component.state ==
        ShadowPowClaimRecoveryState::RETIRED_ON_ACTIVE_BRANCH) {
        return refuse(
            "claim-expired-locally-retired",
            "the component has an inconsistent deprecated local-retirement classification; reopen and repair its retained claim records before recovery");
    }
    if (component.all_claims_zero_payment_retirable) {
        return refuse(
            "zero-payment-retirement-pending",
            "the component has an inconsistent deprecated zero-payment-retirement classification; repair its retained claim records before recovery");
    }
    if (!component.anchor_authenticated || component.anchor.IsNull() ||
        component.generation_fingerprint.IsNull()) {
        return refuse("anchor-not-authenticated",
                      "component has no authenticated confirmed wallet anchor");
    }
    if (!component.anchor_unspent) {
        return refuse("anchor-spent",
                      "confirmed anchor is already spent on the active chain");
    }
    if (component.claim_txids.empty()) {
        return refuse("component-no-claims",
                      "component contains no claim transactions");
    }
    if (!component.ordinary_or_mixed_txids.empty()) {
        return refuse("ordinary-conflict",
                      "component contains an ordinary, mixed, or malformed wallet transaction");
    }
    if (component.resolution_txids.size() > 1) {
        return refuse("multiple-resolutions",
                      "more than one wallet-known resolution spends this anchor generation");
    }

    size_t claims_seen{0};
    for (const ShadowPowClaimRecoveryNode& node : component.nodes) {
        if (node.kind == ShadowPowClaimRecoveryNodeKind::CLAIM) {
            ++claims_seen;
            if (node.active_chain_confirmed) {
                return refuse("claim-confirmed",
                              "a component claim is confirmed on the active chain");
            }
            if (node.in_mempool) {
                return refuse("claim-live",
                              "a component claim is still live in the local mempool");
            }
            if (!node.quarantined) {
                return refuse("claim-not-quarantined",
                              "a component claim lacks persistent quarantine provenance");
            }
            if (!node.wallet_authored) {
                return refuse("claim-foreign-or-unspendable",
                              "a component claim is foreign or not wallet-spendable");
            }
            if (!node.expected_shape) {
                return refuse("claim-malformed",
                              "a component claim is malformed or multi-input");
            }
            if (!IsShadowPowClaimCurrentBranchTerminal(node.disposition) &&
                node.disposition !=
                    ShadowPowClaimMempoolDisposition::UNBOUND_PROOF_MAY_REVALIDATE) {
                return refuse("claim-not-terminal",
                              "a component claim remains live, transient, or indeterminate on the pinned tip");
            }
            if (origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC &&
                node.provenance !=
                    ShadowPowClaimRecoveryProvenance::EXPLICIT_AUTHORED &&
                node.provenance !=
                    ShadowPowClaimRecoveryProvenance::EXPLICIT_ADOPTED) {
                return refuse("automatic-provenance-missing",
                              "automatic recovery requires explicit wallet-authored or adopted provenance");
            }
        } else if (node.kind == ShadowPowClaimRecoveryNodeKind::ORDINARY) {
            return refuse("ordinary-conflict",
                          "component contains an ordinary, mixed, or malformed wallet transaction");
        }
    }
    if (claims_seen != component.claim_txids.size()) {
        return refuse("incomplete-claim-graph",
                      "component claim graph is incomplete");
    }
    reason_code.clear();
    reason.clear();
    return true;
}

bool SafeGraphForAdoption(const ShadowPowClaimRecoveryComponent& component,
                          std::string& reason_code, std::string& reason)
{
    if (!SafeClaimGraphForRecovery(
            component, ShadowPowClaimRecoveryOrigin::MANUAL,
            reason_code, reason)) {
        return false;
    }
    if (!component.resolution_txids.empty()) {
        reason_code = "resolution-present";
        reason = "a component with a resolution transaction cannot be adopted";
        return false;
    }
    reason_code.clear();
    reason.clear();
    return true;
}

ShadowPowClaimRecoveryUsage BuildRecoveryUsageLocked(
    const CWallet& wallet, const ShadowPowClaimRecoveryInventory& inventory,
    uint32_t rolling_window_seconds)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);
    ShadowPowClaimRecoveryUsage usage;
    const CBlockIndex* accounting_tip =
        wallet.chain().chainman().ActiveChain().Tip();
    int64_t now = std::max<int64_t>(
        1, accounting_tip ? accounting_tip->GetMedianTimePast() : 1);
    std::map<uint256, ManagedResolutionFacts> managed_records;
    for (const auto& [txid, wtx] : wallet.mapWallet) {
        ManagedResolutionFacts facts;
        if (!ParseManagedResolutionFacts(wallet, wtx, facts)) continue;
        // Candidate transactions are deterministically stamped pinned-tip
        // MTP+1. Floor legacy wall-clock metadata at that chain-derived time
        // so an old backward-skewed host clock cannot erase budget usage.
        if (wtx.tx && wtx.tx->nTime > 1) {
            facts.created_time = std::max<int64_t>(
                facts.created_time,
                static_cast<int64_t>(wtx.tx->nTime) - 1);
        }
        managed_records.emplace(txid, facts);
    }
    const int64_t window_start =
        now - static_cast<int64_t>(rolling_window_seconds);
    std::set<COutPoint> confirmed_managed_outputs;

    for (const ShadowPowClaimRecoveryComponent& component : inventory.components) {
        if (component.state ==
            ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN) {
            usage.reconciled_descendant_claims += component.descendant_claims;
        }
    }

    // Managed facts outlive the current unconfirmed-claim inventory. This is
    // essential when the original claim confirms first: the losing exact
    // resolution still consumed one authorized action and fee exposure, even
    // if no sibling claim remains to seed an inventory component.
    for (const auto& [txid, facts] : managed_records) {
        const CWalletTx& wtx = wallet.mapWallet.at(txid);
        const bool automatic =
            facts.origin == SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC;
        if (wallet.GetTxDepthInMainChain(wtx) > 0) {
            if (automatic) {
                ++usage.confirmed_automatic;
            } else {
                ++usage.confirmed_manual;
            }
            usage.confirmed_resolution_fees += facts.fee;
            // Managed resolutions are authenticated above as exact one-input,
            // one-output transactions. Recycling authority therefore belongs
            // only to their sole confirmed output, never to another vout that
            // merely shares the transaction hash.
            confirmed_managed_outputs.emplace(txid, 0);
        } else if (wtx.isUnconfirmed()) {
            if (automatic) {
                ++usage.pending_automatic;
            } else {
                ++usage.pending_manual;
            }
        }
        // A future-dated legacy record is conservatively age zero until chain
        // MTP catches it. Never advance `now` to that record: doing so would
        // move window_start past other genuinely recent MTP-stamped actions
        // and undercount the operator's action and fee budgets.
        const int64_t accounting_created_time =
            std::min(facts.created_time, now);
        if (automatic && accounting_created_time >= window_start) {
            ++usage.automatic_actions_in_window;
            usage.automatic_fee_exposure_in_window += facts.fee;
        }
    }

    std::set<uint256> recycled_claims;
    for (const auto& [txid, wtx] : wallet.mapWallet) {
        if (!wtx.tx || !TransactionHasShadowProof(*wtx.tx)) continue;
        if (std::any_of(wtx.tx->vin.begin(), wtx.tx->vin.end(),
                        [&](const CTxIn& input) {
                            return confirmed_managed_outputs.count(
                                       input.prevout) != 0;
                        })) {
            recycled_claims.insert(txid);
        }
    }
    usage.recycled_outputs = recycled_claims.size();
    return usage;
}

ShadowPowClaimRecoveryPlan BuildRecoveryPlanLocked(
    const CWallet& wallet, const ShadowPowClaimRecoveryRequest& request,
    const ShadowPowClaimRecoveryPolicy* automatic_policy)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);

    ShadowPowClaimRecoveryPlan plan;
    plan.origin = request.origin;
    plan.max_fee_per_resolution = request.max_fee_per_resolution;
    plan.aggregate_batch_fee_cap = request.aggregate_batch_fee_cap;
    if (request.fee_rate) {
        plan.fee_rate_atoms_per_k = request.fee_rate->GetFeePerK();
    }

    const ShadowPowClaimRecoveryInventory inventory =
        wallet.GetShadowPowClaimRecoveryInventoryLocked();
    plan.active_tip = inventory.active_tip;
    plan.active_height = inventory.active_height;
    plan.wallet_generation = inventory.wallet_generation;
    plan.wallet_tip_matches = inventory.wallet_tip_matches;
    if (inventory.recovery_database_ambiguous) {
        ShadowPowClaimRecoveryAction refused;
        refused.reason_code = "database-outcome-ambiguous";
        refused.detail = "wallet recovery or coin-lock database outcome is ambiguous; reload and inspect exact records before any new plan";
        plan.refused.push_back(std::move(refused));
        plan.complete = false;
        plan.plan_id = ComputeShadowPowClaimRecoveryPlanId(
            plan, request.selectors);
        return plan;
    }
    if (!inventory.wallet_tip_matches || inventory.active_tip.IsNull()) {
        plan.complete = false;
        plan.plan_id = ComputeShadowPowClaimRecoveryPlanId(
            plan, request.selectors);
        return plan;
    }

    if (request.max_fee_per_resolution <= 0 ||
        request.max_fee_per_resolution > wallet.m_default_max_tx_fee ||
        request.aggregate_batch_fee_cap < request.max_fee_per_resolution ||
        request.aggregate_batch_fee_cap <= 0) {
        ShadowPowClaimRecoveryAction refused;
        refused.reason_code = "invalid-fee-limits";
        refused.detail = "invalid recovery fee limits";
        plan.refused.push_back(std::move(refused));
        plan.complete = true;
        plan.plan_id = ComputeShadowPowClaimRecoveryPlanId(
            plan, request.selectors);
        return plan;
    }

    ShadowPowClaimRecoveryUsage automatic_usage;
    if (request.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC) {
        if (!automatic_policy || !automatic_policy->HasAutomaticAuthority() ||
            !ValidateShadowPowClaimRecoveryPolicy(*automatic_policy)) {
            ShadowPowClaimRecoveryAction refused;
            refused.reason_code = "automatic-authority-missing";
            refused.detail = "automatic recovery has no valid persisted operator authority";
            plan.refused.push_back(std::move(refused));
            plan.complete = true;
            plan.plan_id = ComputeShadowPowClaimRecoveryPlanId(
                plan, request.selectors);
            return plan;
        }
        if (!wallet.m_pow_mining_enabled.load()) {
            ShadowPowClaimRecoveryAction refused;
            refused.reason_code = "miner-not-enabled";
            refused.detail = "automatic recovery requires an already-enabled Gold Rush miner";
            plan.refused.push_back(std::move(refused));
            plan.complete = true;
            plan.plan_id = ComputeShadowPowClaimRecoveryPlanId(
                plan, request.selectors);
            return plan;
        }
        if (!wallet.GetBroadcastTransactions() ||
            !wallet.chain().isReadyToBroadcast()) {
            ShadowPowClaimRecoveryAction refused;
            refused.reason_code = "chain-or-broadcast-unavailable";
            refused.detail = "automatic recovery requires synchronized chain and wallet broadcast";
            plan.refused.push_back(std::move(refused));
            plan.complete = true;
            plan.plan_id = ComputeShadowPowClaimRecoveryPlanId(
                plan, request.selectors);
            return plan;
        }
        automatic_usage = BuildRecoveryUsageLocked(
            wallet, inventory,
            automatic_policy->rolling_fee_window_seconds);
    }

    std::set<uint256> selector_set{
        request.selectors.begin(), request.selectors.end()};
    std::set<uint256> matched_selectors;
    CAmount new_automatic_fees{0};
    size_t new_automatic_actions{0};
    const CBlockIndex* pinned_tip =
        wallet.chain().chainman().ActiveChain().Tip();
    if (!pinned_tip || pinned_tip->GetBlockHash() != inventory.active_tip) {
        plan.complete = false;
        plan.plan_id = ComputeShadowPowClaimRecoveryPlanId(
            plan, request.selectors);
        return plan;
    }
    // The preview and later execution must construct byte-identical unsigned
    // transactions for one pinned tip. Wall-clock nTime would let the bytes
    // change without changing chain or wallet state, defeating an exact plan
    // acknowledgement. MTP+1 is deterministic for the tip and valid for a
    // next-block ordinary transaction.
    const uint32_t transaction_time = static_cast<uint32_t>(
        std::min<int64_t>(std::numeric_limits<uint32_t>::max(),
                          std::max<int64_t>(1,
                              pinned_tip->GetMedianTimePast() + 1)));

    for (const ShadowPowClaimRecoveryComponent& component :
         inventory.components) {
        if (!ComponentSelected(component, selector_set)) continue;
        for (const ShadowPowClaimRecoveryNode& node : component.nodes) {
            if (selector_set.count(node.txid)) matched_selectors.insert(node.txid);
        }

        ShadowPowClaimRecoveryAction action;
        action.anchor = component.anchor;
        action.generation_fingerprint = component.generation_fingerprint;
        action.component_fingerprint = component.fingerprint;
        action.claim_txids = component.claim_txids;
        action.descendant_claims = component.descendant_claims;
        action.component_state = component.state;
        action.conflicts_with_revalidating_unbound_proof =
            component.has_revalidating_unbound_proof;

        if (component.anchor_user_locked) {
            action.reason_code = "anchor-user-locked";
            action.detail =
                "the confirmed recovery anchor is user-locked; explicitly unlock this outpoint before previewing a fee-paying recovery";
            plan.refused.push_back(std::move(action));
            continue;
        }

        std::string refusal_code;
        std::string refusal;
        if (!SafeClaimGraphForRecovery(
                component, request.origin, refusal_code, refusal)) {
            action.reason_code = std::move(refusal_code);
            action.detail = std::move(refusal);
            plan.refused.push_back(std::move(action));
            continue;
        }
        if (action.conflicts_with_revalidating_unbound_proof) {
            action.reason_code = "unbound-proof-may-revalidate";
            action.detail =
                "the exact claim proof is invalid only on the pinned tip and may become valid on a descendant; executing this resolution deliberately conflicts with that future-validity possibility";
        }

        const ShadowPowClaimRecoveryNode* existing_node{nullptr};
        if (!component.resolution_txids.empty()) {
            existing_node = FindNode(component,
                                     component.resolution_txids.front());
            if (!existing_node || !IsResolutionNode(existing_node->kind)) {
                action.detail = "wallet-known resolution metadata is incomplete";
                action.reason_code = "resolution-metadata-invalid";
                plan.refused.push_back(std::move(action));
                continue;
            }
            action.relay_authorized =
                existing_node->kind ==
                    ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION &&
                existing_node->resolution_relay_authorized;
            action.relay_revoked =
                existing_node->kind ==
                    ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION &&
                existing_node->resolution_relay_revoked;
            if (request.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC &&
                existing_node->kind ==
                    ShadowPowClaimRecoveryNodeKind::LEGACY_RESOLUTION) {
                action.detail = "legacy cleanup transactions require explicit manual relay";
                action.reason_code = "legacy-manual-only";
                plan.refused.push_back(std::move(action));
                continue;
            }
            if (request.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC &&
                existing_node->resolution_relay_revoked) {
                action.detail = "local relay authority for this exact managed resolution was explicitly revoked";
                action.reason_code = "resolution-relay-revoked";
                plan.refused.push_back(std::move(action));
                continue;
            }
            if (request.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC &&
                (existing_node->resolution_origin !=
                     SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC ||
                 !existing_node->resolution_relay_authorized)) {
                action.detail = "automatic recovery may retry only its own commit-authorized managed resolution";
                action.reason_code = "automatic-cannot-promote-draft";
                plan.refused.push_back(std::move(action));
                continue;
            }
            const auto tx_it = wallet.mapWallet.find(existing_node->txid);
            if (tx_it == wallet.mapWallet.end() || !tx_it->second.tx ||
                tx_it->second.tx->vout.size() != 1) {
                action.detail = "persisted resolution transaction is unavailable";
                action.reason_code = "resolution-unavailable";
                plan.refused.push_back(std::move(action));
                continue;
            }
            action.transaction = tx_it->second.tx;
            if (request.fee_rate) {
                action.detail = "an explicit fee rate cannot modify an already-signed resolution";
                action.reason_code = "fee-rate-cannot-modify-signed";
                plan.refused.push_back(std::move(action));
                continue;
            }
            action.fee = component.anchor_amount -
                         action.transaction->vout.front().nValue;
            action.vsize = GetVirtualTransactionSize(*action.transaction);
            action.persisted = true;
            action.in_mempool = existing_node->in_mempool;
            action.status =
                existing_node->kind ==
                        ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION
                    ? ShadowPowClaimRecoveryActionStatus::REUSE_MANAGED
                    : ShadowPowClaimRecoveryActionStatus::REUSE_LEGACY;
        } else {
            // A locked wallet may safely retry only an exact transaction that
            // already has durable relay authority. It must never construct a
            // new automatic spend.
            if (request.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC &&
                (!wallet.HasPrivateKeys() ||
                 wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS) ||
                 wallet.IsWalletFlagSet(WALLET_FLAG_EXTERNAL_SIGNER) ||
                 wallet.IsLocked() || wallet.m_wallet_unlock_staking_only)) {
                action.detail = "automatic recovery requires normal local private-key wallet unlock to create a resolution";
                action.reason_code = "wallet-signing-unavailable";
                plan.refused.push_back(std::move(action));
                continue;
            }
            CMutableTransaction candidate;
            candidate.nVersion = CTransaction::CURRENT_VERSION;
            candidate.nTime = transaction_time;
            candidate.vin.emplace_back(component.anchor, CScript(),
                                       std::numeric_limits<uint32_t>::max());
            candidate.vout.emplace_back(component.anchor_amount,
                                        component.anchor_script);

            CCoinControl coin_control;
            coin_control.m_allow_other_inputs = false;
            coin_control.m_avoid_address_reuse = false;
            coin_control.m_min_depth = 1;
            if (request.fee_rate) {
                coin_control.m_feerate = *request.fee_rate;
                coin_control.fOverrideFeeRate = true;
            }
            const TxSize tx_size = CalculateMaximumSignedTxSize(
                CTransaction(candidate), &wallet, &coin_control);
            if (tx_size.vsize <= 0) {
                action.detail = "wallet cannot estimate the signed resolution size";
                action.reason_code = "fee-estimation-failed";
                plan.refused.push_back(std::move(action));
                continue;
            }
            action.vsize = tx_size.vsize;
            const CFeeRate fee_rate = GetMinimumFeeRate(
                wallet, coin_control, transaction_time);
            if (request.fee_rate && fee_rate > *request.fee_rate) {
                action.detail = "explicit fee rate is below the wallet minimum";
                action.reason_code = "fee-rate-below-minimum";
                plan.refused.push_back(std::move(action));
                continue;
            }
            action.fee = std::max<CAmount>(
                1, std::max(
                       GetMinFee(static_cast<size_t>(tx_size.vsize),
                                 transaction_time),
                       fee_rate.GetFee(static_cast<uint32_t>(
                           tx_size.vsize))));
            if (action.fee >= component.anchor_amount ||
                !MoneyRange(component.anchor_amount - action.fee)) {
                action.detail = "resolution fee consumes the confirmed anchor";
                action.reason_code = "fee-consumes-anchor";
                plan.refused.push_back(std::move(action));
                continue;
            }
            candidate.vout.front().nValue =
                component.anchor_amount - action.fee;
            if (IsDust(candidate.vout.front(),
                       wallet.chain().relayDustFee())) {
                action.detail = "resolution output would be dust";
                action.reason_code = "resolution-output-dust";
                plan.refused.push_back(std::move(action));
                continue;
            }
            action.transaction = MakeTransactionRef(std::move(candidate));
            action.status = ShadowPowClaimRecoveryActionStatus::READY;
        }

        // Persisted bytes are immutable, but relay dust policy can change
        // across releases. Refuse them in the read-only plan instead of
        // advertising an action that only the later mutation preflight will
        // reject.
        if (!action.transaction || action.transaction->vout.size() != 1 ||
            IsDust(action.transaction->vout.front(),
                   wallet.chain().relayDustFee())) {
            action.detail = "resolution output is dust under current relay policy";
            action.reason_code = "resolution-output-dust";
            plan.refused.push_back(std::move(action));
            continue;
        }

        if (action.fee <= 0 || action.fee > request.max_fee_per_resolution ||
            action.fee > wallet.m_default_max_tx_fee) {
            action.detail = "resolution fee exceeds the configured or wallet maximum";
            action.reason_code = "fee-limit-exceeded";
            plan.refused.push_back(std::move(action));
            continue;
        }
        if (plan.total_fee > request.aggregate_batch_fee_cap - action.fee) {
            action.detail = "aggregate batch fee cap would be exceeded";
            action.reason_code = "batch-fee-cap-exceeded";
            plan.refused.push_back(std::move(action));
            continue;
        }

        if (request.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC &&
            !action.persisted) {
            if (!component.stale_depth_known ||
                component.minimum_stale_depth <
                    static_cast<int>(automatic_policy->minimum_stale_blocks)) {
                action.detail = "component has not satisfied the persisted stale-depth policy";
                action.reason_code = "stale-depth-not-met";
                plan.refused.push_back(std::move(action));
                continue;
            }
            if (automatic_usage.automatic_actions_in_window +
                    new_automatic_actions >=
                automatic_policy->max_actions_per_window) {
                action.detail = "automatic recovery action-rate budget is exhausted";
                action.reason_code = "action-rate-exhausted";
                plan.refused.push_back(std::move(action));
                continue;
            }
            if (automatic_usage.automatic_fee_exposure_in_window +
                    new_automatic_fees >
                automatic_policy->rolling_fee_budget - action.fee) {
                action.detail = "automatic recovery rolling fee budget is exhausted";
                action.reason_code = "rolling-fee-budget-exhausted";
                plan.refused.push_back(std::move(action));
                continue;
            }
            ++new_automatic_actions;
            new_automatic_fees += action.fee;
        }

        plan.total_fee += action.fee;
        plan.actions.push_back(std::move(action));
    }

    for (const uint256& selector : selector_set) {
        if (matched_selectors.count(selector) != 0) continue;
        ShadowPowClaimRecoveryAction refused;
        refused.reason_code = "selector-not-found";
        refused.detail = "selector is not a claim or resolution in the current wallet graph";
        refused.claim_txids.push_back(selector);
        plan.refused.push_back(std::move(refused));
    }

    for (ShadowPowClaimRecoveryAction& refused : plan.refused) {
        refused.status = ShadowPowClaimRecoveryActionStatus::REFUSED;
    }
    plan.complete = true;
    plan.plan_id = ComputeShadowPowClaimRecoveryPlanId(plan,
                                                       request.selectors);
    return plan;
}

} // namespace

const char* ShadowPowClaimRecoveryAdoptionStatusName(
    ShadowPowClaimRecoveryAdoptionStatus status)
{
    switch (status) {
    case ShadowPowClaimRecoveryAdoptionStatus::SUCCESS: return "success";
    case ShadowPowClaimRecoveryAdoptionStatus::ALREADY_EXPLICIT: return "already_explicit";
    case ShadowPowClaimRecoveryAdoptionStatus::NO_CHAIN: return "no_chain";
    case ShadowPowClaimRecoveryAdoptionStatus::DATABASE_OUTCOME_AMBIGUOUS: return "database_outcome_ambiguous";
    case ShadowPowClaimRecoveryAdoptionStatus::SIGNING_UNAVAILABLE: return "signing_unavailable";
    case ShadowPowClaimRecoveryAdoptionStatus::STALE_TIP: return "stale_tip";
    case ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_NOT_FOUND: return "selector_not_found";
    case ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_NOT_CLAIM: return "selector_not_claim";
    case ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_AMBIGUOUS: return "selector_ambiguous";
    case ShadowPowClaimRecoveryAdoptionStatus::STALE_COMPONENT_FINGERPRINT: return "stale_component_fingerprint";
    case ShadowPowClaimRecoveryAdoptionStatus::UNSAFE_GRAPH: return "unsafe_graph";
    case ShadowPowClaimRecoveryAdoptionStatus::DATABASE_FAILURE: return "database_failure";
    }
    return "database_failure";
}

const char* ShadowPowClaimRecoveryPolicyMutationStatusName(
    ShadowPowClaimRecoveryPolicyMutationStatus status)
{
    switch (status) {
    case ShadowPowClaimRecoveryPolicyMutationStatus::SUCCESS: return "success";
    case ShadowPowClaimRecoveryPolicyMutationStatus::INVALID_POLICY: return "invalid_policy";
    case ShadowPowClaimRecoveryPolicyMutationStatus::DATABASE_FAILURE: return "database_failure";
    case ShadowPowClaimRecoveryPolicyMutationStatus::DATABASE_OUTCOME_AMBIGUOUS: return "database_outcome_ambiguous";
    }
    return "database_failure";
}

const char* ShadowPowClaimResolutionRevocationStatusName(
    ShadowPowClaimResolutionRevocationStatus status)
{
    switch (status) {
    case ShadowPowClaimResolutionRevocationStatus::SUCCESS: return "success";
    case ShadowPowClaimResolutionRevocationStatus::ALREADY_REVOKED: return "already_revoked";
    case ShadowPowClaimResolutionRevocationStatus::NOT_FOUND: return "not_found";
    case ShadowPowClaimResolutionRevocationStatus::NOT_MANAGED: return "not_managed";
    case ShadowPowClaimResolutionRevocationStatus::INVALID_METADATA: return "invalid_metadata";
    case ShadowPowClaimResolutionRevocationStatus::ANCHOR_NOT_RESERVED: return "anchor_not_reserved";
    case ShadowPowClaimResolutionRevocationStatus::BROADCAST_IN_FLIGHT: return "broadcast_in_flight";
    case ShadowPowClaimResolutionRevocationStatus::DATABASE_FAILURE: return "database_failure";
    case ShadowPowClaimResolutionRevocationStatus::DATABASE_OUTCOME_AMBIGUOUS: return "database_outcome_ambiguous";
    }
    return "database_failure";
}

bool CWallet::PersistNewManagedShadowPowResolution(
    const ShadowPowClaimRecoveryAction& action,
    ShadowPowClaimRecoveryOrigin origin, bool relay_authorized,
    int active_height, int64_t created_time, std::string& error)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(cs_wallet);
    if (m_shadow_pow_claim_recovery_db_ambiguous) {
        error = "recovery database outcome is ambiguous; reload wallet before persistence";
        return false;
    }
    if (!action.transaction || action.claim_txids.empty()) {
        error = "resolution action has no transaction or claim provenance";
        return false;
    }
    const uint256 txid = action.transaction->GetHash();
    const auto existing = mapWallet.find(txid);
    if (existing != mapWallet.end()) {
        error = existing->second.tx->GetWitnessHash() ==
                        action.transaction->GetWitnessHash()
                    ? "resolution appeared before persistence; replan and validate its durable metadata"
                    : "wallet contains different bytes for the resolution txid";
        return false;
    }

    mapValue_t metadata;
    metadata[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
        SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
    metadata[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
        action.anchor.hash.GetHex();
    metadata[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
        ToString(action.anchor.n);
    metadata[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
        action.generation_fingerprint.GetHex();
    metadata[SHADOW_POW_RESOLUTION_ORIGIN_KEY] =
        RecoveryOriginString(origin);
    metadata[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
        ToString(active_height);
    metadata[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] =
        ToString(created_time);
    metadata[SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY] =
        relay_authorized ? "1" : "0";
    metadata[SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY] = "0";
    metadata[SHADOW_POW_LEGACY_CLEANUP_FOR_KEY] =
        (*std::min_element(action.claim_txids.begin(),
                           action.claim_txids.end())).GetHex();

    WalletBatch batch(GetDatabase());
    if (!batch.TxnBegin(/*durable=*/true)) {
        error = "failed to begin durable resolution transaction update";
        return false;
    }
    const int64_t old_order_pos_next = nOrderPosNext;
    CWalletTx record(action.transaction, TxStateInactive{});
    record.mapValue = std::move(metadata);
    record.fTimeReceivedIsTxTime = true;
    record.fFromMe = true;
    record.nTimeReceived = GetTime();
    record.nOrderPos = nOrderPosNext++;
    record.nTimeSmart = ComputeTimeSmart(
        record, /*rescanning_old_block=*/false);

    if (!batch.WriteOrderPosNext(nOrderPosNext) ||
        !batch.WriteTx(record)) {
        nOrderPosNext = old_order_pos_next;
        if (!batch.TxnAbort()) {
            MarkShadowPowClaimRecoveryDatabaseAmbiguous();
            error = "signed resolution write and rollback outcomes are ambiguous; reload the wallet";
        } else {
            error = "failed to durably write signed resolution transaction";
        }
        return false;
    }
    if (!batch.TxnCommit()) {
        nOrderPosNext = old_order_pos_next;
        batch.TxnAbort();
        MarkShadowPowClaimRecoveryDatabaseAmbiguous();
        error = "resolution database commit outcome is ambiguous; reload the wallet before retrying";
        return false;
    }

    const auto [wallet_it, inserted] = mapWallet.emplace(
        std::piecewise_construct, std::forward_as_tuple(txid),
        std::forward_as_tuple(action.transaction, TxStateInactive{}));
    if (!inserted) {
        error = "resolution appeared in the wallet during durable persistence";
        return false;
    }
    CWalletTx& committed = wallet_it->second;
    committed.CopyFrom(record);
    committed.m_it_wtxOrdered = wtxOrdered.insert(
        std::make_pair(committed.nOrderPos, &committed));
    AddToSpends(committed);
    RefreshLiveUnspentStakeOutpoints(committed);
    MaybeUpdateBirthTime(committed.GetTxTime());
    committed.MarkDirty();
    NotifyTransactionChanged(txid, CT_NEW);
    const auto parent = mapWallet.find(action.anchor.hash);
    if (parent != mapWallet.end()) {
        parent->second.MarkDirty();
        NotifyTransactionChanged(parent->first, CT_UPDATED);
    }
    return true;
}

bool CWallet::SetManagedShadowPowResolutionRelayAuthority(
    const uint256& txid, bool authorized,
    bool explicit_reauthorization, std::string& error)
{
    AssertLockHeld(cs_wallet);
    if (m_shadow_pow_claim_recovery_db_ambiguous ||
        m_locked_coins_db_ambiguous) {
        error = "recovery or coin-lock database outcome is ambiguous; reload wallet before relay-authority mutation";
        return false;
    }
    const auto it = mapWallet.find(txid);
    if (it == mapWallet.end() || !it->second.tx) {
        error = "persisted managed resolution disappeared";
        return false;
    }
    const auto schema = it->second.mapValue.find(
        SHADOW_POW_RESOLUTION_SCHEMA_KEY);
    if (schema == it->second.mapValue.end() ||
        schema->second != SHADOW_POW_RESOLUTION_SCHEMA_VERSION) {
        error = "legacy resolution has no managed relay-authority record";
        return false;
    }
    ManagedResolutionFacts facts;
    if (!ParseManagedResolutionFacts(*this, it->second, facts)) {
        error = "managed resolution metadata is invalid";
        return false;
    }
    if (authorized && facts.relay_revoked && !explicit_reauthorization) {
        error = "managed resolution relay authority was explicitly revoked; use a fresh exact recovery plan to reauthorize it";
        return false;
    }
    const bool desired_revoked = !authorized;
    if (facts.relay_authorized == authorized &&
        facts.relay_revoked == desired_revoked) {
        return true;
    }

    CWalletTx persisted(it->second.tx, it->second.m_state);
    persisted.CopyFrom(it->second);
    persisted.mapValue[SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY] =
        authorized ? "1" : "0";
    persisted.mapValue[SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY] =
        desired_revoked ? "1" : "0";
    WalletBatch batch(GetDatabase());
    if (!batch.TxnBegin(/*durable=*/true)) {
        error = "failed to begin durable managed-resolution relay-authority update";
        return false;
    }
    if (!batch.WriteTx(persisted)) {
        if (!batch.TxnAbort()) {
            MarkShadowPowClaimRecoveryDatabaseAmbiguous();
            error = "relay-authority write and rollback outcomes are ambiguous; reload the wallet";
        } else {
            error = "failed to write managed resolution relay authority";
        }
        return false;
    }
    if (!batch.TxnCommit()) {
        batch.TxnAbort();
        MarkShadowPowClaimRecoveryDatabaseAmbiguous();
        error = "relay-authority commit outcome is ambiguous; reload the wallet before retrying";
        return false;
    }
    it->second.mapValue[SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY] =
        authorized ? "1" : "0";
    it->second.mapValue[SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY] =
        desired_revoked ? "1" : "0";
    it->second.MarkDirty();
    NotifyTransactionChanged(txid, CT_UPDATED);
    return true;
}

ShadowPowClaimResolutionRevocationResult
CWallet::RevokeManagedShadowPowResolutionRelayAuthority(
    const uint256& txid)
{
    ShadowPowClaimResolutionRevocationResult result;
    result.resolution_txid = txid;

    // Serialize against planning, signing, relay promotion, and the recovery
    // scheduler. Generic wallet broadcasts use m_inflight_wallet_broadcasts;
    // the wallet lock below makes that reservation and this tombstone one
    // total order as well.
    LOCK(m_pow_recovery_authority_mutex);
    const auto revoke_locked = [&] {
        LOCK(cs_wallet);
        if (m_shadow_pow_claim_recovery_db_ambiguous ||
            m_locked_coins_db_ambiguous) {
            result.status =
                ShadowPowClaimResolutionRevocationStatus::DATABASE_OUTCOME_AMBIGUOUS;
            result.durable_state_ambiguous = true;
            result.detail = "a prior recovery or coin-lock database commit had an ambiguous outcome; reload the wallet before revocation";
            return;
        }

        const auto it = mapWallet.find(txid);
        if (it == mapWallet.end() || !it->second.tx) {
            result.status = ShadowPowClaimResolutionRevocationStatus::NOT_FOUND;
            result.detail = "managed claim-resolution transaction not found in this wallet";
            return;
        }
        const auto schema = it->second.mapValue.find(
            SHADOW_POW_RESOLUTION_SCHEMA_KEY);
        if (schema == it->second.mapValue.end() ||
            schema->second != SHADOW_POW_RESOLUTION_SCHEMA_VERSION) {
            result.status = ShadowPowClaimResolutionRevocationStatus::NOT_MANAGED;
            result.detail = "transaction is not an authenticated managed claim resolution";
            return;
        }

        ManagedResolutionFacts facts;
        if (!ParseManagedResolutionFacts(*this, it->second, facts)) {
            result.status =
                ShadowPowClaimResolutionRevocationStatus::INVALID_METADATA;
            result.detail = "managed claim-resolution metadata or transaction shape is invalid";
            return;
        }
        result.anchor = facts.anchor;
        result.generation_fingerprint = facts.generation_fingerprint;
        result.relay_authority_was_active = facts.relay_authorized;
        // Validation-interface delivery can lag a caller that immediately
        // revokes after submission. When a chain interface exists, report
        // the node's current mempool truth rather than a potentially older
        // wallet callback state. Chainless wallets can still durably narrow
        // local authority, but must not invent a mempool observation.
        if (HaveChain()) {
            result.in_mempool = chain().isInMempool(txid);
        }
        result.broadcast_in_flight =
            m_inflight_wallet_broadcasts.count(txid) != 0;
        result.may_still_confirm = true;
        result.anchor_reserved = IsSpent(facts.anchor);
        result.normal_coin_selection_enabled = !*result.anchor_reserved;

        if (*result.broadcast_in_flight) {
            result.status =
                ShadowPowClaimResolutionRevocationStatus::BROADCAST_IN_FLIGHT;
            result.detail = "an exact local broadcast is already in flight; wait for its verdict and revoke again";
            return;
        }
        if (!*result.anchor_reserved) {
            result.status =
                ShadowPowClaimResolutionRevocationStatus::ANCHOR_NOT_RESERVED;
            result.detail = "managed resolution anchor is not reserved by the wallet; refusing to report a restriction-only cancellation";
            return;
        }
        if (facts.relay_revoked) {
            result.status =
                ShadowPowClaimResolutionRevocationStatus::ALREADY_REVOKED;
            result.success = true;
            result.relay_authority_revoked = true;
            result.locally_cancelled = true;
            result.detail = "local relay authority was already durably revoked";
        } else {
            std::string error;
            if (!SetManagedShadowPowResolutionRelayAuthority(
                    txid, /*authorized=*/false,
                    /*explicit_reauthorization=*/false, error)) {
                result.durable_state_ambiguous =
                    m_shadow_pow_claim_recovery_db_ambiguous;
                result.status = result.durable_state_ambiguous
                    ? ShadowPowClaimResolutionRevocationStatus::DATABASE_OUTCOME_AMBIGUOUS
                    : ShadowPowClaimResolutionRevocationStatus::DATABASE_FAILURE;
                if (result.durable_state_ambiguous) {
                    // The durable outcome may be either the old authority or
                    // the new tombstone. Never serialize either as factual.
                    result.durable_state_changed.reset();
                    result.relay_authority_revoked.reset();
                    result.locally_cancelled.reset();
                } else {
                    result.relay_authority_revoked = false;
                    result.locally_cancelled = false;
                }
                result.detail = std::move(error);
                return;
            }
            result.status = ShadowPowClaimResolutionRevocationStatus::SUCCESS;
            result.success = true;
            result.durable_state_changed = true;
            result.relay_authority_revoked = true;
            result.locally_cancelled = true;
            result.detail = "local relay authority was durably revoked; exact bytes and the shared anchor remain reserved";
        }
    };
    revoke_locked();

    // Report the post-attempt typed miner consequence when a chain snapshot
    // exists. This read-only gate is computed while the recovery-authority
    // mutex still excludes a competing fresh-plan commit that could clear the
    // tombstone. A chainless wallet leaves it explicitly unavailable rather
    // than mislabelling an unknown gate with a default.
    if (HaveChain()) {
        result.mining_gate_action = GetShadowPowClaimMiningGate().action;
        result.mining_gate_available = true;
    }
    return result;
}

ShadowPowClaimRecoveryPlan CWallet::PlanShadowPowClaimRecovery(
    const ShadowPowClaimRecoveryRequest& request) const
{
    ShadowPowClaimRecoveryRequest effective = request;
    std::optional<ShadowPowClaimRecoveryPolicy> automatic_policy;
    if (request.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC) {
        automatic_policy = GetShadowPowClaimRecoveryPolicy();
        effective.max_fee_per_resolution =
            automatic_policy->max_fee_per_resolution;
        effective.aggregate_batch_fee_cap =
            automatic_policy->aggregate_batch_fee_cap;
    }
    if (!HaveChain() || !chain().isReadyToBroadcast()) {
        ShadowPowClaimRecoveryPlan plan;
        plan.origin = effective.origin;
        plan.max_fee_per_resolution = effective.max_fee_per_resolution;
        plan.aggregate_batch_fee_cap = effective.aggregate_batch_fee_cap;
        if (effective.fee_rate) {
            plan.fee_rate_atoms_per_k = effective.fee_rate->GetFeePerK();
        }
        plan.plan_id = ComputeShadowPowClaimRecoveryPlanId(
            plan, effective.selectors);
        return plan;
    }
    LOCK2(::cs_main, cs_wallet);
    return BuildRecoveryPlanLocked(*this, effective,
                                   automatic_policy
                                       ? &*automatic_policy
                                       : nullptr);
}

ShadowPowClaimRecoveryUsage CWallet::GetShadowPowClaimRecoveryUsage(
    uint32_t rolling_window_seconds) const
{
    if (!HaveChain()) return {};
    LOCK2(::cs_main, cs_wallet);
    const ShadowPowClaimRecoveryInventory inventory =
        GetShadowPowClaimRecoveryInventoryLocked();
    return GetShadowPowClaimRecoveryUsageFromInventoryLocked(
        inventory, rolling_window_seconds);
}

ShadowPowClaimRecoveryUsage
CWallet::GetShadowPowClaimRecoveryUsageFromInventoryLocked(
    const ShadowPowClaimRecoveryInventory& inventory,
    uint32_t rolling_window_seconds) const
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(cs_wallet);
    return BuildRecoveryUsageLocked(
        *this, inventory,
        rolling_window_seconds);
}

ShadowPowClaimRecoveryReview CWallet::GetShadowPowClaimRecoveryReview(
    const ShadowPowClaimRecoveryRequest& request) const
{
    ShadowPowClaimRecoveryReview review;
    if (!HaveChain()) {
        review.reason_code = "chain-unavailable";
        review.detail = "wallet has no chain interface";
        return review;
    }

    LOCK2(::cs_main, cs_wallet);
    const ShadowPowClaimRecoveryPolicyMutationResult policy_state =
        GetShadowPowClaimRecoveryPolicyState();
    review.policy = policy_state.authoritative_state_available
        ? policy_state.authoritative_policy
        : DefaultShadowPowClaimRecoveryPolicy();

    ShadowPowClaimRecoveryRequest effective = request;
    const ShadowPowClaimRecoveryPolicy* automatic_policy{nullptr};
    if (effective.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC &&
        policy_state.authoritative_state_available) {
        effective.max_fee_per_resolution =
            review.policy.max_fee_per_resolution;
        effective.aggregate_batch_fee_cap =
            review.policy.aggregate_batch_fee_cap;
        automatic_policy = &review.policy;
    }

    review.inventory = GetShadowPowClaimRecoveryInventoryLocked();
    review.plan = BuildRecoveryPlanLocked(
        *this, effective, automatic_policy);
    review.usage = BuildRecoveryUsageLocked(
        *this, review.inventory,
        review.policy.rolling_fee_window_seconds);
    review.active_tip = review.inventory.active_tip;
    review.active_height = review.inventory.active_height;
    review.wallet_generation = review.inventory.wallet_generation;
    const std::optional<int> wallet_height = GetLastBlockHeightIfSet();
    if (wallet_height) {
        review.wallet_height = *wallet_height;
        review.wallet_tip = GetLastBlockHash();
    }

    review.consistent = policy_state.authoritative_state_available &&
        review.inventory.wallet_tip_matches &&
        !review.active_tip.IsNull() &&
        review.active_tip == review.plan.active_tip &&
        review.active_height == review.plan.active_height &&
        review.wallet_generation == review.plan.wallet_generation &&
        review.plan.wallet_tip_matches;
    if (!policy_state.authoritative_state_available) {
        review.status =
            ShadowPowClaimRecoveryReviewStatus::POLICY_UNAVAILABLE;
        review.reason_code = "policy-unavailable";
        review.detail = policy_state.detail.empty()
            ? "recovery policy authority is unavailable; reload the wallet"
            : policy_state.detail;
    } else if (review.active_tip.IsNull()) {
        review.status =
            ShadowPowClaimRecoveryReviewStatus::CHAIN_UNAVAILABLE;
        review.reason_code = "chain-unavailable";
        review.detail = "active chain tip is unavailable";
    } else if (!review.inventory.wallet_tip_matches) {
        review.status =
            ShadowPowClaimRecoveryReviewStatus::WALLET_TIP_STALE;
        review.reason_code = "wallet-tip-stale";
        review.detail =
            "wallet-processed tip does not match the active chain tip";
    } else if (!review.consistent) {
        review.status =
            ShadowPowClaimRecoveryReviewStatus::WALLET_TIP_STALE;
        review.reason_code = "snapshot-inconsistent";
        review.detail =
            "recovery inventory and plan did not bind to one snapshot";
    } else {
        review.status = ShadowPowClaimRecoveryReviewStatus::AVAILABLE;
        review.available = true;
        review.reason_code = "available";
        review.detail = "recovery review is one coherent read-only snapshot";
    }
    return review;
}

ShadowPowClaimRecoveryResult CWallet::ResolveShadowPowClaims(
    const ShadowPowClaimRecoveryRequest& request)
{
    ShadowPowClaimRecoveryResult result;
    if (!HaveChain()) {
        result.error = "wallet has no chain interface";
        return result;
    }
    if (!chain().isReadyToBroadcast()) {
        result.error = "active chain is not synchronized and ready for recovery";
        return result;
    }
    // Keep durable recovery mutations and miner consent changes in one
    // authorization order. If disable acquires this lock first, automatic
    // planning observes mining off. If an authorized recovery already holds
    // it, disable waits for that operation's definitive result.
    LOCK(m_pow_recovery_authority_mutex);
    if (request.mode != ShadowPowClaimRecoveryMode::PREVIEW) {
        if (request.origin == ShadowPowClaimRecoveryOrigin::MANUAL) {
            const bool explicit_manual =
                request.execution_authority ==
                    ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL &&
                request.acknowledge_fee_and_conflict_risk &&
                request.expected_plan_id.has_value();
            const bool persisted_retry =
                request.execution_authority ==
                    ShadowPowClaimRecoveryExecutionAuthority::PERSISTED_COMMIT &&
                request.mode ==
                    ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
            if (!explicit_manual && !persisted_retry) {
                result.error = "manual recovery mutation requires an exact preview plan and explicit fee/conflict acknowledgement";
                return result;
            }
        } else if (request.execution_authority !=
                   ShadowPowClaimRecoveryExecutionAuthority::AUTOMATIC_POLICY) {
            result.error = "automatic recovery mutation requires durable bounded policy authority";
            return result;
        }
    }
    ShadowPowClaimSubmissionGuard submission_guard(*this);
    if (!submission_guard) {
        result.error = "another Gold Rush claim or recovery action is already in progress";
        return result;
    }

    ShadowPowClaimRecoveryRequest effective = request;
    std::optional<ShadowPowClaimRecoveryPolicy> automatic_policy;
    if (request.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC) {
        automatic_policy = GetShadowPowClaimRecoveryPolicy();
        effective.max_fee_per_resolution =
            automatic_policy->max_fee_per_resolution;
        effective.aggregate_batch_fee_cap =
            automatic_policy->aggregate_batch_fee_cap;
    }

    std::vector<uint256> relay_txids;
    std::map<uint256, size_t> relay_action_indices;
    std::map<uint256, COutPoint> relay_anchors;
    std::set<uint256> relay_requires_unlock;
    uint64_t post_persist_generation{0};
    {
        LOCK2(::cs_main, cs_wallet);
        // The policy is re-read under the same wallet lock as planning so a
        // concurrent revocation can never authorize another automatic sign or
        // relay action.
        if (effective.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC) {
            automatic_policy = m_shadow_pow_claim_recovery_policy;
            effective.max_fee_per_resolution =
                automatic_policy->max_fee_per_resolution;
            effective.aggregate_batch_fee_cap =
                automatic_policy->aggregate_batch_fee_cap;
        }
        if (m_shadow_pow_claim_recovery_db_ambiguous ||
            m_locked_coins_db_ambiguous) {
            result.durable_state_ambiguous = true;
            result.error = "a prior recovery or coin-lock database commit had an ambiguous outcome; reload the wallet before any further recovery action";
            return result;
        }
        result.plan = BuildRecoveryPlanLocked(
            *this, effective,
            automatic_policy ? &*automatic_policy : nullptr);
        if (request.expected_plan_id &&
            *request.expected_plan_id != result.plan.plan_id) {
            result.stale_plan = true;
            result.error = "recovery plan is stale; preview the current tip and wallet state again";
            return result;
        }
        if (request.mode == ShadowPowClaimRecoveryMode::PREVIEW) {
            result.success = result.plan.complete;
            return result;
        }
        if (!result.plan.complete) {
            result.error = "wallet and active-chain tips are not synchronized";
            return result;
        }
        if (result.plan.actions.empty()) {
            result.success = result.plan.refused.empty();
            if (!result.success) {
                result.error = "no selected claim component is currently safe to recover";
            }
            return result;
        }
        const bool needs_signing = std::any_of(
            result.plan.actions.begin(), result.plan.actions.end(),
            [](const ShadowPowClaimRecoveryAction& action) {
                return action.status ==
                       ShadowPowClaimRecoveryActionStatus::READY;
            });
        if (needs_signing &&
            (IsLocked() || m_wallet_unlock_staking_only ||
             !HasPrivateKeys() ||
             IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS) ||
             IsWalletFlagSet(WALLET_FLAG_EXTERNAL_SIGNER))) {
            result.error = "normal local private-key wallet unlock is required to sign recovery transactions";
            return result;
        }

        const uint256 pinned_tip = result.plan.active_tip;
        const CBlockIndex* tip = chain().chainman().ActiveChain().Tip();
        if (!tip || tip->GetBlockHash() != pinned_tip ||
            m_last_block_processed != pinned_tip ||
            GetDatabase().nUpdateCounter.load() !=
                result.plan.wallet_generation) {
            result.stale_plan = true;
            result.error = "tip or wallet generation changed before recovery signing";
            return result;
        }
        const unsigned int script_verify_flags =
            GetNextBlockPolicyScriptFlags(tip, chain().chainman());

        struct Prepared {
            size_t action_index{0};
            CTransactionRef transaction;
            bool newly_signed{false};
            bool managed{false};
            bool relay_authorized{false};
        };
        std::vector<Prepared> prepared;
        prepared.reserve(result.plan.actions.size());

        const CCoinsViewCache& coins_tip =
            chain().chainman().ActiveChainstate().CoinsTip();
        const ShadowPowClaimRecoveryInventory execution_inventory =
            GetShadowPowClaimRecoveryInventoryLocked();
        for (size_t i = 0; i < result.plan.actions.size(); ++i) {
            ShadowPowClaimRecoveryAction& action = result.plan.actions[i];
            Coin anchor_coin;
            if (!coins_tip.GetCoin(action.anchor, anchor_coin) ||
                anchor_coin.IsSpent() ||
                anchor_coin.out.nValue + 0 !=
                    action.transaction->vout.front().nValue + action.fee ||
                anchor_coin.out.scriptPubKey !=
                    action.transaction->vout.front().scriptPubKey ||
                (IsMine(anchor_coin.out) & ISMINE_SPENDABLE) == ISMINE_NO) {
                result.stale_plan = true;
                result.error = "confirmed recovery anchor changed before signing";
                return result;
            }

            CTransactionRef exact = action.transaction;
            bool newly_signed = action.status ==
                                ShadowPowClaimRecoveryActionStatus::READY;
            if (newly_signed) {
                CMutableTransaction mutable_tx{*action.transaction};
                std::map<int, bilingual_str> input_errors;
                if (!SignTransactionWithScriptVerifyFlags(
                        mutable_tx, input_errors, script_verify_flags)) {
                    result.error = input_errors.empty()
                                       ? "failed to sign recovery transaction"
                                       : "failed to sign recovery transaction: " +
                                             input_errors.begin()->second.original;
                    return result;
                }
                exact = MakeTransactionRef(std::move(mutable_tx));
                action.transaction = exact;
                action.vsize = GetVirtualTransactionSize(*exact);
            }

            const ShadowPowClaimRecoveryNode* existing_node = nullptr;
            if (action.persisted) {
                const auto component_it = std::find_if(
                    execution_inventory.components.begin(),
                    execution_inventory.components.end(),
                    [&](const ShadowPowClaimRecoveryComponent& component) {
                        return component.anchor == action.anchor;
                    });
                if (component_it != execution_inventory.components.end()) {
                    existing_node = FindNode(*component_it,
                                             exact->GetHash());
                }
            }
            const bool managed = newly_signed ||
                (existing_node && existing_node->kind ==
                    ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION);
            bool relay_authorized = managed && existing_node &&
                                     existing_node->resolution_relay_authorized;

            if (request.execution_authority ==
                    ShadowPowClaimRecoveryExecutionAuthority::PERSISTED_COMMIT &&
                (newly_signed || !managed || !relay_authorized ||
                 !existing_node ||
                 existing_node->resolution_origin !=
                     SHADOW_POW_RESOLUTION_ORIGIN_MANUAL)) {
                result.error = "persisted-commit retry authority applies only to exact manual-origin managed bytes with durable relay consent";
                return result;
            }

            if (!action.in_mempool) {
                const MempoolAcceptResult accept =
                    chain().chainman().ProcessTransaction(
                        exact, /*test_accept=*/true);
                if (accept.m_result_type !=
                    MempoolAcceptResult::ResultType::VALID) {
                    result.error = "resolution transaction is not acceptable on the pinned tip: " +
                                   accept.m_state.ToString();
                    return result;
                }
            }
            prepared.push_back(
                {i, exact, newly_signed, managed, relay_authorized});
        }

        const bool commit_authority =
            request.mode ==
            ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
        int64_t created_time = std::max<int64_t>(1, GetTime());
        if (effective.origin == ShadowPowClaimRecoveryOrigin::AUTOMATIC) {
            // Automatic spending authority is anchored to chain MTP, not the
            // host wall clock. A forward or backward host-clock correction
            // therefore cannot expire the rolling action/fee window.
            created_time = std::max<int64_t>(1, tip->GetMedianTimePast());
        }
        for (Prepared& item : prepared) {
            ShadowPowClaimRecoveryAction& action =
                result.plan.actions[item.action_index];
            if (item.newly_signed) {
                if (!PersistNewManagedShadowPowResolution(
                        action, effective.origin, commit_authority,
                        result.plan.active_height, created_time,
                        result.error)) {
                    // A failed or ambiguous durable commit never authorizes
                    // relay. Reload/retry will discover and reuse exact bytes
                    // if the database committed despite the error.
                    result.durable_state_ambiguous =
                        m_shadow_pow_claim_recovery_db_ambiguous;
                    return result;
                }
                action.persisted = true;
                action.relay_authorized = commit_authority;
                action.relay_revoked = false;
                action.status = ShadowPowClaimRecoveryActionStatus::SIGNED_AND_PERSISTED;
                ++result.signed_and_persisted;
                result.durable_state_changed = true;
                if (commit_authority) {
                    ++result.relay_authority_granted;
                }
                item.relay_authorized = commit_authority;
            } else if (commit_authority && item.managed &&
                       !item.relay_authorized) {
                // Promoting a SIGN_ONLY draft is a new spending consent and
                // therefore still requires normal wallet unlock. A later
                // retry of the already-authorized exact bytes does not.
                if (IsLocked() || m_wallet_unlock_staking_only ||
                    !HasPrivateKeys() ||
                    IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS) ||
                    IsWalletFlagSet(WALLET_FLAG_EXTERNAL_SIGNER)) {
                    result.error = "normal local private-key wallet unlock is required to authorize a signed recovery draft for relay";
                    return result;
                }
                if (!SetManagedShadowPowResolutionRelayAuthority(
                        item.transaction->GetHash(), true,
                        /*explicit_reauthorization=*/true,
                        result.error)) {
                    result.durable_state_ambiguous =
                        m_shadow_pow_claim_recovery_db_ambiguous;
                    return result;
                }
                relay_requires_unlock.insert(
                    item.transaction->GetHash());
                item.relay_authorized = true;
                action.relay_authorized = true;
                action.relay_revoked = false;
                result.durable_state_changed = true;
                ++result.relay_authority_granted;
            }

            if (commit_authority) {
                // A legacy transaction has no standing/scheduler authority,
                // but this explicit manual call may relay its exact bytes.
                if (!item.managed && effective.origin !=
                                         ShadowPowClaimRecoveryOrigin::MANUAL) {
                    result.error = "legacy resolution relay requires manual authority";
                    return result;
                }
                relay_txids.push_back(item.transaction->GetHash());
                relay_action_indices.emplace(
                    item.transaction->GetHash(), item.action_index);
                relay_anchors.emplace(
                    item.transaction->GetHash(), action.anchor);
                if (item.newly_signed || !item.managed ||
                    !item.relay_authorized) {
                    relay_requires_unlock.insert(
                        item.transaction->GetHash());
                }
            }
        }
        post_persist_generation = GetDatabase().nUpdateCounter.load();
    }

    // No outer cs_wallet is held while validation or networking runs. Each
    // relay takes cs_main, briefly checks the exact durable record and policy,
    // releases cs_wallet, then broadcasts while the active tip remains pinned.
    for (size_t relay_index = 0; relay_index < relay_txids.size();
         ++relay_index) {
        const uint256& txid = relay_txids[relay_index];
        LOCK(::cs_main);
        const CBlockIndex* tip = chain().chainman().ActiveChain().Tip();
        if (!tip || tip->GetBlockHash() != result.plan.active_tip) {
            result.stale_plan = true;
            result.error = "active tip changed after persistence; signed bytes remain safely stored";
            return result;
        }
        bool already_in_mempool{false};
        {
            LOCK(cs_wallet);
            const auto anchor_it = relay_anchors.find(txid);
            if (anchor_it == relay_anchors.end()) {
                result.error = "recovery relay lost its exact anchor binding";
                return result;
            }
            if (m_shadow_pow_claim_recovery_db_ambiguous ||
                m_locked_coins_db_ambiguous) {
                result.durable_state_ambiguous = true;
                result.error = "recovery or coin-lock database outcome became ambiguous before relay; reload the wallet";
                return result;
            }
            if (IsLockedCoin(anchor_it->second)) {
                result.error = "recovery anchor was user-locked before relay; exact authorized bytes remain persisted";
                return result;
            }
            if (m_last_block_processed != result.plan.active_tip ||
                GetDatabase().nUpdateCounter.load() !=
                    post_persist_generation) {
                result.stale_plan = true;
                result.error = "wallet generation changed after persistence; signed bytes remain safely stored";
                return result;
            }
            const auto it = mapWallet.find(txid);
            if (it == mapWallet.end() || !it->second.tx) {
                result.error = "durably persisted resolution is missing from memory";
                return result;
            }
            const bool managed = it->second.mapValue.count(
                                     SHADOW_POW_RESOLUTION_SCHEMA_KEY) != 0;
            ManagedResolutionFacts managed_facts;
            if (managed && !ParseManagedResolutionFacts(
                               *this, it->second, managed_facts)) {
                result.error = "managed resolution metadata changed before relay";
                return result;
            }
            const bool relay_authorized =
                managed && managed_facts.relay_authorized;
            if (managed && managed_facts.relay_revoked) {
                result.error = "local relay authority for the signed recovery was revoked before relay";
                return result;
            }
            if (managed && !relay_authorized) {
                result.error = "signed recovery draft has no durable relay authority";
                return result;
            }
            if (effective.origin ==
                ShadowPowClaimRecoveryOrigin::AUTOMATIC) {
                if (!automatic_policy ||
                    !(m_shadow_pow_claim_recovery_policy == *automatic_policy) ||
                    !m_shadow_pow_claim_recovery_policy.HasAutomaticAuthority() ||
                    !ValidateShadowPowClaimRecoveryPolicy(
                        m_shadow_pow_claim_recovery_policy) ||
                    !m_pow_mining_enabled.load()) {
                    result.error = "automatic recovery authority was revoked before relay";
                    return result;
                }
            }
            if (relay_requires_unlock.count(txid) != 0 &&
                (IsLocked() || m_wallet_unlock_staking_only ||
                 !HasPrivateKeys() ||
                 IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS) ||
                 IsWalletFlagSet(WALLET_FLAG_EXTERNAL_SIGNER))) {
                result.error = "normal local private-key wallet unlock ended before relay; exact authorized bytes remain persisted";
                return result;
            }
            already_in_mempool = it->second.InMempool();
        }
        if (already_in_mempool) {
            result.plan.actions.at(relay_action_indices.at(txid)).status =
                ShadowPowClaimRecoveryActionStatus::ALREADY_IN_MEMPOOL;
            result.plan.actions.at(relay_action_indices.at(txid)).in_mempool =
                true;
            ++result.already_in_mempool;
            continue;
        }
        std::string relay_error;
        ShadowPowClaimRecoveryBroadcastGuard broadcast_guard;
        broadcast_guard.expected_wallet_generation =
            post_persist_generation;
        broadcast_guard.expected_wallet_tip = result.plan.active_tip;
        broadcast_guard.expected_unlocked_input =
            relay_anchors.at(txid);
        broadcast_guard.require_normal_unlock =
            relay_requires_unlock.count(txid) != 0;
        if (effective.origin ==
            ShadowPowClaimRecoveryOrigin::AUTOMATIC) {
            broadcast_guard.expected_automatic_policy = automatic_policy;
            broadcast_guard.require_pow_mining_enabled = true;
        }
        if (!SubmitTxMemoryPoolAndRelay(
                txid, relay_error, /*relay=*/true, &broadcast_guard)) {
            result.error = "signed resolution was retained but relay failed: " +
                           relay_error;
            return result;
        }
        ++result.broadcast;
        result.plan.actions.at(relay_action_indices.at(txid)).status =
            ShadowPowClaimRecoveryActionStatus::BROADCAST;
        result.plan.actions.at(relay_action_indices.at(txid)).in_mempool = true;
        // A successful relay can synchronously mutate wallet/mempool state.
        // Do not infer that every resulting DB-generation change was ours.
        // Leave the rest durably commit-authorized for a fresh, fully pinned
        // scheduler pass instead of silently rebasing the generation gate.
        result.relay_deferred = relay_txids.size() - relay_index - 1;
        for (size_t deferred_index = relay_index + 1;
             deferred_index < relay_txids.size(); ++deferred_index) {
            result.plan.actions.at(
                relay_action_indices.at(relay_txids.at(deferred_index))).status =
                ShadowPowClaimRecoveryActionStatus::RELAY_DEFERRED;
        }
        break;
    }

    result.success = true;
    return result;
}

ShadowPowClaimRecoveryAdoptionResult
CWallet::AdoptShadowPowClaimRecoveryComponent(
    const uint256& selector, const uint256& expected_tip,
    const uint256& expected_component_fingerprint)
{
    ShadowPowClaimRecoveryAdoptionResult result;
    result.reviewed_component_fingerprint =
        expected_component_fingerprint;
    const auto fail = [&](ShadowPowClaimRecoveryAdoptionStatus status,
                          std::string detail) {
        result.status = status;
        result.detail = std::move(detail);
        return result;
    };

    if (!HaveChain()) {
        return fail(ShadowPowClaimRecoveryAdoptionStatus::NO_CHAIN,
                    "wallet has no active chain interface");
    }
    LOCK2(::cs_main, cs_wallet);
    if (m_shadow_pow_claim_recovery_db_ambiguous) {
        result.durable_state_ambiguous = true;
        return fail(
            ShadowPowClaimRecoveryAdoptionStatus::DATABASE_OUTCOME_AMBIGUOUS,
            "a prior recovery database commit had an ambiguous outcome; reload the wallet before adoption");
    }
    if (IsLocked() || m_wallet_unlock_staking_only || !HasPrivateKeys() ||
        IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS) ||
        IsWalletFlagSet(WALLET_FLAG_EXTERNAL_SIGNER)) {
        return fail(
            ShadowPowClaimRecoveryAdoptionStatus::SIGNING_UNAVAILABLE,
            "normal local private-key wallet unlock is required before adopting historical claims");
    }

    const ShadowPowClaimRecoveryInventory inventory =
        GetShadowPowClaimRecoveryInventoryLocked();
    result.active_tip = inventory.active_tip;
    if (!inventory.wallet_tip_matches || inventory.active_tip != expected_tip) {
        return fail(
            ShadowPowClaimRecoveryAdoptionStatus::STALE_TIP,
            "active or wallet-processed tip changed; review the component again");
    }

    std::vector<const ShadowPowClaimRecoveryComponent*> matches;
    bool selector_seen_as_non_claim{false};
    for (const ShadowPowClaimRecoveryComponent& component :
         inventory.components) {
        const auto node = std::find_if(
            component.nodes.begin(), component.nodes.end(),
            [&](const ShadowPowClaimRecoveryNode& candidate) {
                return candidate.txid == selector;
            });
        if (node == component.nodes.end()) continue;
        if (node->kind != ShadowPowClaimRecoveryNodeKind::CLAIM) {
            selector_seen_as_non_claim = true;
            continue;
        }
        matches.push_back(&component);
    }
    if (matches.empty()) {
        return fail(
            selector_seen_as_non_claim
                ? ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_NOT_CLAIM
                : ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_NOT_FOUND,
            selector_seen_as_non_claim
                ? "selector identifies a non-claim node in the recovery graph"
                : "selector is not a claim in the current wallet recovery graph");
    }
    if (matches.size() != 1) {
        return fail(
            ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_AMBIGUOUS,
            "selector appears in more than one recovery component; adoption fails closed");
    }

    const ShadowPowClaimRecoveryComponent& component = *matches.front();
    result.generation_fingerprint = component.generation_fingerprint;
    result.claim_txids = component.claim_txids;
    result.component_has_revalidating_unbound_proof =
        component.has_revalidating_unbound_proof;
    if (component.fingerprint != expected_component_fingerprint) {
        return fail(
            ShadowPowClaimRecoveryAdoptionStatus::STALE_COMPONENT_FINGERPRINT,
            "recovery component fingerprint changed; review it again");
    }
    std::string refusal_code;
    std::string refusal;
    if (!SafeGraphForAdoption(component, refusal_code, refusal)) {
        result.component_refusal_code = std::move(refusal_code);
        return fail(
            ShadowPowClaimRecoveryAdoptionStatus::UNSAFE_GRAPH,
            "component cannot be adopted: " + refusal);
    }
    if (component.all_claims_explicitly_provenanced) {
        result.status =
            ShadowPowClaimRecoveryAdoptionStatus::ALREADY_EXPLICIT;
        result.post_adoption_component_fingerprint = component.fingerprint;
        result.automatic_eligible_after_adoption = true;
        result.detail =
            "every component claim already has explicit authored or adopted provenance";
        return result;
    }

    struct AdoptionUpdate {
        uint256 txid;
        mapValue_t metadata;
    };
    std::vector<AdoptionUpdate> updates;
    updates.reserve(component.claim_txids.size());
    WalletBatch batch(GetDatabase());
    if (!batch.TxnBegin(/*durable=*/true)) {
        return fail(
            ShadowPowClaimRecoveryAdoptionStatus::DATABASE_FAILURE,
            "failed to begin durable claim-component adoption");
    }
    for (const uint256& txid : component.claim_txids) {
        const auto it = mapWallet.find(txid);
        if (it == mapWallet.end() || !it->second.tx) {
            if (!batch.TxnAbort()) {
                MarkShadowPowClaimRecoveryDatabaseAmbiguous();
                result.durable_state_ambiguous = true;
                return fail(
                    ShadowPowClaimRecoveryAdoptionStatus::DATABASE_OUTCOME_AMBIGUOUS,
                    "claim adoption rollback outcome is ambiguous; reload the wallet");
            }
            return fail(
                ShadowPowClaimRecoveryAdoptionStatus::DATABASE_FAILURE,
                "a claim disappeared while its component was being adopted");
        }
        CWalletTx persisted(it->second.tx, it->second.m_state);
        persisted.CopyFrom(it->second);
        persisted.mapValue[SHADOW_POW_CLAIM_ADOPTED_KEY] = "1";
        persisted.mapValue[SHADOW_POW_CLAIM_ADOPTION_TIP_KEY] =
            expected_tip.GetHex();
        persisted.mapValue[SHADOW_POW_CLAIM_ADOPTION_FINGERPRINT_KEY] =
            component.generation_fingerprint.GetHex();
        if (!batch.WriteTx(persisted)) {
            if (!batch.TxnAbort()) {
                MarkShadowPowClaimRecoveryDatabaseAmbiguous();
                result.durable_state_ambiguous = true;
                return fail(
                    ShadowPowClaimRecoveryAdoptionStatus::DATABASE_OUTCOME_AMBIGUOUS,
                    "claim adoption write and rollback outcomes are ambiguous; reload the wallet");
            }
            return fail(
                ShadowPowClaimRecoveryAdoptionStatus::DATABASE_FAILURE,
                "failed to persist complete claim-component adoption");
        }
        updates.push_back({txid, std::move(persisted.mapValue)});
    }
    if (!batch.TxnCommit()) {
        batch.TxnAbort();
        MarkShadowPowClaimRecoveryDatabaseAmbiguous();
        result.durable_state_ambiguous = true;
        return fail(
            ShadowPowClaimRecoveryAdoptionStatus::DATABASE_OUTCOME_AMBIGUOUS,
            "claim-component adoption commit outcome is ambiguous; reload the wallet before retrying");
    }

    // Publish all metadata to memory only after the one durable batch commits.
    for (AdoptionUpdate& update : updates) {
        CWalletTx& wtx = mapWallet.at(update.txid);
        wtx.mapValue = std::move(update.metadata);
        wtx.MarkDirty();
        NotifyTransactionChanged(update.txid, CT_UPDATED);
    }
    result.durable_state_changed = true;
    result.adopted = true;
    result.status = ShadowPowClaimRecoveryAdoptionStatus::SUCCESS;
    result.detail = "complete claim component was durably adopted";

    // Report the post-commit fingerprint from the same chain/wallet lock and
    // durable in-memory publication. Adapters must never perform a racy second
    // inventory lookup merely to describe this successful mutation.
    const ShadowPowClaimRecoveryInventory post =
        GetShadowPowClaimRecoveryInventoryLocked();
    const auto post_component = std::find_if(
        post.components.begin(), post.components.end(),
        [&](const ShadowPowClaimRecoveryComponent& candidate) {
            return candidate.generation_fingerprint ==
                   result.generation_fingerprint;
        });
    if (post_component != post.components.end()) {
        result.post_adoption_component_fingerprint =
            post_component->fingerprint;
        result.automatic_eligible_after_adoption =
            post_component->all_claims_explicitly_provenanced;
    }
    return result;
}

void CWallet::MaybeAutoResolveShadowPowClaims()
{
    // A prior explicit COMMIT is durable standing authority to retry those
    // exact bytes even while the wallet is locked and independently of the
    // optional automatic-creation policy. It never authorizes a new spend or
    // promotes a SIGN_ONLY draft.
    ShadowPowClaimRecoveryRequest manual_retry;
    manual_retry.mode =
        ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
    manual_retry.origin = ShadowPowClaimRecoveryOrigin::MANUAL;
    manual_retry.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::PERSISTED_COMMIT;
    // The exact bytes already carry durable per-transaction consent. Do not
    // strand a previously authorized manual resolution merely because the
    // scheduler request object's preview defaults are lower than the fee the
    // operator reviewed. Creation still could never exceed the wallet max.
    manual_retry.max_fee_per_resolution = m_default_max_tx_fee;
    manual_retry.aggregate_batch_fee_cap = MAX_MONEY;
    if (HaveChain() && chain().isReadyToBroadcast()) {
        const ShadowPowClaimRecoveryInventory inventory =
            GetShadowPowClaimRecoveryInventory();
        for (const ShadowPowClaimRecoveryComponent& component :
             inventory.components) {
            for (const ShadowPowClaimRecoveryNode& node : component.nodes) {
                if (node.kind ==
                        ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION &&
                    node.resolution_metadata_valid &&
                    node.resolution_origin ==
                        SHADOW_POW_RESOLUTION_ORIGIN_MANUAL &&
                    node.resolution_relay_authorized &&
                    !node.resolution_relay_revoked &&
                    !node.active_chain_confirmed && !node.in_mempool) {
                    manual_retry.selectors.push_back(node.txid);
                }
            }
        }
    }
    if (!manual_retry.selectors.empty()) {
        const ShadowPowClaimRecoveryResult retry =
            ResolveShadowPowClaims(manual_retry);
        if (!retry.success) {
            WalletLogPrintf("Commit-authorized manual Gold Rush recovery retry paused: %s\n",
                            retry.error);
        }
    }

    const ShadowPowClaimRecoveryPolicy policy =
        GetShadowPowClaimRecoveryPolicy();
    if (!policy.HasAutomaticAuthority() ||
        !ValidateShadowPowClaimRecoveryPolicy(policy) ||
        !m_pow_mining_enabled.load()) {
        return;
    }
    ShadowPowClaimRecoveryRequest request;
    request.mode = ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
    request.origin = ShadowPowClaimRecoveryOrigin::AUTOMATIC;
    request.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::AUTOMATIC_POLICY;
    request.max_fee_per_resolution = policy.max_fee_per_resolution;
    request.aggregate_batch_fee_cap = policy.aggregate_batch_fee_cap;
    const ShadowPowClaimRecoveryResult result = ResolveShadowPowClaims(request);
    if (!result.success || !result.plan.refused.empty()) {
        const std::string reason = !result.error.empty()
            ? result.error
            : (!result.plan.refused.empty()
                   ? result.plan.refused.front().reason_code + ": " +
                         result.plan.refused.front().detail
                   : "no actionable component");
        WalletLogPrintf("Automatic Gold Rush PoW claim recovery paused: %s\n",
                        reason);
    } else if (result.broadcast != 0 || result.already_in_mempool != 0) {
        WalletLogPrintf("Automatic Gold Rush PoW claim recovery relayed %u exact persisted transaction(s); %u already in mempool; miner enablement unchanged\n",
                        result.broadcast, result.already_in_mempool);
    }
}

} // namespace wallet
