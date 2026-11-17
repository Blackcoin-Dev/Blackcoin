// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/txvaluemap.h>

#include <cassert>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <vector>

namespace wallet {
namespace {

// Keys stored as a one-byte id. The ids exist only in memory, so entries may
// be added here freely; the table must stay sorted bytewise and hold at most
// 255 keys. A key that is not listed costs its length, nothing else.
constexpr std::string_view KNOWN_KEYS[]{
    "comment",
    "from",
    "message",
    "qq_auto_shadow_stale",
    "qq_manual_shadow_abandon",
    "qq_reorg_shadow_resubmit",
    "qq_shadow_pow_adopted",
    "qq_shadow_pow_adoption_fingerprint",
    "qq_shadow_pow_adoption_tip",
    "qq_shadow_pow_authored",
    "qq_shadow_pow_branch_quarantine_height",
    "qq_shadow_pow_branch_quarantine_tip",
    "qq_shadow_pow_claim_relay_birth",
    "qq_shadow_pow_claim_relay_clock_schema",
    "qq_shadow_pow_claim_relay_txid",
    "qq_shadow_pow_cleanup_for",
    "qq_shadow_pow_created_height",
    "qq_shadow_pow_created_tip",
    "qq_shadow_pow_first_quarantine_height",
    "qq_shadow_pow_first_quarantine_tip",
    "qq_shadow_pow_legacy_cleanup_quarantine",
    "qq_shadow_pow_lineage_family",
    "qq_shadow_pow_lineage_ordinal",
    "qq_shadow_pow_lineage_parent",
    "qq_shadow_pow_lineage_root",
    "qq_shadow_pow_lineage_schema",
    "qq_shadow_pow_quarantine",
    "qq_shadow_pow_resolution_anchor_txid",
    "qq_shadow_pow_resolution_anchor_vout",
    "qq_shadow_pow_resolution_auth_generation",
    "qq_shadow_pow_resolution_auth_height",
    "qq_shadow_pow_resolution_auth_origin",
    "qq_shadow_pow_resolution_auth_plan",
    "qq_shadow_pow_resolution_auth_schema",
    "qq_shadow_pow_resolution_auth_tip",
    "qq_shadow_pow_resolution_auth_wtxid",
    "qq_shadow_pow_resolution_created_height",
    "qq_shadow_pow_resolution_created_time",
    "qq_shadow_pow_resolution_fingerprint",
    "qq_shadow_pow_resolution_origin",
    "qq_shadow_pow_resolution_relay_authorized",
    "qq_shadow_pow_resolution_relay_revoked",
    "qq_shadow_pow_resolution_schema",
    "qq_shadow_signal_reorg_hash",
    "qq_shadow_signal_reorg_height",
    "qq_shadow_signal_source",
    "qq_synthetic_goldrush_payout",
    "qq_synthetic_goldrush_payout_stale",
    "qq_synthetic_goldrush_payout_stale_block",
    "qq_synthetic_goldrush_payout_stale_height",
    "replaced_by_txid",
    "replaces_txid",
    "to",
};
constexpr size_t KNOWN_KEY_COUNT{sizeof(KNOWN_KEYS) / sizeof(KNOWN_KEYS[0])};

constexpr uint8_t RAW_KEY{0xff};
constexpr uint8_t VALUE_RAW{0x00};
constexpr uint8_t VALUE_HEX256{0x01};
constexpr uint8_t VALUE_UINT{0x02};
constexpr size_t HEX256_BYTES{32};

// std::string orders by unsigned char; std::string_view::compare does too.
constexpr bool KnownKeysSortedUnique()
{
    for (size_t i{1}; i < KNOWN_KEY_COUNT; ++i) {
        if (KNOWN_KEYS[i - 1].compare(KNOWN_KEYS[i]) >= 0) return false;
    }
    return true;
}
static_assert(KnownKeysSortedUnique(), "KNOWN_KEYS must be sorted and unique");
static_assert(KNOWN_KEY_COUNT < RAW_KEY, "key ids must fit below the raw-key marker");

//! Table index of key, or RAW_KEY.
uint8_t KnownKeyId(std::string_view key)
{
    size_t lo{0};
    size_t hi{KNOWN_KEY_COUNT};
    while (lo < hi) {
        const size_t mid{lo + (hi - lo) / 2};
        const int order{KNOWN_KEYS[mid].compare(key)};
        if (order == 0) return static_cast<uint8_t>(mid);
        if (order < 0) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return RAW_KEY;
}

void PutVarInt(std::vector<unsigned char>& out, uint64_t value)
{
    while (value >= 0x80) {
        out.push_back(static_cast<unsigned char>(value) | 0x80);
        value >>= 7;
    }
    out.push_back(static_cast<unsigned char>(value));
}

uint64_t GetVarInt(const unsigned char* data, size_t& pos)
{
    uint64_t value{0};
    for (int shift{0};; shift += 7) {
        const unsigned char byte{data[pos++]};
        value |= static_cast<uint64_t>(byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return value;
    }
}

int LowerHexDigit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

//! True, with the 32 bytes appended to out, iff value is exactly 64 characters of [0-9a-f].
bool PackHex256(std::string_view value, std::vector<unsigned char>& out)
{
    if (value.size() != HEX256_BYTES * 2) return false;
    for (const char c : value) {
        if (LowerHexDigit(c) < 0) return false;
    }
    for (size_t i{0}; i < HEX256_BYTES; ++i) {
        out.push_back(static_cast<unsigned char>((LowerHexDigit(value[2 * i]) << 4) | LowerHexDigit(value[2 * i + 1])));
    }
    return true;
}

void UnpackHex256(const unsigned char* bytes, std::string& out)
{
    static constexpr char DIGITS[]{"0123456789abcdef"};
    out.resize(HEX256_BYTES * 2);
    for (size_t i{0}; i < HEX256_BYTES; ++i) {
        out[2 * i] = DIGITS[bytes[i] >> 4];
        out[2 * i + 1] = DIGITS[bytes[i] & 0x0f];
    }
}

//! True iff value is the decimal text ToString(uint64_t) prints for some number, which is returned in parsed.
bool ParseCanonicalUInt(std::string_view value, uint64_t& parsed)
{
    if (value.empty() || value.size() > 20) return false;
    if (value.size() > 1 && value[0] == '0') return false;
    uint64_t result{0};
    for (const char c : value) {
        if (c < '0' || c > '9') return false;
        const uint64_t digit{static_cast<uint64_t>(c - '0')};
        if (result > (std::numeric_limits<uint64_t>::max() - digit) / 10) return false;
        result = result * 10 + digit;
    }
    parsed = result;
    return true;
}

void UnpackUInt(uint64_t value, std::string& out)
{
    char buffer[20];
    size_t pos{sizeof(buffer)};
    do {
        buffer[--pos] = static_cast<char>('0' + value % 10);
        value /= 10;
    } while (value != 0);
    out.assign(buffer + pos, sizeof(buffer) - pos);
}

void EncodeEntry(std::string_view key, std::string_view value, std::vector<unsigned char>& out)
{
    const uint8_t id{KnownKeyId(key)};
    out.push_back(id);
    if (id == RAW_KEY) {
        PutVarInt(out, key.size());
        out.insert(out.end(), key.begin(), key.end());
    }
    uint64_t number{0};
    const size_t tag_pos{out.size()};
    out.push_back(VALUE_HEX256);
    if (PackHex256(value, out)) return;
    if (ParseCanonicalUInt(value, number)) {
        out[tag_pos] = VALUE_UINT;
        PutVarInt(out, number);
        return;
    }
    out[tag_pos] = VALUE_RAW;
    PutVarInt(out, value.size());
    out.insert(out.end(), value.begin(), value.end());
}

uint32_t ReadSize(const unsigned char* data)
{
    uint32_t size;
    std::memcpy(&size, data, sizeof(size));
    return size;
}

//! One entry as it lies in the block. Views point into the block or the key table.
struct EntryView {
    uint8_t key_id;
    std::string_view key;
    uint8_t value_tag;
    const unsigned char* value_bytes; //!< raw bytes, or the 32 packed bytes
    uint64_t value_number;            //!< raw length, or the packed number
    size_t next;                      //!< payload offset of the following entry
};

//! Parse the entry at payload offset pos. base points at the payload (past the size header).
EntryView ReadEntry(const unsigned char* base, size_t pos)
{
    EntryView entry;
    entry.key_id = base[pos++];
    if (entry.key_id == RAW_KEY) {
        const uint64_t length{GetVarInt(base, pos)};
        entry.key = std::string_view{reinterpret_cast<const char*>(base + pos), static_cast<size_t>(length)};
        pos += length;
    } else {
        assert(entry.key_id < KNOWN_KEY_COUNT);
        entry.key = KNOWN_KEYS[entry.key_id];
    }
    entry.value_tag = base[pos++];
    entry.value_bytes = nullptr;
    entry.value_number = 0;
    switch (entry.value_tag) {
    case VALUE_RAW:
        entry.value_number = GetVarInt(base, pos);
        entry.value_bytes = base + pos;
        pos += entry.value_number;
        break;
    case VALUE_HEX256:
        entry.value_bytes = base + pos;
        pos += HEX256_BYTES;
        break;
    case VALUE_UINT:
        entry.value_number = GetVarInt(base, pos);
        break;
    default:
        assert(false);
    }
    entry.next = pos;
    return entry;
}

void DecodeValue(const EntryView& entry, std::string& out)
{
    switch (entry.value_tag) {
    case VALUE_RAW:
        out.assign(reinterpret_cast<const char*>(entry.value_bytes), static_cast<size_t>(entry.value_number));
        break;
    case VALUE_HEX256:
        UnpackHex256(entry.value_bytes, out);
        break;
    default:
        UnpackUInt(entry.value_number, out);
        break;
    }
}

} // namespace

size_t WalletTxValueMap::KnownKeyCount() { return KNOWN_KEY_COUNT; }
std::string_view WalletTxValueMap::KnownKey(size_t id) { assert(id < KNOWN_KEY_COUNT); return KNOWN_KEYS[id]; }

size_t WalletTxValueMap::PayloadSize() const
{
    return m_data ? ReadSize(m_data.get()) : 0;
}

WalletTxValueMap::WalletTxValueMap(const WalletTxValueMap& other)
{
    *this = other;
}

WalletTxValueMap& WalletTxValueMap::operator=(const WalletTxValueMap& other)
{
    if (this == &other) return *this;
    if (!other.m_data) {
        m_data.reset();
        return *this;
    }
    const size_t bytes{HEADER_SIZE + other.PayloadSize()};
    std::unique_ptr<unsigned char[]> copy{new unsigned char[bytes]};
    std::memcpy(copy.get(), other.m_data.get(), bytes);
    m_data = std::move(copy);
    return *this;
}

void WalletTxValueMap::Assign(const mapValue_t& values)
{
    if (values.empty()) {
        m_data.reset();
        return;
    }
    std::vector<unsigned char> payload;
    payload.reserve(256);
    for (const auto& [key, value] : values) {
        EncodeEntry(key, value, payload);
    }
    if (payload.size() > std::numeric_limits<uint32_t>::max()) {
        throw std::length_error("wallet transaction value map too large");
    }
    const uint32_t size{static_cast<uint32_t>(payload.size())};
    std::unique_ptr<unsigned char[]> data{new unsigned char[HEADER_SIZE + payload.size()]};
    std::memcpy(data.get(), &size, sizeof(size));
    std::memcpy(data.get() + HEADER_SIZE, payload.data(), payload.size());
    m_data = std::move(data);
}

mapValue_t WalletTxValueMap::ToMap() const
{
    mapValue_t result;
    for (auto it = begin(); it != end(); ++it) {
        // Entries are stored in key order, so each one belongs at the end.
        result.emplace_hint(result.end(), it->first, it->second);
    }
    return result;
}

size_t WalletTxValueMap::size() const
{
    if (!m_data) return 0;
    const unsigned char* base{m_data.get() + HEADER_SIZE};
    const size_t payload{PayloadSize()};
    size_t entries{0};
    for (size_t pos{0}; pos < payload; pos = ReadEntry(base, pos).next) ++entries;
    return entries;
}

WalletTxValueMap::const_iterator& WalletTxValueMap::const_iterator::operator++()
{
    m_pos = ReadEntry(m_data + HEADER_SIZE, m_pos).next;
    m_decoded = false;
    return *this;
}

const WalletTxValueMap::value_type& WalletTxValueMap::const_iterator::Decoded() const
{
    if (!m_decoded) {
        const EntryView entry{ReadEntry(m_data + HEADER_SIZE, m_pos)};
        m_value.first.assign(entry.key.data(), entry.key.size());
        DecodeValue(entry, m_value.second);
        m_decoded = true;
    }
    return m_value;
}

WalletTxValueMap::const_iterator WalletTxValueMap::find(std::string_view key) const
{
    if (!m_data) return end();
    const unsigned char* base{m_data.get() + HEADER_SIZE};
    const size_t payload{PayloadSize()};
    const uint8_t id{KnownKeyId(key)};
    for (size_t pos{0}; pos < payload;) {
        const EntryView entry{ReadEntry(base, pos)};
        if (entry.key_id == id && (id != RAW_KEY || entry.key == key)) return {m_data.get(), pos};
        pos = entry.next;
    }
    return end();
}

WalletTxValueMap::const_iterator WalletTxValueMap::lower_bound(std::string_view key) const
{
    if (!m_data) return end();
    const unsigned char* base{m_data.get() + HEADER_SIZE};
    const size_t payload{PayloadSize()};
    for (size_t pos{0}; pos < payload;) {
        const EntryView entry{ReadEntry(base, pos)};
        if (entry.key.compare(key) >= 0) return {m_data.get(), pos};
        pos = entry.next;
    }
    return end();
}

std::optional<std::string> WalletTxValueMap::Get(std::string_view key) const
{
    const const_iterator it{find(key)};
    if (it == end()) return std::nullopt;
    return it->second;
}

std::string WalletTxValueMap::at(std::string_view key) const
{
    const const_iterator it{find(key)};
    if (it == end()) throw std::out_of_range("WalletTxValueMap::at: key not found");
    return it->second;
}

void WalletTxValueMap::Set(std::string_view key, std::string_view value)
{
    mapValue_t values{ToMap()};
    values.insert_or_assign(std::string{key}, std::string{value});
    Assign(values);
}

bool WalletTxValueMap::emplace(std::string_view key, std::string_view value)
{
    if (find(key) != end()) return false;
    Set(key, value);
    return true;
}

WalletTxValueMap::ValueRef WalletTxValueMap::operator[](std::string_view key)
{
    if (find(key) == end()) Set(key, {});
    return ValueRef{*this, key};
}

size_t WalletTxValueMap::erase(std::string_view key)
{
    if (find(key) == end()) return 0;
    mapValue_t values{ToMap()};
    values.erase(std::string{key});
    Assign(values);
    return 1;
}

WalletTxValueMap::const_iterator WalletTxValueMap::erase(const const_iterator& pos)
{
    assert(pos.m_data == m_data.get() && pos != end());
    const std::string key{pos->first};
    const_iterator following{pos};
    ++following;
    const std::optional<std::string> next_key{following == end() ? std::nullopt : std::make_optional(following->first)};
    erase(std::string_view{key});
    return next_key ? find(*next_key) : end();
}

bool operator==(const WalletTxValueMap& a, const WalletTxValueMap& b)
{
    // The encoding is a function of the logical map, so equal maps have equal blocks.
    const size_t size{a.PayloadSize()};
    if (size != b.PayloadSize()) return false;
    return size == 0 || std::memcmp(a.m_data.get(), b.m_data.get(), WalletTxValueMap::HEADER_SIZE + size) == 0;
}

} // namespace wallet
