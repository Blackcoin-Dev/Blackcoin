// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_TEST_UTIL_ALLOCATOR_STATISTICS_H
#define BITCOIN_TEST_UTIL_ALLOCATOR_STATISTICS_H

#ifndef __has_feature
#define __has_feature(x) 0
#endif

/**
 * Whether the allocator's own statistics (malloc_zone_statistics on macOS) describe the native heap.
 * AddressSanitizer and ThreadSanitizer replace the allocator: AddressSanitizer reports accumulated
 * allocations without subtracting frees, and ThreadSanitizer reports nothing, so a threshold on the
 * measured bytes or blocks says nothing about the code under test there. A test that measures the
 * heap keeps every functional, serialization and representation check running and asserts the
 * measured thresholds only when this is true.
 */
#if __has_feature(address_sanitizer) || __has_feature(thread_sanitizer) || defined(__SANITIZE_ADDRESS__) || defined(__SANITIZE_THREAD__)
inline constexpr bool NATIVE_ALLOCATOR_STATISTICS{false};
#else
inline constexpr bool NATIVE_ALLOCATOR_STATISTICS{true};
#endif

#endif // BITCOIN_TEST_UTIL_ALLOCATOR_STATISTICS_H
