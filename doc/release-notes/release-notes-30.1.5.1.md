# Blackcoin Core 30.1.5.1

Blackcoin Core 30.1.5.1 is a wallet-capacity maintenance correction for v30.1.5.
The source commit and annotated tag are SSH-signed by Blackcoin-Dev. Windows
packages remain without Authenticode signatures; macOS applications carry only
ad-hoc signatures and are not notarized.

## Corrected wallet capacity accounting

- **#54 — complete retained claim histories:** the finite inventory topology
  work ceiling increases from 4,096 to 16,384 units. Independent claim-index,
  ownership-slice, script-manager, record-byte, aggregate-byte and metadata
  bounds remain enforced. No history is discarded or treated as resolved merely
  to fit a budget. An incomplete inventory still withholds action authority.
- **#55 — referenced confirmed-parent output:** ancestry traversal charges the
  work and serialized bytes of the output actually read at a confirmed boundary,
  before ownership checks and script copying. Inactive ancestors and graph nodes
  still incur complete transaction accounting. A reorg does not inherit the
  confirmed-boundary shortcut.
- **#56 — wallet-wide source selection:** the complete wallet-only scan has
  independent bounds of 65,536 live outputs, 131,072 source/spender work units,
  and 4,194,304 script-manager work units. These are independent maxima, not a
  promise that every combination fits: manager, byte, protected-asset and other
  bounds can refuse a scan earlier. Refusal clears partial selection authority.

These changes prevent avoidable capacity refusals from masking valid claim
creation, exact relay, same-anchor refresh, or normal waiting for a live claim.
They do not make a capacity limit an earnings limit or guarantee unlimited wallet
growth. Mature legacy stake reserve, confirmed-input selection, wallet-generation
and active-tip revalidation, existing coin locks, and default-off recovery
spending authority are preserved.

## Version and compatibility

The displayed and packaged release is `30.1.5.1`.
The numeric `CLIENT_VERSION` remains `300105`, preserving the existing wallet
database version interpretation.
Peer subversion and Windows resources include revision 1. For Apple's numeric
bundle constraints, macOS uses short version `30.1.5`, bundle version `30.1.501`,
and `BlackcoinFullVersion=30.1.5.1`.

This release does not change consensus, network protocol version, reward rules,
proof validity, activation heights, wallet storage format, or chainstate format.
Existing v30.1.5 behavior outside the scoped wallet corrections remains.
Back up wallets and datadirs before upgrading. This release does not require a
data rewind, wallet recreation, or reindex solely because of the version change.
Do not substitute these packages into an older immutable release.

## Validation and publication

Generic synthetic fixtures cover large live-output sets, complete branching
claim histories, confirmed versus inactive ancestry, referenced-script byte
bounds, exact topology-capacity acceptance and overflow refusal, mature stake
reserve, and create/relay/refresh/live-wait gating. They contain no deployment
topology, node identities, addresses, private paths, or operator adapters.

Release publication still requires the exact-SHA signed-source, hosted CI,
sanitizer, native-platform, package, two-builder reproducibility, attestation,
and immutable-publication gates. Earlier local tests are supporting evidence,
not a substitute for public-release qualification. Private deployment results
and operational workarounds are not public Core requirements.

The publisher validates a fresh signed immutable-configuration receipt, detects
existing drafts through authenticated release inventory, and uses the numeric
release ID for draft verification and final publication. It does not recreate a
release or repeat successful uploads to recover a lookup failure.
