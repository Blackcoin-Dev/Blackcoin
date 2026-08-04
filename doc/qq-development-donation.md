# Quantum Quasar development donation

Blackcoin Core v30.1.4 permanently retires the legacy development-fund
recipient and payment path. `-donatetodevfund` is retained only as a
compatibility option: zero is harmless, and a historical nonzero value is
ignored with a prominent startup warning. `getstakingdonationinfo` reports the
retired state, and `setstakingdonation` accepts only zero.

The replacement is a separate optional wallet policy. It is not a consensus
tax, does not change the PoS subsidy, and is off by default in every wallet.
No legacy configuration, GUI setting, or percentage is migrated.

## Mainnet recipient

- Address: `blk1szuc2u0wfdnluf2m7m4smw68uzy42hjtmy27aywklqgx55w5erwqslnfs8h`
- Witness version: `16`
- Witness program: `1730ae3dc96cffc4ab7edd61b768fc112aabc97b22bdd23adf020d4a3a991b81`
- Type: direct quantum migration output (not legacy, tiered, or cold stake)
- Initial encrypted-wallet backup SHA256: `14efec03cb0bcc2dccdca19559a68ed602f461b2e4127fddce67dfab28c6cd46`

The checksum identifies the verified initial encrypted backup; it is not a
private key and cannot recover the wallet. Operational backup locations and
credentials are intentionally not part of the source tree.

## Consent and rotation

Use `getqqdevelopmentdonationinfo` to review the exact current network and
recipient. Record a choice with:

```
setqqdevelopmentdonation 5 "exact_recipient_from_getqqdevelopmentdonationinfo"
```

Use percentage zero with the same exact recipient to opt out. The choice is
stored durably in that wallet and binds the network, recipient, and percentage.
A future recipient change or cross-network wallet load makes an enabled record
ineffective and reports that reauthorization is required. Core never transfers
old consent to a replacement address.

For headless startup, the separate options are
`-qqdevelopmentdonation=<0..95>` and
`-qqdevelopmentdonationrecipient=<exact-address>`. They seed only a wallet with
no persisted choice. A persisted wallet choice always wins.

## Coinstake behavior

Core includes the optional output only when all of these conditions hold:

- the wallet has a durable, nonzero, exact-current consent;
- quantum outputs are active for the candidate block;
- the compiled recipient script is an ordinary direct witness-v16 quantum
  output; and
- the active coinstake format permits an extra wallet-policy output.

Exact participant/operator reward-split formats do not carry the optional
output. Any malformed consent, database-outcome ambiguity, network mismatch,
recipient rotation, premature quantum lifecycle, or invalid recipient disables
the donation without redirecting value elsewhere.
