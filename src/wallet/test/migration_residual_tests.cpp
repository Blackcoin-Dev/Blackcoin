// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

// The migration report inventories every unspent legacy output the wallet owns and files each one
// the sweep did not consider under a reason. A wallet that cannot sign (no private keys) must
// report all of its legacy outputs as "signer unavailable", not as migrated or absent.

#include <addresstype.h>
#include <key.h>
#include <key_io.h>
#include <script/descriptor.h>
#include <script/script.h>
#include <script/signingprovider.h>
#include <test/util/setup_common.h>
#include <validation.h>
#include <wallet/migration_batch.h>
#include <wallet/test/util.h>
#include <wallet/transaction.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

#include <memory>

namespace wallet {
BOOST_FIXTURE_TEST_SUITE(migration_residual_tests, TestChain100Setup)

BOOST_AUTO_TEST_CASE(a_wallet_without_private_keys_reports_its_legacy_outputs_as_having_no_signer)
{
    auto wallet = std::make_unique<CWallet>(m_node.chain.get(), "", CreateMockableWalletDatabase());
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        wallet->SetLastBlockProcessed(m_node.chainman->ActiveChain().Height(), m_node.chainman->ActiveChain().Tip()->GetBlockHash());
    }
    wallet->LoadWallet();
    const CPubKey pubkey = coinbaseKey.GetPubKey();
    // The report reads the chainstate, so (as its callers do) take the chain lock before the wallet lock.
    LOCK2(::cs_main, wallet->cs_wallet);
    const int height = m_node.chainman->ActiveChain().Height();
    const uint256 block_hash = m_node.chainman->ActiveChain()[1]->GetBlockHash();
    wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
    wallet->SetWalletFlag(WALLET_FLAG_DISABLE_PRIVATE_KEYS);
    FlatSigningProvider provider;
    std::string error;
    std::unique_ptr<Descriptor> desc = Parse("pkh(" + HexStr(pubkey) + ")", provider, error, /*require_checksum=*/false);
    BOOST_REQUIRE(desc);
    WalletDescriptor w_desc(std::move(desc), 0, 0, 1, 1);
    BOOST_REQUIRE(wallet->AddWalletDescriptor(w_desc, provider, "", false));

    CMutableTransaction tx;
    tx.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(7)}, 0});
    tx.vout.emplace_back(2 * COIN, GetScriptForDestination(PKHash(pubkey)));
    BOOST_REQUIRE(wallet->AddToWallet(MakeTransactionRef(tx), TxStateConfirmed{block_hash, 1, 0}));
    BOOST_REQUIRE_LT(1, height);

    const Consensus::Params& consensus = Params().GetConsensus();
    const ExcludedLegacyOutputs excluded = FindExcludedLegacyOutputs(*wallet, /*considered=*/{}, consensus, height + 1);
    BOOST_CHECK_EQUAL(excluded.count, 1U);
    BOOST_CHECK_EQUAL(excluded.amount, 2 * COIN);
    BOOST_CHECK_EQUAL(excluded.signer_unavailable.count, 1U);
    BOOST_CHECK_EQUAL(excluded.signer_unavailable.amount, 2 * COIN);
    BOOST_CHECK_EQUAL(excluded.other.count, 0U);
    BOOST_CHECK_EQUAL(excluded.locked.count + excluded.immature.count + excluded.unconfirmed.count + excluded.protected_asset.count, 0U);
    BOOST_CHECK(DescribeExcludedLegacyOutputs(excluded).find("without a signer here") != std::string::npos);

    // A sweep that already considered the output leaves nothing behind.
    const COutPoint outpoint{wallet->mapWallet.begin()->first, 0};
    const ExcludedLegacyOutputs none = FindExcludedLegacyOutputs(*wallet, {outpoint}, consensus, height + 1);
    BOOST_CHECK_EQUAL(none.count, 0U);
    BOOST_CHECK(DescribeExcludedLegacyOutputs(none).empty());
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
