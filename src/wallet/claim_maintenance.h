// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_CLAIM_MAINTENANCE_H
#define BITCOIN_WALLET_CLAIM_MAINTENANCE_H

#include <chrono>
#include <functional>
#include <memory>

namespace wallet {
class CWallet;
struct WalletClaimMaintenanceSlot;

/** Opaque executor API shared by wallet state and wallet loading. The loader
 * implements and owns its lifecycle without exposing loader dependencies. */
class WalletClaimMaintenance {
    struct State;
    std::shared_ptr<State> m_state;
    explicit WalletClaimMaintenance(std::function<void(CWallet&, bool, bool)> test_pass);
    bool WaitForCancellationForTesting(
        const std::shared_ptr<WalletClaimMaintenanceSlot>& slot,
        std::chrono::milliseconds timeout);
    friend struct WalletLoadTestAccess;
    friend struct WalletClaimMaintenanceSlot;
public:
    WalletClaimMaintenance();
    ~WalletClaimMaintenance();
    WalletClaimMaintenance(const WalletClaimMaintenance&) = delete;
    WalletClaimMaintenance& operator=(const WalletClaimMaintenance&) = delete;
    void Start();
    void Register(const std::shared_ptr<CWallet>& wallet);
    void Unregister(CWallet& wallet);
    void Stop();
    /** Deterministic barrier for callers outside wallet/chain locks. */
    void Sync();
};

/** Coalesce requests without queue allocation or retained wallet ownership. */
void RequestWalletClaimMaintenance(
    const std::shared_ptr<WalletClaimMaintenanceSlot>& slot,
    bool resolve, bool relay);
} // namespace wallet

#endif // BITCOIN_WALLET_CLAIM_MAINTENANCE_H
