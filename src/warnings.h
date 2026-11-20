// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2021 Blackcoin Core Developers
// Copyright (c) 2009-2021 Blackcoin More Developers
// Copyright (c) 2009-2021 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WARNINGS_H
#define BITCOIN_WARNINGS_H

#include <string>

struct bilingual_str;

void SetMiscWarning(const bilingual_str& warning);
/** Set an independent operational resource warning without overwriting clock,
 * disk, or other miscellaneous warnings. Returns true when the value changed. */
bool SetShadowResourceWarning(const bilingual_str& warning);
/** Set the sticky warning raised when the background wallet integrity check
 * finds damage. It has its own slot so it never overwrites, or is erased by,
 * the clock or disk warnings. An empty string clears it. */
void SetWalletIntegrityWarning(const bilingual_str& warning);
void SetfLargeWorkInvalidChainFound(bool flag);
/** Format a string that describes several potential problems detected by the core.
 * @param[in] verbose bool
 * - if true, get all warnings separated by <hr />
 * - if false, get the most important warning
 * @returns the warning string
 */
bilingual_str GetWarnings(bool verbose);

#endif // BITCOIN_WARNINGS_H
