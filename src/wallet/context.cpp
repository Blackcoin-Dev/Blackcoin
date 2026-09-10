// Copyright (c) 2020-2022 The Bitcoin Core developers
// Copyright (c) 2020-2022 Blackcoin Core Developers
// Copyright (c) 2020-2022 Blackcoin More Developers
// Copyright (c) 2020-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/context.h>
#include <wallet/load.h>

namespace wallet {
WalletContext::WalletContext() : claim_maintenance(std::make_unique<WalletClaimMaintenance>()) {}
WalletContext::~WalletContext()
{
    // Join before destroying the context's wallet references or chain users.
    claim_maintenance->Stop();
}
} // namespace wallet
