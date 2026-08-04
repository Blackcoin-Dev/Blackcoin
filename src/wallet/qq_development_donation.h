// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_QQ_DEVELOPMENT_DONATION_H
#define BITCOIN_WALLET_QQ_DEVELOPMENT_DONATION_H

#include <serialize.h>

#include <cstdint>
#include <string>

namespace wallet {

static constexpr unsigned int DEFAULT_QQ_DEVELOPMENT_DONATION_PERCENTAGE{0};
static constexpr unsigned int MIN_QQ_DEVELOPMENT_DONATION_PERCENTAGE{0};
static constexpr unsigned int MAX_QQ_DEVELOPMENT_DONATION_PERCENTAGE{95};

/** Wallet-scoped, recipient-bound consent for the optional Quantum Quasar
 * development donation. Absent or invalid metadata grants no authority. */
struct QQDevelopmentDonationConsent
{
    static constexpr uint32_t VERSION{1};

    uint32_t version{VERSION};
    uint8_t choice_recorded{0};
    uint32_t percentage{DEFAULT_QQ_DEVELOPMENT_DONATION_PERCENTAGE};
    std::string network;
    std::string recipient;

    SERIALIZE_METHODS(QQDevelopmentDonationConsent, obj)
    {
        READWRITE(obj.version, obj.choice_recorded, obj.percentage,
                  obj.network, obj.recipient);
    }

    bool HasDonationAuthority() const
    {
        return choice_recorded == 1 && percentage > 0;
    }

    bool operator==(const QQDevelopmentDonationConsent& other) const
    {
        return version == other.version &&
               choice_recorded == other.choice_recorded &&
               percentage == other.percentage &&
               network == other.network &&
               recipient == other.recipient;
    }
};

inline QQDevelopmentDonationConsent DefaultQQDevelopmentDonationConsent()
{
    return {};
}

inline bool ValidateQQDevelopmentDonationConsent(
    const QQDevelopmentDonationConsent& consent, std::string* error = nullptr)
{
    const auto fail = [&](const char* message) {
        if (error) *error = message;
        return false;
    };
    if (consent.version != QQDevelopmentDonationConsent::VERSION) {
        return fail("unsupported consent version");
    }
    if (consent.choice_recorded > 1) {
        return fail("choice flag is not a canonical boolean");
    }
    if (consent.percentage > MAX_QQ_DEVELOPMENT_DONATION_PERCENTAGE) {
        return fail("percentage is outside the permitted range");
    }
    if (consent.choice_recorded == 0) {
        if (consent.percentage != 0 || !consent.network.empty() || !consent.recipient.empty()) {
            return fail("an unrecorded choice must not contain donation authority");
        }
        return true;
    }
    if (consent.network.empty() || consent.recipient.empty()) {
        return fail("a recorded choice must bind the network and recipient");
    }
    return true;
}

} // namespace wallet

#endif // BITCOIN_WALLET_QQ_DEVELOPMENT_DONATION_H
