// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_TXVALUEMAP_H
#define BITCOIN_WALLET_TXVALUEMAP_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace wallet {

typedef std::map<std::string, std::string> mapValue_t;

/**
 * Packed, memory-only form of CWalletTx::mapValue.
 *
 * Logically this is exactly a std::map<std::string, std::string>: the same
 * keys, the same values, the same (bytewise lexicographic) iteration order.
 * It is never serialized itself. CWalletTx converts it to a mapValue_t before
 * writing and from a mapValue_t after reading, so the wallet database format
 * is the one every earlier release reads and writes.
 *
 * Storage is one heap block per non-empty map (none for an empty map):
 *
 *     uint32 payload size, then one entry per pair in key order
 *     entry := key value
 *     key   := id byte (index into the table of well-known keys)
 *            | 0xff varint(length) bytes        (any other key, kept raw)
 *     value := 0x00 varint(length) bytes        (raw string)
 *            | 0x01 32 bytes                    (64 lower-case hex digits)
 *            | 0x02 varint(n)                   (canonical decimal uint64)
 *
 * Canonical form rule: a value is packed only when unpacking reproduces the
 * stored string byte for byte. That is decided from the value alone: exactly
 * 64 characters of [0-9a-f] pack as 32 bytes, and a decimal number that is
 * what ToString(uint64_t) prints (no sign, no leading zero, no whitespace,
 * fits 64 bits) packs as a varint. Every other value, and every key that is
 * not in the table (including keys written by a newer release), is kept as
 * its raw string. Nothing is normalised and nothing is dropped, so the
 * string a reader sees, and the bytes a rewrite produces, are always the
 * ones that were stored.
 *
 * A Gold Rush claim's metadata (about a dozen qq_shadow_pow_* pairs) takes
 * roughly 200 bytes in one allocation this way, against roughly 2 kB in 25
 * to 40 allocations as map nodes with out-of-line key and value strings.
 *
 * Differences from std::map that callers must respect:
 *  - iterators are read-only snapshots; any mutation of the map invalidates
 *    all of them (std::map keeps iterators to other elements valid);
 *  - an iterator caches the pair it decodes, so a reference obtained through
 *    it lives only as long as that iterator object;
 *  - at() returns the value by value.
 */
class WalletTxValueMap
{
public:
    using key_type = std::string;
    using mapped_type = std::string;
    using value_type = std::pair<std::string, std::string>;
    using size_type = size_t;

    class const_iterator
    {
    public:
        using iterator_category = std::forward_iterator_tag;
        using value_type = WalletTxValueMap::value_type;
        using difference_type = std::ptrdiff_t;
        using pointer = const value_type*;
        using reference = const value_type&;

        const_iterator() = default;
        reference operator*() const { return Decoded(); }
        pointer operator->() const { return &Decoded(); }
        const_iterator& operator++();
        const_iterator operator++(int) { const_iterator old{*this}; ++*this; return old; }
        friend bool operator==(const const_iterator& a, const const_iterator& b) { return a.m_data == b.m_data && a.m_pos == b.m_pos; }
        friend bool operator!=(const const_iterator& a, const const_iterator& b) { return !(a == b); }

    private:
        friend class WalletTxValueMap;
        const_iterator(const unsigned char* data, size_t pos) : m_data{data}, m_pos{pos} {}
        const value_type& Decoded() const;

        const unsigned char* m_data{nullptr};
        size_t m_pos{0};
        mutable bool m_decoded{false};
        mutable value_type m_value;
    };
    using iterator = const_iterator;

    //! Result of operator[]: assignable from, convertible to and comparable with a string.
    class ValueRef
    {
    public:
        ValueRef& operator=(std::string_view value) { m_map.Set(m_key, value); return *this; }
        ValueRef& operator=(const ValueRef& other) { return *this = std::string_view{other.str()}; }
        std::string str() const { return m_map.Get(m_key).value_or(std::string{}); }
        operator std::string() const { return str(); }
        friend bool operator==(const ValueRef& a, std::string_view b) { return a.str() == b; }
        friend bool operator!=(const ValueRef& a, std::string_view b) { return !(a == b); }
        friend bool operator==(std::string_view a, const ValueRef& b) { return b == a; }
        friend bool operator!=(std::string_view a, const ValueRef& b) { return !(b == a); }

    private:
        friend class WalletTxValueMap;
        ValueRef(WalletTxValueMap& map, std::string_view key) : m_map{map}, m_key{key} {}
        ValueRef(const ValueRef&) = default;
        WalletTxValueMap& m_map;
        std::string m_key;
    };

    WalletTxValueMap() noexcept = default;
    WalletTxValueMap(const WalletTxValueMap& other);
    WalletTxValueMap(WalletTxValueMap&& other) noexcept = default;
    WalletTxValueMap(const mapValue_t& values) { Assign(values); } // NOLINT(google-explicit-constructor)
    WalletTxValueMap& operator=(const WalletTxValueMap& other);
    WalletTxValueMap& operator=(WalletTxValueMap&& other) noexcept = default;
    WalletTxValueMap& operator=(const mapValue_t& values) { Assign(values); return *this; }
    //! Moving a std::map in leaves it empty, as moving it into a std::map did.
    WalletTxValueMap& operator=(mapValue_t&& values) { Assign(values); values.clear(); return *this; }

    //! The full logical map, as std::map. This is what is serialized and what RPC and GUI code is given.
    mapValue_t ToMap() const;
    explicit operator mapValue_t() const { return ToMap(); } // NOLINT(google-explicit-constructor)
    void Assign(const mapValue_t& values);

    bool empty() const noexcept { return !m_data; }
    size_t size() const;
    void clear() noexcept { m_data.reset(); }

    const_iterator begin() const { return {m_data.get(), 0}; }
    const_iterator end() const { return {m_data.get(), PayloadSize()}; }
    const_iterator find(std::string_view key) const;
    //! First entry whose key is not less than key.
    const_iterator lower_bound(std::string_view key) const;
    size_t count(std::string_view key) const { return find(key) == end() ? 0 : 1; }

    //! Value stored under key, or nullopt.
    std::optional<std::string> Get(std::string_view key) const;
    //! Like std::map::at, but returns a copy. Throws std::out_of_range.
    std::string at(std::string_view key) const;

    //! Insert or overwrite.
    void Set(std::string_view key, std::string_view value);
    //! Insert only when the key is absent, as std::map::emplace. Returns whether it inserted.
    bool emplace(std::string_view key, std::string_view value);
    //! As std::map::operator[]: inserts an empty value when the key is absent.
    ValueRef operator[](std::string_view key);
    size_t erase(std::string_view key);
    //! Erases the entry and returns an iterator to the one that followed it.
    const_iterator erase(const const_iterator& pos);

    friend bool operator==(const WalletTxValueMap& a, const WalletTxValueMap& b);
    friend bool operator!=(const WalletTxValueMap& a, const WalletTxValueMap& b) { return !(a == b); }
    friend bool operator==(const WalletTxValueMap& a, const mapValue_t& b) { return a.ToMap() == b; }
    friend bool operator!=(const WalletTxValueMap& a, const mapValue_t& b) { return !(a == b); }
    friend bool operator==(const mapValue_t& a, const WalletTxValueMap& b) { return b == a; }
    friend bool operator!=(const mapValue_t& a, const WalletTxValueMap& b) { return !(b == a); }

    //! Heap bytes requested for this map (0 when empty).
    size_t DynamicMemoryUsage() const { return m_data ? HEADER_SIZE + PayloadSize() : 0; }

    //! Number of keys stored as a one-byte id (for tests).
    static size_t KnownKeyCount();
    //! The id-th well-known key, in table (sorted) order (for tests).
    static std::string_view KnownKey(size_t id);

private:
    static constexpr size_t HEADER_SIZE{sizeof(uint32_t)};
    size_t PayloadSize() const;

    //! Null when the map is empty; otherwise a uint32 payload size followed by the payload.
    std::unique_ptr<unsigned char[]> m_data;
};

} // namespace wallet

#endif // BITCOIN_WALLET_TXVALUEMAP_H
