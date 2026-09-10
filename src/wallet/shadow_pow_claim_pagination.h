// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SHADOW_POW_CLAIM_PAGINATION_H
#define BITCOIN_WALLET_SHADOW_POW_CLAIM_PAGINATION_H

#include <hash.h>
#include <util/strencodings.h>
#include <wallet/shadow_pow_claim_recovery_types.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace wallet {

inline constexpr size_t MAX_SHADOW_POW_RECOVERY_PAGE_SIZE{1000};

enum class ShadowPowRecoveryPageRecordKind : uint8_t {
    COMPONENT,
    NODE,
    CLAIM_TXID,
    ROOT_CLAIM_TXID,
    RESOLUTION_TXID,
    ORDINARY_OR_MIXED_TXID,
    UNANCHORED_CLAIM_TXID,
};

/** Non-owning views: the authoritative inventory must outlive this page. */
struct ShadowPowRecoveryPageRecord {
    ShadowPowRecoveryPageRecordKind kind;
    const ShadowPowClaimRecoveryComponent* component{nullptr};
    const ShadowPowClaimRecoveryNode* node{nullptr};
    uint256 txid;
};

struct ShadowPowRecoveryPage {
    uint256 snapshot;
    size_t offset{0};
    size_t total_records{0};
    std::vector<ShadowPowRecoveryPageRecord> records;
    std::string next_cursor;
    std::string error;
};

/** Pagination is read-only presentation, never spending authority. Index only
 * lightweight references to the complete bounded Core inventory; copy neither
 * scripts nor graph payloads. Every nested collection is flattened so even a
 * single large component cannot bypass the caller's response-record bound.
 * Cursors have no server-side state and expire on wallet/tip/classifier drift.
 */
inline ShadowPowRecoveryPage BuildShadowPowRecoveryPage(
    const ShadowPowClaimRecoveryInventory& inventory,
    const std::string& wallet_scope, size_t page_size,
    const std::string& cursor = {})
{
    ShadowPowRecoveryPage page;
    if (page_size == 0 || page_size > MAX_SHADOW_POW_RECOVERY_PAGE_SIZE) {
        page.error = "recovery-page-size-out-of-range";
        return page;
    }
    std::string cursor_snapshot;
    if (!cursor.empty()) {
        // v1:<64 lowercase hex characters>:<canonical unsigned offset>
        if (cursor.size() < 69 || cursor.size() > 88 ||
            cursor.compare(0, 3, "v1:") != 0 || cursor[67] != ':') {
            page.error = "recovery-page-cursor-malformed";
            return page;
        }
        cursor_snapshot = cursor.substr(3, 64);
        const std::string offset_text = cursor.substr(68);
        const auto offset = ToIntegral<size_t>(offset_text);
        if (!IsHex(cursor_snapshot) || !offset ||
            std::to_string(*offset) != offset_text ||
            std::any_of(cursor_snapshot.begin(), cursor_snapshot.end(),
                        [](char c) { return c >= 'A' && c <= 'F'; })) {
            page.error = "recovery-page-cursor-malformed";
            return page;
        }
        page.offset = *offset;
    }

    std::vector<ShadowPowRecoveryPageRecord> index;
    using Kind = ShadowPowRecoveryPageRecordKind;
    for (const auto& component : inventory.components) {
        index.push_back({Kind::COMPONENT, &component, nullptr, {}});
        for (const auto& node : component.nodes) {
            index.push_back({Kind::NODE, &component, &node, node.txid});
        }
        const auto add = [&](Kind kind, const std::vector<uint256>& txids) {
            for (const auto& txid : txids) {
                index.push_back({kind, &component, nullptr, txid});
            }
        };
        add(Kind::CLAIM_TXID, component.claim_txids);
        add(Kind::ROOT_CLAIM_TXID, component.root_claim_txids);
        add(Kind::RESOLUTION_TXID, component.resolution_txids);
        add(Kind::ORDINARY_OR_MIXED_TXID, component.ordinary_or_mixed_txids);
    }
    for (const auto& txid : inventory.unanchored_claim_txids) {
        index.push_back({Kind::UNANCHORED_CLAIM_TXID, nullptr, nullptr, txid});
    }
    std::sort(index.begin(), index.end(), [](const auto& a, const auto& b) {
        if (bool(a.component) != bool(b.component)) return bool(a.component);
        if (a.component && a.component->anchor != b.component->anchor) {
            return a.component->anchor < b.component->anchor;
        }
        if (a.kind != b.kind) return a.kind < b.kind;
        return a.txid < b.txid;
    });

    HashWriter hasher;
    hasher << std::string{"shadow-pow-recovery-page-v1"} << wallet_scope;
    hasher << inventory.active_tip << inventory.active_height;
    hasher << inventory.wallet_processed_tip << inventory.wallet_processed_height;
    hasher << inventory.wallet_generation << inventory.candidate_state_fingerprint;
    hasher << inventory.classification_time << inventory.relay_clock_high_water;
    hasher << inventory.legacy_relay_clock_high_water;
    hasher << inventory.recovery_database_ambiguous;
    for (const auto& record : index) {
        hasher << static_cast<uint8_t>(record.kind) << record.txid;
        if (record.kind == Kind::COMPONENT) {
            hasher << record.component->anchor << record.component->fingerprint;
        } else if (record.node) {
            // These displayed evaluator/clock facts supplement the Core
            // component fingerprint, including incremental cold evaluation.
            const auto& node = *record.node;
            hasher << static_cast<uint8_t>(node.proof_validation_result);
            hasher << node.proof_reject_reason << node.relay_time_invalid;
            hasher << node.relay_clock_metadata_present << node.relay_clock_metadata_valid;
            hasher << node.relay_birth_time;
        }
    }
    page.snapshot = hasher.GetHash();
    page.total_records = index.size();
    if (!cursor.empty() && cursor_snapshot != page.snapshot.GetHex()) {
        page.error = "recovery-page-cursor-stale";
        return page;
    }
    if (!cursor.empty() && page.offset >= index.size()) {
        page.error = "recovery-page-cursor-out-of-range";
        return page;
    }
    const size_t count = std::min(page_size, index.size() - page.offset);
    page.records.assign(index.begin() + page.offset,
                        index.begin() + page.offset + count);
    if (page.offset + count < index.size()) {
        page.next_cursor = "v1:" + page.snapshot.GetHex() + ":" +
                           std::to_string(page.offset + count);
    }
    return page;
}

} // namespace wallet

#endif // BITCOIN_WALLET_SHADOW_POW_CLAIM_PAGINATION_H
