// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2022 The Bitcoin Core developers
// Copyright (c) 2009-2022 Blackcoin Core Developers
// Copyright (c) 2009-2022 Blackcoin More Developers
// Copyright (c) 2009-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/load.h>

#include <common/args.h>
#include <interfaces/chain.h>
#include <kernel/cs_main.h>
#include <scheduler.h>
#include <util/check.h>
#include <util/fs.h>
#include <util/string.h>
#include <util/thread.h>
#include <util/translation.h>
#include <wallet/context.h>
#include <wallet/spend.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>

#include <univalue.h>

#include <algorithm>
#include <condition_variable>
#include <list>
#include <mutex>
#include <system_error>
#include <thread>

namespace wallet {

struct WalletClaimMaintenanceSlot {
    std::weak_ptr<WalletClaimMaintenance::State> state;
    std::weak_ptr<CWallet> wallet;
    bool pending{true};
    bool resolve{false};
    bool relay{false};
    bool active{false};
    bool cancelled{false};
};

struct WalletClaimMaintenance::State {
    std::mutex mutex;
    std::condition_variable changed;
    // Lifecycle serialization is separate: joins never hold the work mutex.
    std::mutex lifecycle_mutex;
    std::thread worker;
    std::list<std::shared_ptr<WalletClaimMaintenanceSlot>> slots;
    bool stopping{false};
    bool running{false};
    std::function<void(CWallet&, bool, bool)> test_pass;

    bool Pending() const
    {
        return std::any_of(slots.begin(), slots.end(), [](const auto& slot) {
            return slot->pending && !slot->cancelled;
        });
    }

    bool Cancelled(const WalletClaimMaintenanceSlot& slot)
    {
        std::lock_guard<std::mutex> lock(mutex);
        return stopping || slot.cancelled;
    }

    void Run()
    {
        std::unique_lock<std::mutex> lock(mutex);
        while (true) {
            changed.wait(lock, [&] { return stopping || Pending(); });
            if (stopping) break;
            auto next = std::find_if(slots.begin(), slots.end(), [](const auto& slot) {
                return slot->pending && !slot->cancelled;
            });
            const auto slot = *next;
            // A wallet dirtied while active goes behind all other wallets.
            slots.splice(slots.end(), slots, next);
            const bool resolve = slot->resolve;
            const bool relay = slot->relay;
            slot->pending = slot->resolve = slot->relay = false;
            slot->active = true;
            lock.unlock();
            {
                const auto wallet = slot->wallet.lock();
                if (wallet && !Cancelled(*slot)) {
                    try {
                        if (test_pass) {
                            test_pass(*wallet, resolve, relay);
                        } else {
                            wallet->RepairStaleShadowTransactions(/*force=*/false);
                            if (resolve && !Cancelled(*slot)) {
                                wallet->MaybeAutoResolveShadowPowClaims();
                            }
                            if (relay && !Cancelled(*slot) && wallet->HaveChain() &&
                                wallet->chain().isReadyToBroadcast()) {
                                wallet->RelayRetainedShadowPowClaim(/*relay=*/true);
                            }
                        }
                    } catch (const std::exception& e) {
                        wallet->WalletLogPrintf("Claim maintenance deferred after exception: %s\n", e.what());
                    } catch (...) {
                        wallet->WalletLogPrintf("Claim maintenance deferred after unknown exception\n");
                    }
                }
            } // Release temporary wallet ownership before acknowledging drain.
            lock.lock();
            slot->active = false;
            changed.notify_all();
        }
        running = false;
        changed.notify_all();
    }
};

WalletClaimMaintenance::WalletClaimMaintenance()
    : WalletClaimMaintenance(std::function<void(CWallet&, bool, bool)>{}) {}

WalletClaimMaintenance::WalletClaimMaintenance(
    std::function<void(CWallet&, bool, bool)> test_pass) : m_state(std::make_shared<State>())
{
    m_state->test_pass = std::move(test_pass);
}

WalletClaimMaintenance::~WalletClaimMaintenance() { Stop(); }

void WalletClaimMaintenance::Start()
{
    const auto state = m_state;
    std::lock_guard<std::mutex> lifecycle(state->lifecycle_mutex);
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->stopping || state->worker.joinable()) return;
    state->worker = std::thread([state] {
        util::TraceThread("wallet-claims", [state] { state->Run(); });
    });
    state->running = true;
}

void WalletClaimMaintenance::Register(const std::shared_ptr<CWallet>& wallet)
{
    AssertLockNotHeld(cs_main);
    AssertLockNotHeld(wallet->cs_wallet);
    auto slot = std::make_shared<WalletClaimMaintenanceSlot>();
    slot->state = m_state;
    slot->wallet = wallet;
    LOCK(wallet->cs_wallet);
    if (wallet->m_claim_maintenance || wallet->m_claim_maintenance_unregistered) return;
    std::lock_guard<std::mutex> lock(m_state->mutex);
    if (m_state->stopping) return;
    m_state->slots.push_back(slot);
    wallet->m_claim_maintenance = std::move(slot);
    m_state->changed.notify_one();
}

void RequestWalletClaimMaintenance(
    const std::shared_ptr<WalletClaimMaintenanceSlot>& slot,
    bool resolve, bool relay)
{
    if (!slot) return;
    const auto state = slot->state.lock();
    if (!state) return;
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->stopping || slot->cancelled) return;
    slot->pending = true;
    slot->resolve |= resolve;
    slot->relay |= relay;
    state->changed.notify_one();
}

void WalletClaimMaintenance::Unregister(CWallet& wallet)
{
    AssertLockNotHeld(cs_main);
    AssertLockNotHeld(wallet.cs_wallet);
    std::shared_ptr<WalletClaimMaintenanceSlot> slot;
    {
        LOCK(wallet.cs_wallet);
        // Removal may race postInitProcess before initial registration. Never
        // attach background work after that wallet's unload boundary began.
        wallet.m_claim_maintenance_unregistered = true;
        slot = std::move(wallet.m_claim_maintenance);
    }
    if (!slot) return;
    std::unique_lock<std::mutex> lock(m_state->mutex);
    slot->cancelled = true;
    slot->pending = false;
    m_state->changed.notify_all();
    m_state->changed.wait(lock, [&] { return !slot->active; });
    m_state->slots.remove(slot);
    m_state->changed.notify_all();
}

void WalletClaimMaintenance::Stop()
{
    const auto state = m_state;
    std::lock_guard<std::mutex> lifecycle(state->lifecycle_mutex);
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->stopping = true;
        for (const auto& slot : state->slots) {
            slot->cancelled = true;
            slot->pending = false;
        }
        state->changed.notify_all();
    }
    if (state->worker.joinable()) {
        AssertLockNotHeld(cs_main);
        state->worker.join();
    }
}

void WalletClaimMaintenance::Sync()
{
    AssertLockNotHeld(cs_main);
    std::unique_lock<std::mutex> lock(m_state->mutex);
    m_state->changed.wait(lock, [&] {
        return (!m_state->running || !m_state->Pending()) &&
            std::none_of(m_state->slots.begin(), m_state->slots.end(),
                         [](const auto& slot) { return slot->active; });
    });
}

bool WalletClaimMaintenance::WaitForCancellationForTesting(
    const std::shared_ptr<WalletClaimMaintenanceSlot>& slot,
    std::chrono::milliseconds timeout)
{
    std::unique_lock<std::mutex> lock(m_state->mutex);
    return m_state->changed.wait_for(lock, timeout, [&] { return slot->cancelled; });
}

bool VerifyWallets(WalletContext& context)
{
    interfaces::Chain& chain = *context.chain;
    ArgsManager& args = *Assert(context.args);

    if (args.IsArgSet("-walletdir")) {
        const fs::path wallet_dir{args.GetPathArg("-walletdir")};
        std::error_code error;
        // The canonical path cleans the path, preventing >1 Berkeley environment instances for the same directory
        // It also lets the fs::exists and fs::is_directory checks below pass on windows, since they return false
        // if a path has trailing slashes, and it strips trailing slashes.
        fs::path canonical_wallet_dir = fs::canonical(wallet_dir, error);
        if (error || !fs::exists(canonical_wallet_dir)) {
            chain.initError(strprintf(_("Specified -walletdir \"%s\" does not exist"), fs::PathToString(wallet_dir)));
            return false;
        } else if (!fs::is_directory(canonical_wallet_dir)) {
            chain.initError(strprintf(_("Specified -walletdir \"%s\" is not a directory"), fs::PathToString(wallet_dir)));
            return false;
        // The canonical path transforms relative paths into absolute ones, so we check the non-canonical version
        } else if (!wallet_dir.is_absolute()) {
            chain.initError(strprintf(_("Specified -walletdir \"%s\" is a relative path"), fs::PathToString(wallet_dir)));
            return false;
        }
        args.ForceSetArg("-walletdir", fs::PathToString(canonical_wallet_dir));
    }

    LogPrintf("Using wallet directory %s\n", fs::PathToString(GetWalletDir()));

    chain.initMessage(_("Verifying wallet(s)…").translated);

    // For backwards compatibility if an unnamed top level wallet exists in the
    // wallets directory, include it in the default list of wallets to load.
    if (!args.IsArgSet("wallet")) {
        DatabaseOptions options;
        DatabaseStatus status;
        ReadDatabaseArgs(args, options);
        bilingual_str error_string;
        options.require_existing = true;
        options.verify = false;
        if (MakeWalletDatabase("", options, status, error_string)) {
            common::SettingsValue wallets(common::SettingsValue::VARR);
            wallets.push_back(""); // Default wallet name is ""
            // Pass write=false because no need to write file and probably
            // better not to. If unnamed wallet needs to be added next startup
            // and the setting is empty, this code will just run again.
            chain.updateRwSetting("wallet", wallets, /* write= */ false);
        }
    }

    // Keep track of each wallet absolute path to detect duplicates.
    std::set<fs::path> wallet_paths;

    for (const auto& wallet : chain.getSettingsList("wallet")) {
        const auto& wallet_file = wallet.get_str();
        const fs::path path = fsbridge::AbsPathJoin(GetWalletDir(), fs::PathFromString(wallet_file));

        if (!wallet_paths.insert(path).second) {
            chain.initWarning(strprintf(_("Ignoring duplicate -wallet %s."), wallet_file));
            continue;
        }

        DatabaseOptions options;
        DatabaseStatus status;
        ReadDatabaseArgs(args, options);
        options.require_existing = true;
        options.verify = true;
        bilingual_str error_string;
        if (!MakeWalletDatabase(wallet_file, options, status, error_string)) {
            if (status == DatabaseStatus::FAILED_NOT_FOUND) {
                chain.initWarning(Untranslated(strprintf("Skipping -wallet path that doesn't exist. %s", error_string.original)));
            } else {
                chain.initError(error_string);
                return false;
            }
        }
    }

    return true;
}

bool LoadWallets(WalletContext& context)
{
    interfaces::Chain& chain = *context.chain;
    try {
        std::set<fs::path> wallet_paths;
        for (const auto& wallet : chain.getSettingsList("wallet")) {
            const auto& name = wallet.get_str();
            if (!wallet_paths.insert(fs::PathFromString(name)).second) {
                continue;
            }
            DatabaseOptions options;
            DatabaseStatus status;
            ReadDatabaseArgs(*context.args, options);
            options.require_existing = true;
            options.verify = false; // No need to verify, assuming verified earlier in VerifyWallets()
            bilingual_str error;
            std::vector<bilingual_str> warnings;
            std::unique_ptr<WalletDatabase> database = MakeWalletDatabase(name, options, status, error);
            if (!database && status == DatabaseStatus::FAILED_NOT_FOUND) {
                continue;
            }
            chain.initMessage(_("Loading wallet…").translated);
            std::shared_ptr<CWallet> pwallet = database ? CWallet::Create(context, name, std::move(database), options.create_flags, error, warnings) : nullptr;
            if (!warnings.empty()) chain.initWarning(Join(warnings, Untranslated("\n")));
            if (!pwallet) {
                chain.initError(error);
                return false;
            }

            if (!pwallet->ApplyShadowPowClaimRecoveryStartupPolicy(*context.args, error)) {
                chain.initError(Untranslated(strprintf(
                    "Failed to seed PoW claim recovery policy for wallet %s: %s",
                    name, error.original)));
                return false;
            }

            NotifyWalletLoaded(context, pwallet);
            AddWallet(context, pwallet);
        }
        return true;
    } catch (const std::runtime_error& e) {
        chain.initError(Untranslated(e.what()));
        return false;
    }
}

void StartWallets(WalletContext& context, CScheduler& scheduler)
{
    for (const std::shared_ptr<CWallet>& pwallet : GetWallets(context)) {
        pwallet->postInitProcess();
        context.claim_maintenance->Register(pwallet);
    }
    context.claim_maintenance->Start();

    // Schedule periodic wallet flushes and tx rebroadcasts
    if (context.args->GetBoolArg("-flushwallet", DEFAULT_FLUSHWALLET)) {
        scheduler.scheduleEvery([&context] { MaybeCompactWalletDB(context); }, std::chrono::milliseconds{500});
    }
    scheduler.scheduleEvery([&context] { MaybeResendWalletTxs(context); }, 1min);
}

void FlushWallets(WalletContext& context)
{
    context.claim_maintenance->Stop();
    for (const std::shared_ptr<CWallet>& pwallet : GetWallets(context)) {
        pwallet->StopPowMining();
        pwallet->StopStake();
        pwallet->Flush();
    }
}

void StopWallets(WalletContext& context)
{
    context.claim_maintenance->Stop();
    for (const std::shared_ptr<CWallet>& pwallet : GetWallets(context)) {
        pwallet->Close();
    }
}

void UnloadWallets(WalletContext& context)
{
    context.claim_maintenance->Stop();
    auto wallets = GetWallets(context);
    while (!wallets.empty()) {
        auto wallet = wallets.back();
        wallets.pop_back();
        std::vector<bilingual_str> warnings;
        RemoveWallet(context, wallet, /* load_on_start= */ std::nullopt, warnings);
        UnloadWallet(std::move(wallet));
    }
}
} // namespace wallet
