#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""-finalstakereserve takes the bare flag and 0, 1, true and false (any letter case), nothing else.

A value is parsed before the generic boolean reading discards its text, on the command line and in the configuration
file, in the positive form and in the negated form (-nofinalstakereserve=true means false). Anything else, an empty
assignment included, stops the start with an error that names the option. Unset, the reserve is on.
"""
from test_framework.test_framework import BitcoinTestFramework
from test_framework.test_node import ErrorMatch
from test_framework.util import assert_equal

INVALID = ["maybe", "2", "-1", "yes", "no", "on", "off", "01", "t", "abc", "", " 1"]


class FinalStakeReserveOptionTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def enabled(self):
        return self.nodes[0].get_wallet_rpc(self.default_wallet_name).getquantumstakereadiness()["final_stake_reserve"]["enabled"]

    def conf_path(self):
        return self.nodes[0].datadir_path / "blackcoin.conf"

    def run_test(self):
        node = self.nodes[0]
        assert_equal(self.enabled(), True)  # unset: on

        self.log.info("Accepted on the command line")
        accepted = [
            ([], True),
            (["-finalstakereserve"], True),
            (["-nofinalstakereserve"], False),
            (["-finalstakereserve=1"], True),
            (["-finalstakereserve=0"], False),
            (["-finalstakereserve=true"], True),
            (["-finalstakereserve=false"], False),
            (["-finalstakereserve=TRUE"], True),
            (["-finalstakereserve=False"], False),
            (["-nofinalstakereserve=1"], False),
            (["-nofinalstakereserve=0"], True),
            (["-nofinalstakereserve=true"], False),
            (["-nofinalstakereserve=FALSE"], True),
        ]
        for args, expected in accepted:
            self.restart_node(0, extra_args=args)
            assert_equal(self.enabled(), expected)
        self.stop_node(0)

        self.log.info("Refused on the command line, before the node starts")
        for value in INVALID:
            for prefix in ("-finalstakereserve=", "-nofinalstakereserve="):
                node.assert_start_raises_init_error(
                    extra_args=[prefix + value],
                    expected_msg="Error: Error parsing command line arguments: Invalid value '%s' for -%s: only 0, 1, true or false is accepted (or no value)" % (
                        value, prefix[1:-1]),
                )

        self.log.info("The configuration file takes the same values")
        conf = self.conf_path()
        base = conf.read_text(encoding="utf-8")
        for line, expected in [("finalstakereserve=0", False), ("finalstakereserve=false", False), ("finalstakereserve=TRUE", True),
                               ("finalstakereserve=1", True), ("nofinalstakereserve=1", False), ("nofinalstakereserve=false", True)]:
            conf.write_text(base + line + "\n", encoding="utf-8")
            self.start_node(0)
            assert_equal(self.enabled(), expected)
            self.stop_node(0)
        for value in INVALID[:-1]:  # a padded value is trimmed by the configuration file reader
            for key in ("finalstakereserve", "nofinalstakereserve"):
                conf.write_text(base + "%s=%s\n" % (key, value), encoding="utf-8")
                node.assert_start_raises_init_error(
                    expected_msg="Error: Error reading configuration file: Invalid value '%s' for -%s: only 0, 1, true or false is accepted (or no value)" % (value, key),
                )

        self.log.info("The command line still takes precedence over the configuration file")
        conf.write_text(base + "finalstakereserve=0\n", encoding="utf-8")
        self.start_node(0, extra_args=["-finalstakereserve=1"])
        assert_equal(self.enabled(), True)
        self.stop_node(0)

        self.log.info("Repeated assignments in the configuration file keep their ordinary precedence: the first positive one wins")
        for lines, expected in [("finalstakereserve=0\nfinalstakereserve=1\n", False), ("finalstakereserve=1\nfinalstakereserve=0\n", True),
                                ("finalstakereserve=false\nfinalstakereserve=true\n", False),
                                ("[regtest]\nfinalstakereserve=0\n", False)]:
            conf.write_text(base + lines, encoding="utf-8")
            self.start_node(0)
            assert_equal(self.enabled(), expected)
            self.stop_node(0)
        conf.write_text(base + "finalstakereserve=1\nfinalstakereserve=maybe\n", encoding="utf-8")
        node.assert_start_raises_init_error(expected_msg="Invalid value 'maybe' for -finalstakereserve", match=ErrorMatch.PARTIAL_REGEX)
        conf.write_text(base, encoding="utf-8")

        self.log.info("settings.json is checked before the wallet starts")
        settings = node.chain_path / "settings.json"
        # The wallets that load at startup are kept in the same file.
        wallets_key = '"wallet": ["%s"],' % self.default_wallet_name
        for text, expected in [("false", False), ("true", True), ("0", False), ("1", True), ('"false"', False), ('"TRUE"', True)]:
            settings.write_text('{%s "finalstakereserve": %s}' % (wallets_key, text), encoding="utf-8")
            self.start_node(0)
            assert_equal(self.enabled(), expected)
            self.stop_node(0)
        for text in ['"maybe"', '""', "2", "-1", "0.5", "[]", "[1]", "{}", "null", '"yes"']:
            settings.write_text('{%s "finalstakereserve": %s}' % (wallets_key, text), encoding="utf-8")
            node.assert_start_raises_init_error(expected_msg="Settings file could not be read", match=ErrorMatch.PARTIAL_REGEX)
            # The refusal is an abort: the file on disk is left as it was.
            assert_equal(settings.read_text(encoding="utf-8"), '{%s "finalstakereserve": %s}' % (wallets_key, text))
        settings.write_text('{%s "nofinalstakereserve": true}' % wallets_key, encoding="utf-8")
        node.assert_start_raises_init_error(expected_msg="Settings file could not be read", match=ErrorMatch.PARTIAL_REGEX)
        self.log.info("settings.json against the configuration file and the command line")
        conf.write_text(base + "finalstakereserve=1\n", encoding="utf-8")
        settings.write_text('{%s "finalstakereserve": false}' % wallets_key, encoding="utf-8")
        self.start_node(0)
        assert_equal(self.enabled(), False)  # a persistent setting overrides the configuration file
        self.stop_node(0)
        self.start_node(0, extra_args=["-finalstakereserve=1"])
        assert_equal(self.enabled(), True)  # the command line overrides both
        self.stop_node(0)
        settings.write_text('{%s "x": 0}' % wallets_key, encoding="utf-8")
        conf.write_text(base, encoding="utf-8")
        self.start_node(0)
        assert_equal(self.enabled(), True)  # absent everywhere: the default


if __name__ == '__main__':
    FinalStakeReserveOptionTest().main()
