// Copyright (c) 2021-2022 Blackcoin Core Developers
// Copyright (c) 2021-2022 Blackcoin More Developers
// Copyright (c) 2021-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <consensus/amount.h>
#include <interfaces/handler.h>
#include <interfaces/wallet.h>
#include <policy/fees.h>
#include <script/solver.h>
#include <validation.h>
#include <wallet/coincontrol.h>
#include <wallet/context.h>
#include <wallet/spend.h>
#include <wallet/test/util.h>
#include <wallet/test/wallet_test_fixture.h>

#include <atomic>
#include <chrono>
#include <future>
#include <thread>

#include <boost/test/unit_test.hpp>

namespace wallet {
BOOST_FIXTURE_TEST_SUITE(spend_tests, WalletTestingSetup)

BOOST_FIXTURE_TEST_CASE(SubtractFee, TestChain100Setup)
{
    CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    CAmount input_amount;
    COutPoint input_outpoint;
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        std::vector<COutput> coins = AvailableCoins(*wallet).All();
        BOOST_REQUIRE(!coins.empty());
        input_amount = coins.front().txout.nValue;
        input_outpoint = coins.front().outpoint;
    }

    // Check that a subtract-from-recipient transaction slightly less than the
    // coinbase input amount does not create a change output (because it would
    // be uneconomical to add and spend the output), and make sure it pays the
    // leftover input amount which would have been change to the recipient
    // instead of the miner.
    auto check_tx = [&wallet, input_amount, input_outpoint](CAmount leftover_input_amount) {
        CRecipient recipient{PubKeyDestination({}), input_amount - leftover_input_amount, /*subtract_fee=*/true};
        constexpr int RANDOM_CHANGE_POSITION = -1;
        CCoinControl coin_control;
        coin_control.m_allow_other_inputs = false;
        coin_control.Select(input_outpoint);
        coin_control.m_feerate.emplace(100000);
        coin_control.fOverrideFeeRate = true;
        // We need to use a change type with high cost of change so that the leftover amount will be dropped to fee instead of added as a change output
        coin_control.m_change_type = OutputType::LEGACY;
        auto res = CreateTransaction(*wallet, {recipient}, RANDOM_CHANGE_POSITION, coin_control);
        BOOST_REQUIRE_MESSAGE(res, util::ErrorString(res).original);
        const auto& txr = *res;
        BOOST_CHECK_EQUAL(txr.tx->vout.size(), 1);
        BOOST_CHECK_EQUAL(txr.tx->vout[0].nValue, recipient.nAmount + leftover_input_amount - txr.fee);
        BOOST_CHECK_GT(txr.fee, 0);
        return txr.fee;
    };

    // Send full input amount to recipient, check that only nonzero fee is
    // subtracted (to_reduce == fee).
    const CAmount fee{check_tx(0)};

    // Send slightly less than full input amount to recipient, check leftover
    // input amount is paid to recipient not the miner (to_reduce == fee - 123)
    BOOST_CHECK_EQUAL(fee, check_tx(123));

    // Send full input minus fee amount to recipient, check leftover input
    // amount is paid to recipient not the miner (to_reduce == 0)
    BOOST_CHECK_EQUAL(fee, check_tx(fee));

    // Send full input minus more than the fee amount to recipient, check
    // leftover input amount is paid to recipient not the miner (to_reduce ==
    // -123). This overpays the recipient instead of overpaying the miner more
    // than double the necessary fee.
    BOOST_CHECK_EQUAL(fee, check_tx(fee + 123));
}

BOOST_FIXTURE_TEST_CASE(wallet_duplicated_preset_inputs_test, TestChain100Setup)
{
    // Verify that the wallet's Coin Selection process does not include pre-selected inputs twice in a transaction.

    // Add 4 more spendable UTXOs to the wallet.
    for (int i = 0; i < 4; i++) CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);

    LOCK2(::cs_main, wallet->cs_wallet);
    auto available_coins = AvailableCoins(*wallet);
    std::vector<COutput> coins = available_coins.All();
    // Preselect the first 3 UTXOs.
    std::set<COutPoint> preset_inputs = {coins[0].outpoint, coins[1].outpoint, coins[2].outpoint};

    // Try to create a tx that spends more than what preset inputs + wallet selected inputs can cover.
    const CAmount target = available_coins.GetTotalAmount() + COIN;
    std::vector<CRecipient> recipients{{*Assert(wallet->GetNewDestination(OutputType::BECH32, "dummy")),
                                           /*nAmount=*/target, /*fSubtractFeeFromAmount=*/true}};
    CCoinControl coin_control;
    coin_control.m_allow_other_inputs = true;
    for (const auto& outpoint : preset_inputs) {
        coin_control.Select(outpoint);
    }

    // Attempt to send more than the wallet balance. The wallet should exclude
    // the preset inputs from the pool of available coins, realize that there is not enough
    // money to fund the payment, and fail with "Insufficient funds".
    //
    // Even with SFFO, the wallet can only afford to send its actual balance.
    // If the wallet does not properly exclude preset inputs from the pool of available coins
    // prior to coin selection, it may create a transaction that does not fund the full payment
    // amount or, through SFFO, incorrectly reduce the recipient's amount by the difference
    // between the original target and the wrongly counted inputs
    // so that the recipient's amount is no longer equal to the user's selected target.

    // First case, use 'subtract_fee_from_outputs=true'
    util::Result<CreatedTransactionResult> res_tx = CreateTransaction(*wallet, recipients, /*change_pos*/-1, coin_control);
    BOOST_CHECK(!res_tx.has_value());

    // Second case, don't use 'subtract_fee_from_outputs'.
    recipients[0].fSubtractFeeFromAmount = false;
    res_tx = CreateTransaction(*wallet, recipients, /*change_pos*/-1, coin_control);
    BOOST_CHECK(!res_tx.has_value());
}

BOOST_FIXTURE_TEST_CASE(list_coins_interrupt, TestChain100Setup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    LOCK2(::cs_main, wallet->cs_wallet);
    const auto full = ListCoins(*wallet);
    BOOST_REQUIRE(!full.empty());

    // A callback that never fires yields exactly the uninterrupted listing.
    size_t polls{0};
    const auto polled = ListCoins(*wallet, [&] { ++polls; return false; });
    BOOST_REQUIRE(polled.has_value());
    BOOST_CHECK(polled->size() == full.size());
    for (const auto& [dest, coins] : full) {
        const auto it = polled->find(dest);
        BOOST_REQUIRE(it != polled->end());
        BOOST_REQUIRE_EQUAL(it->second.size(), coins.size());
        for (size_t i = 0; i < coins.size(); ++i) {
            BOOST_CHECK(it->second[i].outpoint == coins[i].outpoint);
            BOOST_CHECK(it->second[i].txout == coins[i].txout);
        }
    }
    const size_t complete_polls = polls;
    polls = 0;
    BOOST_CHECK(!ListCoins(*wallet, [&] { return ++polls == complete_polls; }).has_value());
    BOOST_CHECK_EQUAL(polls, complete_polls);
    BOOST_CHECK(polls >= 1);
    // Polls also cover outputs, grouping and ancestry.
    BOOST_CHECK(polls > 1);

    // A callback that fires stops the walk and reports no partial listing.
    BOOST_CHECK(!ListCoins(*wallet, [] { return true; }).has_value());

    // Funding paths without a callback are unaffected.
    CoinFilterParams params;
    BOOST_CHECK(!AvailableCoins(*wallet, /*coinControl=*/nullptr, /*feerate=*/std::nullopt, params).interrupted);
}

BOOST_FIXTURE_TEST_CASE(list_coins_interrupt_mid_walk, TestChain100Setup)
{
    // Enough wallet transactions for several interrupt polls.
    for (int i = 0; i < 4 * static_cast<int>(CoinFilterParams::INTERRUPT_CHECK_INTERVAL); ++i) {
        CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    }
    std::shared_ptr<CWallet> wallet{CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey).release()};
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_REQUIRE(wallet->mapWallet.size() > 4 * CoinFilterParams::INTERRUPT_CHECK_INTERVAL);
        size_t polls{0};
        // Fire on the third poll: the walk is part way through and must stop there.
        BOOST_CHECK(!ListCoins(*wallet, [&] { return ++polls == 3; }).has_value());
        BOOST_CHECK_EQUAL(polls, 3U);
    }

    // The interface used by the GUI snapshot reports an interrupted walk as nullopt
    // and an uninterrupted one exactly like listCoins().
    WalletContext wallet_context;
    wallet_context.chain = m_node.chain.get();
    auto wallet_interface = interfaces::MakeWallet(wallet_context, wallet);
    size_t polls{0};
    BOOST_CHECK(!wallet_interface->tryListCoins([&] { return ++polls == 2; }).has_value());
    BOOST_CHECK_EQUAL(polls, 2U);
    const auto full = wallet_interface->listCoins();
    const auto polled = wallet_interface->tryListCoins([] { return false; });
    BOOST_REQUIRE(polled.has_value());
    BOOST_CHECK_EQUAL(polled->size(), full.size());
    // The GUI snapshot must not wait behind another holder of cs_wallet.
    std::promise<void> locked, release_lock;
    auto released = release_lock.get_future().share();
    std::atomic<bool> deadline_expired{false};
    std::thread holder([&] {
        LOCK(wallet->cs_wallet);
        locked.set_value();
        deadline_expired = released.wait_for(std::chrono::seconds{3}) == std::future_status::timeout;
    });
    auto cleanup = interfaces::MakeCleanupHandler([&] { release_lock.set_value(); holder.join(); });
    locked.get_future().wait();
    const bool busy = !wallet_interface->tryListCoins([] { return false; }).has_value();
    const bool returned_while_held = !deadline_expired.load();
    cleanup.reset(); // Release/join before assertions, including fatal failures.
    BOOST_CHECK(returned_while_held);
    BOOST_CHECK(busy);
    // Initial history cancellation likewise publishes no partial replacement.
    std::vector<interfaces::WalletTx> transactions(1);
    size_t history_polls{0};
    BOOST_CHECK(!wallet_interface->tryGetWalletTxs(transactions, [&] { return ++history_polls == 3; }));
    BOOST_CHECK_EQUAL(transactions.size(), 1U);
    BOOST_CHECK(wallet_interface->tryGetWalletTxs(transactions));
    BOOST_CHECK_EQUAL(transactions.size(), wallet->mapWallet.size());
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
