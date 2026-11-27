// Copyright (c) 2012-2022 The Bitcoin Core developers
// Copyright (c) 2012-2022 Blackcoin Core Developers
// Copyright (c) 2012-2022 Blackcoin More Developers
// Copyright (c) 2012-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <common/args.h>
#include <common/settings.h>
#include <logging.h>
#include <test/util/setup_common.h>
#include <univalue.h>
#include <util/strencodings.h>

#include <limits>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include <boost/test/unit_test.hpp>

BOOST_FIXTURE_TEST_SUITE(getarg_tests, BasicTestingSetup)

void ResetArgs(ArgsManager& local_args, const std::string& strArg)
{
    std::vector<std::string> vecArg;
    if (strArg.size()) {
        vecArg = SplitString(strArg, ' ');
    }

    // Insert dummy executable name:
    vecArg.insert(vecArg.begin(), "testbitcoin");

    // Convert to char*:
    std::vector<const char*> vecChar;
    vecChar.reserve(vecArg.size());
    for (const std::string& s : vecArg)
        vecChar.push_back(s.c_str());

    std::string error;
    BOOST_CHECK(local_args.ParseParameters(vecChar.size(), vecChar.data(), error));
}

void SetupArgs(ArgsManager& local_args, const std::vector<std::pair<std::string, unsigned int>>& args)
{
    for (const auto& arg : args) {
        local_args.AddArg(arg.first, "", arg.second, OptionsCategory::OPTIONS);
    }
}

// Test behavior of GetArg functions when string, integer, and boolean types
// are specified in the settings.json file. GetArg functions are convenience
// functions. The GetSetting method can always be used instead of GetArg
// methods to retrieve original values, and there's not always an objective
// answer to what GetArg behavior is best in every case. This test makes sure
// there's test coverage for whatever the current behavior is, so it's not
// broken or changed unintentionally.
BOOST_AUTO_TEST_CASE(setting_args)
{
    ArgsManager args;
    SetupArgs(args, {{"-foo", ArgsManager::ALLOW_ANY}});

    auto set_foo = [&](const common::SettingsValue& value) {
      args.LockSettings([&](common::Settings& settings) {
        settings.rw_settings["foo"] = value;
      });
    };

    set_foo("str");
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "\"str\"");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "str");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 0);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", true), false);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", false), false);

    set_foo("99");
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "\"99\"");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "99");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 99);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", true), true);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", false), true);

    set_foo("3.25");
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "\"3.25\"");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "3.25");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 3);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", true), true);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", false), true);

    set_foo("0");
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "\"0\"");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "0");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 0);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", true), false);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", false), false);

    set_foo("");
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "\"\"");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 0);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", true), true);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", false), true);

    set_foo(99);
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "99");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "99");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 99);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", true), std::runtime_error);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", false), std::runtime_error);

    set_foo(3.25);
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "3.25");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "3.25");
    BOOST_CHECK_THROW(args.GetIntArg("foo", 100), std::runtime_error);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", true), std::runtime_error);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", false), std::runtime_error);

    set_foo(0);
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "0");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "0");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 0);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", true), std::runtime_error);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", false), std::runtime_error);

    set_foo(true);
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "true");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "1");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 1);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", true), true);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", false), true);

    set_foo(false);
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "false");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "0");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 0);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", true), false);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", false), false);

    set_foo(UniValue::VOBJ);
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "{}");
    BOOST_CHECK_THROW(args.GetArg("foo", "default"), std::runtime_error);
    BOOST_CHECK_THROW(args.GetIntArg("foo", 100), std::runtime_error);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", true), std::runtime_error);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", false), std::runtime_error);

    set_foo(UniValue::VARR);
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "[]");
    BOOST_CHECK_THROW(args.GetArg("foo", "default"), std::runtime_error);
    BOOST_CHECK_THROW(args.GetIntArg("foo", 100), std::runtime_error);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", true), std::runtime_error);
    BOOST_CHECK_THROW(args.GetBoolArg("foo", false), std::runtime_error);

    set_foo(UniValue::VNULL);
    BOOST_CHECK_EQUAL(args.GetSetting("foo").write(), "null");
    BOOST_CHECK_EQUAL(args.GetArg("foo", "default"), "default");
    BOOST_CHECK_EQUAL(args.GetIntArg("foo", 100), 100);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", true), true);
    BOOST_CHECK_EQUAL(args.GetBoolArg("foo", false), false);
}

BOOST_AUTO_TEST_CASE(boolarg)
{
    ArgsManager local_args;

    const auto foo = std::make_pair("-foo", ArgsManager::ALLOW_ANY);
    SetupArgs(local_args, {foo});
    ResetArgs(local_args, "-foo");
    BOOST_CHECK(local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(local_args.GetBoolArg("-foo", true));

    BOOST_CHECK(!local_args.GetBoolArg("-fo", false));
    BOOST_CHECK(local_args.GetBoolArg("-fo", true));

    BOOST_CHECK(!local_args.GetBoolArg("-fooo", false));
    BOOST_CHECK(local_args.GetBoolArg("-fooo", true));

    ResetArgs(local_args, "-foo=0");
    BOOST_CHECK(!local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(!local_args.GetBoolArg("-foo", true));

    ResetArgs(local_args, "-foo=1");
    BOOST_CHECK(local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(local_args.GetBoolArg("-foo", true));

    // New 0.6 feature: auto-map -nosomething to !-something:
    ResetArgs(local_args, "-nofoo");
    BOOST_CHECK(!local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(!local_args.GetBoolArg("-foo", true));

    ResetArgs(local_args, "-nofoo=1");
    BOOST_CHECK(!local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(!local_args.GetBoolArg("-foo", true));

    ResetArgs(local_args, "-foo -nofoo"); // -nofoo should win
    BOOST_CHECK(!local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(!local_args.GetBoolArg("-foo", true));

    ResetArgs(local_args, "-foo=1 -nofoo=1"); // -nofoo should win
    BOOST_CHECK(!local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(!local_args.GetBoolArg("-foo", true));

    ResetArgs(local_args, "-foo=0 -nofoo=0"); // -nofoo=0 should win
    BOOST_CHECK(local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(local_args.GetBoolArg("-foo", true));

    // New 0.6 feature: treat -- same as -:
    ResetArgs(local_args, "--foo=1");
    BOOST_CHECK(local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(local_args.GetBoolArg("-foo", true));

    ResetArgs(local_args, "--nofoo=1");
    BOOST_CHECK(!local_args.GetBoolArg("-foo", false));
    BOOST_CHECK(!local_args.GetBoolArg("-foo", true));
}

BOOST_AUTO_TEST_CASE(stringarg)
{
    ArgsManager local_args;

    const auto foo = std::make_pair("-foo", ArgsManager::ALLOW_ANY);
    const auto bar = std::make_pair("-bar", ArgsManager::ALLOW_ANY);
    SetupArgs(local_args, {foo, bar});
    ResetArgs(local_args, "");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", ""), "");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", "eleven"), "eleven");

    ResetArgs(local_args, "-foo -bar");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", ""), "");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", "eleven"), "");

    ResetArgs(local_args, "-foo=");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", ""), "");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", "eleven"), "");

    ResetArgs(local_args, "-foo=11");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", ""), "11");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", "eleven"), "11");

    ResetArgs(local_args, "-foo=eleven");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", ""), "eleven");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", "eleven"), "eleven");
}

BOOST_AUTO_TEST_CASE(intarg)
{
    ArgsManager local_args;

    const auto foo = std::make_pair("-foo", ArgsManager::ALLOW_ANY);
    const auto bar = std::make_pair("-bar", ArgsManager::ALLOW_ANY);
    SetupArgs(local_args, {foo, bar});
    ResetArgs(local_args, "");
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-foo", 11), 11);
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-foo", 0), 0);

    ResetArgs(local_args, "-foo -bar");
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-foo", 11), 0);
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-bar", 11), 0);

    // Check under-/overflow behavior.
    ResetArgs(local_args, "-foo=-9223372036854775809 -bar=9223372036854775808");
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-foo", 0), std::numeric_limits<int64_t>::min());
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-bar", 0), std::numeric_limits<int64_t>::max());

    ResetArgs(local_args, "-foo=11 -bar=12");
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-foo", 0), 11);
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-bar", 11), 12);

    ResetArgs(local_args, "-foo=NaN -bar=NotANumber");
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-foo", 1), 0);
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-bar", 11), 0);
}

BOOST_AUTO_TEST_CASE(patharg)
{
    ArgsManager local_args;

    const auto dir = std::make_pair("-dir", ArgsManager::ALLOW_ANY);
    SetupArgs(local_args, {dir});
    ResetArgs(local_args, "");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), fs::path{});

    const fs::path root_path{"/"};
    ResetArgs(local_args, "-dir=/");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), root_path);

    ResetArgs(local_args, "-dir=/.");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), root_path);

    ResetArgs(local_args, "-dir=/./");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), root_path);

    ResetArgs(local_args, "-dir=/.//");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), root_path);

#ifdef WIN32
    const fs::path win_root_path{"C:\\"};
    ResetArgs(local_args, "-dir=C:\\");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), win_root_path);

    ResetArgs(local_args, "-dir=C:/");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), win_root_path);

    ResetArgs(local_args, "-dir=C:\\\\");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), win_root_path);

    ResetArgs(local_args, "-dir=C:\\.");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), win_root_path);

    ResetArgs(local_args, "-dir=C:\\.\\");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), win_root_path);

    ResetArgs(local_args, "-dir=C:\\.\\\\");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), win_root_path);
#endif

    const fs::path absolute_path{"/home/user/.bitcoin"};
    ResetArgs(local_args, "-dir=/home/user/.bitcoin");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), absolute_path);

    ResetArgs(local_args, "-dir=/root/../home/user/.bitcoin");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), absolute_path);

    ResetArgs(local_args, "-dir=/home/./user/.bitcoin");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), absolute_path);

    ResetArgs(local_args, "-dir=/home/user/.bitcoin/");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), absolute_path);

    ResetArgs(local_args, "-dir=/home/user/.bitcoin//");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), absolute_path);

    ResetArgs(local_args, "-dir=/home/user/.bitcoin/.");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), absolute_path);

    ResetArgs(local_args, "-dir=/home/user/.bitcoin/./");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), absolute_path);

    ResetArgs(local_args, "-dir=/home/user/.bitcoin/.//");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), absolute_path);

    const fs::path relative_path{"user/.bitcoin"};
    ResetArgs(local_args, "-dir=user/.bitcoin");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), relative_path);

    ResetArgs(local_args, "-dir=somewhere/../user/.bitcoin");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), relative_path);

    ResetArgs(local_args, "-dir=user/./.bitcoin");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), relative_path);

    ResetArgs(local_args, "-dir=user/.bitcoin/");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), relative_path);

    ResetArgs(local_args, "-dir=user/.bitcoin//");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), relative_path);

    ResetArgs(local_args, "-dir=user/.bitcoin/.");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), relative_path);

    ResetArgs(local_args, "-dir=user/.bitcoin/./");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), relative_path);

    ResetArgs(local_args, "-dir=user/.bitcoin/.//");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir"), relative_path);

    // Check negated and default argument handling. Specifying an empty argument
    // is the same as not specifying the argument. This is convenient for
    // scripting so later command line arguments can override earlier command
    // line arguments or bitcoin.conf values. Currently the -dir= case cannot be
    // distinguished from -dir case with no assignment, but #16545 would add the
    // ability to distinguish these in the future (and treat the no-assign case
    // like an imperative command or an error).
    ResetArgs(local_args, "");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir", "default"), fs::path{"default"});
    ResetArgs(local_args, "-dir=override");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir", "default"), fs::path{"override"});
    ResetArgs(local_args, "-dir=");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir", "default"), fs::path{"default"});
    ResetArgs(local_args, "-dir");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir", "default"), fs::path{"default"});
    ResetArgs(local_args, "-nodir");
    BOOST_CHECK_EQUAL(local_args.GetPathArg("-dir", "default"), fs::path{""});
}

BOOST_AUTO_TEST_CASE(doubledash)
{
    ArgsManager local_args;

    const auto foo = std::make_pair("-foo", ArgsManager::ALLOW_ANY);
    const auto bar = std::make_pair("-bar", ArgsManager::ALLOW_ANY);
    SetupArgs(local_args, {foo, bar});
    ResetArgs(local_args, "--foo");
    BOOST_CHECK_EQUAL(local_args.GetBoolArg("-foo", false), true);

    ResetArgs(local_args, "--foo=verbose --bar=1");
    BOOST_CHECK_EQUAL(local_args.GetArg("-foo", ""), "verbose");
    BOOST_CHECK_EQUAL(local_args.GetIntArg("-bar", 0), 1);
}

BOOST_AUTO_TEST_CASE(boolargno)
{
    ArgsManager local_args;

    const auto foo = std::make_pair("-foo", ArgsManager::ALLOW_ANY);
    const auto bar = std::make_pair("-bar", ArgsManager::ALLOW_ANY);
    SetupArgs(local_args, {foo, bar});
    ResetArgs(local_args, "-nofoo");
    BOOST_CHECK(!local_args.GetBoolArg("-foo", true));
    BOOST_CHECK(!local_args.GetBoolArg("-foo", false));

    ResetArgs(local_args, "-nofoo=1");
    BOOST_CHECK(!local_args.GetBoolArg("-foo", true));
    BOOST_CHECK(!local_args.GetBoolArg("-foo", false));

    ResetArgs(local_args, "-nofoo=0");
    BOOST_CHECK(local_args.GetBoolArg("-foo", true));
    BOOST_CHECK(local_args.GetBoolArg("-foo", false));

    ResetArgs(local_args, "-foo --nofoo"); // --nofoo should win
    BOOST_CHECK(!local_args.GetBoolArg("-foo", true));
    BOOST_CHECK(!local_args.GetBoolArg("-foo", false));

    ResetArgs(local_args, "-nofoo -foo"); // foo always wins:
    BOOST_CHECK(local_args.GetBoolArg("-foo", true));
    BOOST_CHECK(local_args.GetBoolArg("-foo", false));
}

BOOST_AUTO_TEST_CASE(logargs)
{
    ArgsManager local_args;

    const auto okaylog_bool = std::make_pair("-okaylog-bool", ArgsManager::ALLOW_ANY);
    const auto okaylog_negbool = std::make_pair("-okaylog-negbool", ArgsManager::ALLOW_ANY);
    const auto okaylog = std::make_pair("-okaylog", ArgsManager::ALLOW_ANY);
    const auto dontlog = std::make_pair("-dontlog", ArgsManager::ALLOW_ANY | ArgsManager::SENSITIVE);
    SetupArgs(local_args, {okaylog_bool, okaylog_negbool, okaylog, dontlog});
    ResetArgs(local_args, "-okaylog-bool -nookaylog-negbool -okaylog=public -dontlog=private42");

    // Everything logged to debug.log will also append to str
    std::string str;
    auto print_connection = LogInstance().PushBackCallback(
        [&str](const std::string& s) {
            str += s;
        });

    // Log the arguments
    local_args.LogArgs();

    LogInstance().DeleteCallback(print_connection);
    // Check that what should appear does, and what shouldn't doesn't.
    BOOST_CHECK(str.find("Command-line arg: okaylog-bool=\"\"") != std::string::npos);
    BOOST_CHECK(str.find("Command-line arg: okaylog-negbool=false") != std::string::npos);
    BOOST_CHECK(str.find("Command-line arg: okaylog=\"public\"") != std::string::npos);
    BOOST_CHECK(str.find("dontlog=****") != std::string::npos);
    BOOST_CHECK(str.find("private42") == std::string::npos);
}

namespace {
struct ConfigArgs : ArgsManager {
    bool Read(const std::string& text, std::string& error)
    {
        std::istringstream stream{text};
        return ReadConfigStream(stream, "", error);
    }
};

void SetupStrictAndPlain(ArgsManager& args, unsigned int strict_flags = ArgsManager::ALLOW_ANY | ArgsManager::STRICT_BOOL)
{
    SetupArgs(args, {{"-strict", strict_flags}, {"-plain", ArgsManager::ALLOW_ANY}});
}

bool ParseCommandLine(ArgsManager& args, const std::vector<std::string>& options, std::string& error)
{
    std::vector<const char*> argv{"testbitcoin"};
    for (const std::string& option : options) argv.push_back(option.c_str());
    return args.ParseParameters(argv.size(), argv.data(), error);
}
} // namespace

// A STRICT_BOOL option takes the bare flag and the values 0, 1, true and false in any letter case, positive and
// negated, and refuses every other text (an empty assignment included) while the text is still known. A positive
// assignment stays a string ("1" or "0") and only a negated key is a boolean, as for an ordinary option.
BOOST_AUTO_TEST_CASE(strict_bool_option)
{
    const auto read_command_line = [](const std::string& arg, std::string& error) -> std::optional<common::SettingsValue> {
        ArgsManager local_args;
        SetupStrictAndPlain(local_args);
        if (!ParseCommandLine(local_args, {arg}, error)) return std::nullopt;
        return local_args.GetSetting("strict");
    };
    const auto read_config = [](const std::string& line, std::string& error) -> std::optional<common::SettingsValue> {
        ConfigArgs local_args;
        SetupStrictAndPlain(local_args);
        if (!local_args.Read(line + "\n", error)) return std::nullopt;
        return local_args.GetSetting("strict");
    };

    // (text, boolean meaning, negated)
    struct Case { std::string text; bool value; bool negated; };
    const std::vector<Case> accepted{
        {"strict", true, false}, {"nostrict", false, true},
        {"strict=1", true, false}, {"strict=0", false, false}, {"strict=true", true, false}, {"strict=false", false, false},
        {"strict=TRUE", true, false}, {"strict=False", false, false}, {"strict=tRuE", true, false},
        {"nostrict=1", false, true}, {"nostrict=0", true, true}, {"nostrict=true", false, true}, {"nostrict=false", true, true},
        {"nostrict=TRUE", false, true}, {"nostrict=FALSE", true, true},
    };
    for (const auto& [text, expected, negated] : accepted) {
        std::string error;
        const auto from_command_line = read_command_line("-" + text, error);
        BOOST_REQUIRE_MESSAGE(from_command_line, text + ": " + error);
        if (negated) {
            BOOST_CHECK_MESSAGE(from_command_line->isBool() && from_command_line->get_bool() == expected, text);
        } else {
            // A positive assignment is a string, "1" or "0".
            BOOST_CHECK_MESSAGE(from_command_line->isStr() && from_command_line->get_str() == (expected ? "1" : "0"), text);
        }
        // A bare flag is not valid in a configuration file the way it is on the command line; the assignment forms are.
        if (text.find('=') != std::string::npos) {
            const auto from_config = read_config(text, error);
            BOOST_REQUIRE_MESSAGE(from_config, text + ": " + error);
            BOOST_CHECK_MESSAGE(from_config->write() == from_command_line->write(), text);
        }
    }
    const std::vector<std::string> rejected{
        "strict=", "nostrict=", "strict=2", "strict=-1", "strict=yes", "strict=no", "strict=on", "strict=off", "strict=01",
        "strict=t", "strict= 1", "strict=1 ", "strict=abc", "nostrict=abc", "nostrict=2", "nostrict=yes", "nostrict=00",
    };
    for (const std::string& text : rejected) {
        std::string error;
        BOOST_CHECK_MESSAGE(!read_command_line("-" + text, error), "command line accepted " + text);
        BOOST_CHECK_MESSAGE(error.find("only 0, 1, true or false") != std::string::npos, text + ": " + error);
        error.clear();
        // A configuration file trims the whitespace around a value, so a value that is only padded is the accepted one.
        if (text == "strict= 1" || text == "strict=1 ") continue;
        BOOST_CHECK_MESSAGE(!read_config(text, error), "configuration accepted " + text);
    }
    // Unset stays unset, and another option keeps the lenient reading it always had.
    ArgsManager local_args;
    SetupStrictAndPlain(local_args);
    ResetArgs(local_args, "-noplain=abc");
    BOOST_CHECK(local_args.GetSetting("strict").isNull());
    BOOST_CHECK(local_args.GetSetting("plain").isTrue()); // the old double-negative reading of an unreadable value
}

// The strict option has the precedence of an ordinary option, for repeated, mixed and sectioned assignments in the
// configuration file and on the command line: the answer is the one an ordinary option gives for the same text.
BOOST_AUTO_TEST_CASE(strict_bool_option_keeps_ordinary_precedence)
{
    const std::vector<std::vector<std::string>> sequences{
        {"=0", "=1"}, {"=1", "=0"}, {"=0", "=0"}, {"=1", "=1"},
        {"=0", "no=1"}, {"=1", "no=1"}, {"no=1", "=1"}, {"no=1", "=0"}, {"no=0", "=0"}, {"=1", "no=0"},
        {"=0", "=1", "=0"}, {"=1", "=0", "=1"}, {"=0", "=1", "no=1"}, {"no=1", "=1", "=0"},
    };
    const auto text_of = [](const std::vector<std::string>& sequence, const std::string& name, const std::string& prefix = "") {
        std::string text;
        for (const std::string& item : sequence) {
            text += prefix + (item.rfind("no", 0) == 0 ? "no" + name + item.substr(2) : name + item) + "\n";
        }
        return text;
    };
    for (const auto& sequence : sequences) {
        for (const bool default_value : {false, true}) {
            // Configuration file, default section, then a network section that has its own assignments.
            std::string error;
            ConfigArgs both;
            SetupStrictAndPlain(both);
            both.SelectConfigNetwork("regtest");
            const std::string config = text_of(sequence, "strict") + text_of(sequence, "plain") +
                                       "[regtest]\n" + text_of(sequence, "strict") + text_of(sequence, "plain");
            BOOST_REQUIRE_MESSAGE(both.Read(config, error), error);
            BOOST_CHECK_EQUAL(both.GetBoolArg("strict", default_value), both.GetBoolArg("plain", default_value));
            // Network section only.
            ConfigArgs sectioned;
            SetupStrictAndPlain(sectioned);
            sectioned.SelectConfigNetwork("regtest");
            BOOST_REQUIRE_MESSAGE(sectioned.Read(text_of(sequence, "strict", "regtest.") + text_of(sequence, "plain", "regtest."), error), error);
            BOOST_CHECK_EQUAL(sectioned.GetBoolArg("strict", default_value), sectioned.GetBoolArg("plain", default_value));
            // Command line: the last assignment wins, and the command line beats the configuration file.
            ArgsManager cli;
            SetupStrictAndPlain(cli);
            std::vector<std::string> strict_options, plain_options;
            for (const std::string& item : sequence) {
                const std::string negate = item.rfind("no", 0) == 0 ? "no" : "";
                const std::string value = item.substr(item.find('='));
                strict_options.push_back("-" + negate + "strict" + value);
                plain_options.push_back("-" + negate + "plain" + value);
            }
            std::vector<std::string> options = strict_options;
            options.insert(options.end(), plain_options.begin(), plain_options.end());
            BOOST_REQUIRE_MESSAGE(ParseCommandLine(cli, options, error), error);
            BOOST_CHECK_EQUAL(cli.GetBoolArg("strict", default_value), cli.GetBoolArg("plain", default_value));
        }
    }
    // The command line over the configuration file.
    for (const char* config_value : {"0", "1"}) {
        for (const char* cli_value : {"0", "1"}) {
            ConfigArgs args;
            SetupStrictAndPlain(args);
            std::string error;
            BOOST_REQUIRE(args.Read(std::string{"strict="} + config_value + "\nplain=" + config_value + "\n", error));
            BOOST_REQUIRE(ParseCommandLine(args, {std::string{"-strict="} + cli_value, std::string{"-plain="} + cli_value}, error));
            BOOST_CHECK_EQUAL(args.GetBoolArg("strict", false), args.GetBoolArg("plain", false));
            BOOST_CHECK_EQUAL(args.GetBoolArg("strict", true), std::string{cli_value} == "1");
        }
    }
    // An invalid occurrence fails even when a valid one follows it, on both inputs.
    for (const char* bad : {"maybe", "", "2"}) {
        std::string error;
        ArgsManager cli;
        SetupStrictAndPlain(cli);
        BOOST_CHECK(!ParseCommandLine(cli, {std::string{"-strict="} + bad, "-strict=1"}, error));
        ConfigArgs config;
        SetupStrictAndPlain(config);
        BOOST_CHECK(!config.Read(std::string{"strict="} + bad + "\nstrict=1\n", error));
        ConfigArgs negated;
        SetupStrictAndPlain(negated);
        BOOST_CHECK(!negated.Read(std::string{"nostrict="} + bad + "\nstrict=1\n", error));
    }
}

// The flags compose: negation and elision are refused before the strict reading.
BOOST_AUTO_TEST_CASE(strict_bool_option_composes_with_the_other_flags)
{
    std::string error;
    ArgsManager no_negation;
    SetupStrictAndPlain(no_negation, ArgsManager::ALLOW_ANY | ArgsManager::STRICT_BOOL | ArgsManager::DISALLOW_NEGATION);
    BOOST_CHECK(!ParseCommandLine(no_negation, {"-nostrict"}, error));
    BOOST_CHECK(error.find("Negating of -strict is meaningless") != std::string::npos);
    BOOST_CHECK(!ParseCommandLine(no_negation, {"-nostrict=maybe"}, error));
    BOOST_CHECK(error.find("Negating of -strict is meaningless") != std::string::npos);
    BOOST_CHECK(ParseCommandLine(no_negation, {"-strict=1"}, error));

    ArgsManager no_elision;
    SetupStrictAndPlain(no_elision, ArgsManager::ALLOW_ANY | ArgsManager::STRICT_BOOL | ArgsManager::DISALLOW_ELISION);
    BOOST_CHECK(!ParseCommandLine(no_elision, {"-strict"}, error));
    BOOST_CHECK(error.find("Can not set -strict with no value") != std::string::npos);
    BOOST_CHECK(ParseCommandLine(no_elision, {"-strict=0"}, error));
}

BOOST_AUTO_TEST_SUITE_END()
