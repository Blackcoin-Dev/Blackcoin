#!/usr/bin/env python3
# Copyright (c) 2026 The Quantum Quasar developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://opensource.org/license/mit/.
"""Verify retirement of legacy dev payments and fresh quantum consent."""

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error


class QQDevelopmentDonationTest(BitcoinTestFramework):
    LEGACY_WARNING = "Warning: -donatetodevfund is retired and its legacy recipient is disabled. The configured nonzero value is ignored. Use the separate -qqdevelopmentdonation facility only after reviewing its exact quantum recipient."

    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.setup_clean_chain = True
        self.num_nodes = 1
        # A historical nonzero setting must be harmless and must not migrate.
        self.extra_args = [["-donatetodevfund=95"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def run_test(self):
        wallet = self.nodes[0].get_wallet_rpc(self.default_wallet_name)

        legacy = wallet.getstakingdonationinfo()
        assert_equal(legacy["retired"], True)
        assert_equal(legacy["enabled"], False)
        assert_equal(legacy["percentage"], 0)
        assert_equal(legacy["target_address"], "")
        assert_raises_rpc_error(
            -8,
            "legacy development-fund payments are retired",
            wallet.setstakingdonation,
            1,
        )
        assert_equal(wallet.setstakingdonation(0)["percentage"], 0)

        initial = wallet.getqqdevelopmentdonationinfo()
        assert_equal(initial["enabled"], False)
        assert_equal(initial["percentage"], 0)
        assert_equal(initial["choice_recorded"], False)
        assert_equal(initial["consent_recipient"], "")
        recipient = initial["recipient"]
        recipient_info = self.nodes[0].validateaddress(recipient)
        assert_equal(recipient_info["isvalid"], True)
        assert_equal(recipient_info["iswitness"], True)
        assert_equal(recipient_info["witness_version"], 16)

        assert_raises_rpc_error(
            -4,
            "recipient must exactly match",
            wallet.setqqdevelopmentdonation,
            7,
            recipient + "wrong",
        )
        enabled = wallet.setqqdevelopmentdonation(7, recipient)
        assert_equal(enabled["enabled"], True)
        assert_equal(enabled["percentage"], 7)
        assert_equal(enabled["stored_percentage"], 7)
        assert_equal(enabled["consent_matches_current"], True)
        assert_equal(enabled["consent_recipient"], recipient)

        # Wallet-database consent survives restart. The legacy nonzero option
        # remains incapable of changing it.
        self.stop_node(0, expected_stderr=self.LEGACY_WARNING)
        self.start_node(0, extra_args=[])
        wallet = self.nodes[0].get_wallet_rpc(self.default_wallet_name)
        persisted = wallet.getqqdevelopmentdonationinfo()
        assert_equal(persisted["enabled"], True)
        assert_equal(persisted["percentage"], 7)
        assert_equal(persisted["consent_recipient"], recipient)

        # New daemon configuration is a separate consent domain. It seeds only
        # wallets without a persisted choice and binds the exact recipient.
        seed_args = [
            "-qqdevelopmentdonation=9",
            f"-qqdevelopmentdonationrecipient={recipient}",
        ]
        self.restart_node(0, extra_args=seed_args)
        wallet = self.nodes[0].get_wallet_rpc(self.default_wallet_name)
        assert_equal(wallet.getqqdevelopmentdonationinfo()["percentage"], 7)

        self.nodes[0].createwallet(wallet_name="fresh-seeded")
        seeded = self.nodes[0].get_wallet_rpc("fresh-seeded")
        seeded_info = seeded.getqqdevelopmentdonationinfo()
        assert_equal(seeded_info["enabled"], True)
        assert_equal(seeded_info["percentage"], 9)
        assert_equal(seeded_info["consent_recipient"], recipient)

        opted_out = wallet.setqqdevelopmentdonation(0, recipient)
        assert_equal(opted_out["enabled"], False)
        assert_equal(opted_out["percentage"], 0)
        assert_equal(opted_out["stored_percentage"], 0)
        assert_equal(opted_out["choice_recorded"], True)


if __name__ == "__main__":
    QQDevelopmentDonationTest().main()
