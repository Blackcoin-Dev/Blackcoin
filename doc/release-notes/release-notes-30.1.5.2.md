# Blackcoin Core 30.1.5.2rc1 (unreleased candidate)

This candidate contains two wallet repairs and clearer GUI, RPC help, and
operator documentation. It is configured with `CLIENT_VERSION_IS_RELEASE=false`.

## Wallet repairs

- **PoW claim-input capacity:** the wallet charges claim-input and related
  script-manager work to the legacy source subset. Accumulated reward outputs
  no longer exhaust those budgets. Eligibility, byte, stake-reserve, active-tip,
  and final selection checks remain enforced. The
  `getpowmininginfo.claim_input_enumeration` result reports scan counts and the
  first failed check.
- **SQLite batch ownership:** an explicit transaction holds the SQLite connection
  lock for its owning batch. Other batches cannot join that transaction. A
  failed rollback blocks further database access until the wallet is reloaded.

## Interface and documentation

Wallet help explains staking, claim recovery, fees, and unlock choices in
shorter language. Existing settings and permission requirements are unchanged.

## Compatibility

The candidate version is `30.1.5.2rc1`. Candidate packages use a
`30.1.5.2-alpha1` or `30.1.5.2-beta1` label and identify their source commit.
The numeric `CLIENT_VERSION` remains `300105`. macOS uses short version
`30.1.5`, bundle version `30.1.502`, and `BlackcoinFullVersion=30.1.5.2`.

This candidate preserves consensus and reward rules, activation heights,
network protocol, wallet storage format, and chainstate format. Back up wallets before
upgrading. This maintenance revision requires no reindex or wallet recreation.

## Release status

Release qualification is pending. Required tests, source signing, reproducible
builds, and publication controls are listed in the [release process](../release-process.md).
Windows packages remain without Authenticode signatures. macOS applications
use ad-hoc signatures and are not Developer-ID signed or notarized.
