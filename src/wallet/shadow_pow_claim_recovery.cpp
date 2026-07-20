// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/shadow_pow_claim_recovery.h>

#include <chain.h>
#include <chainparams.h>
#include <coins.h>
#include <hash.h>
#include <shadow.h>
#include <util/strencodings.h>
#include <validation.h>
#include <wallet/wallet.h>

#include <algorithm>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace wallet {
namespace {

bool MetadataFlag(const mapValue_t& values, const char* key)
{
    const auto it = values.find(key);
    return it != values.end() && it->second == "1";
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
    hasher << component.all_claims_quarantined;
    hasher << component.all_claims_explicitly_provenanced;
    hasher << component.has_live_claim;
    hasher << component.has_transient_claim;
    hasher << component.has_indeterminate_node;
    hasher << component.has_managed_resolution;
    hasher << component.has_legacy_resolution;
    hasher << component.has_live_resolution;
    hasher << component.all_claims_terminal_on_pinned_tip;
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
        hasher << node.active_chain_confirmed;
        hasher << node.in_mempool;
        hasher << node.quarantined;
        hasher << node.expected_shape;
        hasher << node.wallet_authored;
        hasher << node.created_height;
        hasher << node.created_tip;
        hasher << node.authored_metadata_valid;
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
    }
    return hasher.GetHash();
}

uint256 FingerprintClaimGeneration(
    const ShadowPowClaimRecoveryComponent& component)
{
    if (!component.anchor_authenticated || component.anchor.IsNull()) {
        return {};
    }

    HashWriter hasher{};
    hasher << uint8_t{1};
    hasher << component.anchor;
    hasher << component.anchor_amount;
    hasher << component.anchor_script;
    return hasher.GetHash();
}

} // namespace

ShadowPowClaimRecoveryInventory CWallet::GetShadowPowClaimRecoveryInventory() const
{
    if (!HaveChain() || !chain().isReadyToBroadcast()) {
        ShadowPowClaimRecoveryInventory inventory;
        LOCK(cs_wallet);
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

            if (TransactionHasShadowProof(tx)) {
                node.kind = ShadowPowClaimRecoveryNodeKind::CLAIM;
                node.provenance = ClaimProvenance(
                    wtx, node, &component.generation_fingerprint);
                node.wallet_authored = GetDebit(tx, ISMINE_SPENDABLE) > 0;
                node.quarantined = MetadataFlag(
                    wtx.mapValue, SHADOW_POW_QUARANTINE_MARKER_KEY);
                node.expected_shape = tx.vin.size() == 1 &&
                                      !tx.vin.front().prevout.IsNull() &&
                                      !tx.IsCoinBase() && !tx.IsCoinStake();

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

                std::string reject_reason;
                const bool gold_rush_active = IsShadowGoldRushRewardActive(
                    Params().GetConsensus(), tip->GetMedianTimePast(),
                    tip->nHeight + 1);
                CheckShadowPowClaimForMempoolDetailed(
                    tx, tip, coins_tip, gold_rush_active, reject_reason,
                    &node.disposition);
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

                if (node.in_mempool ||
                    node.disposition == ShadowPowClaimMempoolDisposition::ELIGIBLE) {
                    component.has_live_claim = true;
                } else if (IsShadowPowClaimMempoolRetryable(node.disposition)) {
                    component.has_transient_claim = true;
                } else if (!typed_terminal) {
                    component.has_indeterminate_node = true;
                }
                if (node.disposition ==
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
                bool managed_resolution{false};
                uint256 metadata_anchor_hash;
                uint32_t metadata_anchor_vout{0};
                uint256 metadata_fingerprint;
                int metadata_created_height{-1};
                int64_t metadata_created_time{0};
                const auto schema = wtx.mapValue.find(
                    SHADOW_POW_RESOLUTION_SCHEMA_KEY);
                const auto origin = wtx.mapValue.find(
                    SHADOW_POW_RESOLUTION_ORIGIN_KEY);
                if (schema != wtx.mapValue.end() &&
                    schema->second == SHADOW_POW_RESOLUTION_SCHEMA_VERSION &&
                    origin != wtx.mapValue.end() &&
                    (origin->second == SHADOW_POW_RESOLUTION_ORIGIN_MANUAL ||
                     origin->second == SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC) &&
                    ParseMetadataHash(
                        wtx.mapValue,
                        SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY,
                        metadata_anchor_hash) &&
                    ParseMetadataVout(
                        wtx.mapValue,
                        SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY,
                        metadata_anchor_vout) &&
                    ParseMetadataHash(
                        wtx.mapValue,
                        SHADOW_POW_RESOLUTION_FINGERPRINT_KEY,
                        metadata_fingerprint) &&
                    ParseMetadataHeight(
                        wtx.mapValue,
                        SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY,
                        metadata_created_height) &&
                    ParsePositiveMetadataTime(
                        wtx.mapValue,
                        SHADOW_POW_RESOLUTION_CREATED_TIME_KEY,
                        metadata_created_time) &&
                    COutPoint{metadata_anchor_hash, metadata_anchor_vout} == anchor &&
                    metadata_fingerprint == component.generation_fingerprint) {
                    managed_resolution = true;
                }
                uint256 legacy_claim_txid;
                const bool legacy_marker = ParseMetadataHash(
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
                    node.resolution_generation_fingerprint = metadata_fingerprint;
                    node.resolution_origin = origin->second;
                    node.resolution_created_height = metadata_created_height;
                    node.resolution_created_time = metadata_created_time;
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
        } else if (component.all_claims_terminal_on_pinned_tip) {
            component.state = component.has_branch_relative_ineligibility
                                  ? ShadowPowClaimRecoveryState::CURRENT_BRANCH_INELIGIBLE
                                  : ShadowPowClaimRecoveryState::TERMINAL_ON_PINNED_TIP;
            ++inventory.blocking_components;
        } else {
            component.state = ShadowPowClaimRecoveryState::CURRENT_BRANCH_INELIGIBLE;
            ++inventory.blocking_components;
        }

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

            if (TransactionHasShadowProof(*wtx.tx)) {
                node.kind = ShadowPowClaimRecoveryNodeKind::CLAIM;
                node.provenance = ClaimProvenance(wtx, node);
                node.quarantined = MetadataFlag(
                    wtx.mapValue, SHADOW_POW_QUARANTINE_MARKER_KEY);
                node.wallet_authored =
                    GetDebit(*wtx.tx, ISMINE_SPENDABLE) > 0;
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

} // namespace wallet
