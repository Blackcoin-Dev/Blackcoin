// Copyright (c) 2026 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/quantumguides.h>

#include <QObject>

namespace {

QString CommonGuide()
{
    return QObject::tr(R"HTML(
<hr>
<h2>Core concepts used throughout this wallet</h2>
<p><b>Blackcoin V30</b> keeps the legacy chain usable while upgraded wallets track quantum-resistant state. Upgraded users can create quantum addresses, receive Gold Rush rewards, migrate funds, and prepare for quantum staking.</p>

<h3>There are two value families in the wallet</h3>
<ul>
<li><b>Legacy BLK</b> is controlled by the older Blackcoin address and signature system. These coins are still normal chain coins during the transition. Legacy staking continues to help secure the base network.</li>
<li><b>Quantum BLK</b> is controlled by ML-DSA witness programs. These addresses are intended for Gold Rush rewards, migrated balances, post-quantum sends, and quantum staking workflows.</li>
</ul>
<p>The wallet shows these balances separately: <b>legacy</b> uses the older signing path; <b>quantum</b> uses ML-DSA.</p>

<h3>Mainnet schedule</h3>
<p>Mainnet lifecycle boundaries are height-authoritative. Gold Rush is height 5,950,000 through 6,192,999. The emission-neutral competing-claim rule begins at height 5,993,200. Migration is height 6,193,000 through 6,921,999. Final Lockout and automatic demurrage begin at height 6,922,000. Nominal time forecasts and readiness signalling do not move these boundaries.</p>

<h3>Legacy-chain control transactions</h3>
<p>Gold Rush participation uses fee-paying control transactions on the legacy chain: QQSIGNAL for PoS and QQSPROOF for PoW. Legacy nodes carry the transactions; upgraded nodes credit the quantum rewards.</p>
<p>For example, a PoW miner finds a valid Argon2id proof. The wallet spends an eligible legacy UTXO in a transaction containing the proof and quantum payout address. A staker includes it in a block. Upgraded nodes credit the reward to that address; legacy nodes see a transaction with data.</p>

<h3>What confirmations mean in these screens</h3>
<ul>
<li><b>Unconfirmed</b> means the transaction is in the mempool or known locally but not yet in a block.</li>
<li><b>Confirmed</b> means the transaction is in the active chain. More confirmations reduce reorg risk.</li>
<li><b>Mature</b> means a newly staked or mined output has passed the chain's maturity rule and can be used by the wallet.</li>
</ul>
<p>Wait several confirmations before assessing a staking, mining, migration, or cold-staking setup. A displayed transaction may still be immature.</p>

<h3>Back up newly created quantum keys</h3>
<p>Every new quantum address, operator key, staking address, or delegation address is wallet-backed non-HD key material and is not derived from the wallet seed. Back up the wallet after creating those addresses. A backup from before a quantum key was created cannot recover the key needed to spend funds sent there.</p>

<h3>How to read transaction names</h3>
<ul>
<li><b>PoS - Quantum Stake</b> means a PoS quantum reward credit was accepted for a quantum payout address.</li>
<li><b>PoW - Quantum Claim</b> means a PoW quantum claim was accepted and credited to a quantum payout address.</li>
<li><b>PoW Claim</b> or <b>PoS Claim</b> is the control transaction and fee that anchored participation on the legacy-visible chain.</li>
</ul>
<p>A negative fee entry beside a quantum reward records the legacy-chain fee for anchoring participation. The reward is a separate quantum credit.</p>
)HTML");
}

QString PosGuide()
{
    return QObject::tr(R"HTML(
<h2>Detailed PoS Gold Rush example</h2>
<p>PoS Gold Rush eligibility depends on the wallet's aggregate controlled-address balance at the whitelist snapshot, not a single 10,000 BLK UTXO.</p>
<ol>
<li>A wallet controls one or more legacy addresses.</li>
<li>At the whitelist snapshot height, the wallet's controlled addresses are checked for aggregate balance.</li>
<li>If the aggregate balance is at least 10,000 BLK, that wallet target can qualify for PoS Gold Rush participation.</li>
<li>During Gold Rush, the wallet still has to actively stake and solve PoS blocks.</li>
<li>When it has a recent qualifying solve, the wallet must be normally unlocked and the user must explicitly enable automatic QQSIGNAL submission (or submit the signal manually through RPC).</li>
</ol>
<p><b>Example A:</b> a wallet held 6,000 BLK at one address and 4,500 BLK at another controlled address at the snapshot. The aggregate is 10,500 BLK, so it can qualify.</p>
<p><b>Example B:</b> a wallet held 9,999.999 BLK at the snapshot. It is below the threshold and must not receive PoS Gold Rush rewards from that snapshot.</p>
<p><b>Example C:</b> a wallet receives 20,000 BLK after the snapshot. That may help ordinary staking, but it does not retroactively make the wallet whitelisted for the snapshot-based PoS Gold Rush share.</p>

<h3>Why a normal unlock is needed for PoS Gold Rush</h3>
<p>Legacy staking-only unlock permits ordinary legacy coinstakes without enabling spending. A Gold Rush signal is a separate wallet-authenticated control transaction linking qualifying activity to a quantum payout address. It requires normal signing authority.</p>

<h3>Where PoS rewards go</h3>
<p>Ordinary staking rewards follow the usual legacy staking path. Gold Rush reward credits go to a quantum payout address. In the transaction list, the upgraded credit should be labeled <b>PoS - Quantum Stake</b> and should show the quantum destination so the user can tell which address received the reward.</p>

<h3>What to do if you expected a PoS reward but do not see one</h3>
<ul>
<li>Confirm the current block height is inside the Gold Rush reward window.</li>
<li>Confirm the wallet had at least 10,000 BLK aggregate balance at the whitelist snapshot height.</li>
<li>Confirm the wallet solved a PoS block inside the rolling activity window.</li>
<li>Confirm the wallet was normally unlocked, not only legacy staking-only unlocked, when the signal needed to be created.</li>
<li>Confirm automatic QQSIGNAL was explicitly enabled, or submit the signal manually with the wallet RPC. Enabling ordinary staking alone does not grant this transaction consent.</li>
<li>Check the Transactions and Account tabs for the quantum payout address and credit.</li>
</ul>
)HTML");
}

QString PowGuide()
{
    return QObject::tr(R"HTML(
<h2>Detailed PoW Gold Rush example</h2>
<p>Gold Rush PoW does not create a separate chain. Its claims are included in ordinary PoS blocks. Holders can compete for PoW rewards without the 10,000 BLK PoS whitelist balance.</p>
<ol>
<li>When mining starts or prepares future new-anchor work, the wallet binds or reuses a wallet-backed quantum payout address. If none exists, the GUI asks before creating a non-HD key; RPC callers must pass explicit one-call key-creation consent.</li>
<li>A retained claim family preserves its already-authenticated payout. Waiting, relaying, or same-anchor refresh does not allocate an unrelated future-new-anchor key.</li>
<li>The built-in miner searches for an Argon2id proof that meets the current target.</li>
<li>When it finds a proof, the wallet creates a QQSPROOF transaction.</li>
<li>The QQSPROOF transaction pays a legacy-chain fee.</li>
<li>A staker includes the claim in a PoS block.</li>
<li>Upgraded nodes credit the PoW Gold Rush reward to the authenticated quantum payout carried by that claim.</li>
</ol>
<p><b>CPU example:</b> 1 worker at a 1 percent target duty cycle requests less CPU time than 4 workers at 50 percent each. More CPU time may increase proof attempts, heat, fan activity, and battery use. Actual responsiveness depends on the host.</p>
<p><b>Fee input:</b> each QQSPROOF claim pays a legacy transaction fee and needs an eligible legacy UTXO as its fee input.</p>

<h3>Quarantined-claim recovery is an advanced, explicit action</h3>
<p>A peer may retain and confirm a claim after it leaves this node's mempool. The wallet reserves that claim's input and pauses new claims instead of abandoning it on a timer. Waiting for on-chain resolution is the default.</p>
<p>If the claim remains unresolved, open <b>Staking &amp; Mining</b> and select <b>Review claim recovery...</b>. Core shows the immutable claim graph and a recovery plan bound to the current chain tip. Before you can acknowledge the plan, the screen shows the total fee, maximum fee per resolution, batch fee cap, and any legacy QQP2 revalidation risk. <b>Wait / take no action</b> is the default. Resolve requires your authorization of that exact plan. After a temporary normal unlock, Core rechecks the plan, persists the recovery, and handles relay without a separate broadcast command.</p>
<p>The debug-console recovery RPC enforces the same plan binding, fee caps, conflict-risk acknowledgement, and unlock rules. A confirmed conflict pays the displayed base-chain fee without a shadow reimbursement. Confirmation is not guaranteed. Never use generic abandonment to release this input.</p>

<h3>Why the payout must be a quantum address</h3>
<p>PoW Gold Rush rewards are credited only to the claim's authenticated quantum payout address; a legacy address is not eligible. The wallet binds the payout before submitting a claim.</p>
<p>New-anchor payout keys are non-HD. The miner never creates one without explicit consent. Rejecting the prompt or omitting the RPC consent flag causes that start or new-anchor allocation to fail without creating a key; it does not alter a retained family's authenticated payout. If a new payout key is created, back up the wallet immediately.</p>

<h3>When PoW rewards become spendable</h3>
<p>A Gold Rush reward remains locked until Gold Rush ends and must satisfy normal maturity. It then becomes an ordinary direct quantum output at the original payout address. Moving it to a fresh address is optional consolidation or key rotation, not a prerequisite for sends, cold-stake delegation, or node bonding.</p>
)HTML");
}

QString UnlockGuide()
{
    return QObject::tr(R"HTML(
<h2>Unlock modes in practical terms</h2>
<p><b>Locked</b> means the wallet cannot sign transactions. It can display balances and receive funds, but it cannot stake or create claim/migration transactions.</p>
<p><b>Legacy staking-only unlock</b> permits ordinary PoS staking without general spending authority. It does not sign quantum migration, PoW claim, PoS signal, cold-stake setup, or RGB transactions. EUTXO v15 has no enabled signing path in v30.1.1.</p>
<p><b>Quantum and Legacy Staking unlock</b> is a normal unlock. Use it when the wallet needs to sign active transition transactions. This includes Gold Rush PoS signal publication, PoW claim submission, optional reward consolidation, migration, cold-stake delegation, node bonding, and demurrage attestations.</p>
<p><b>Rule:</b> creating a wallet-backed quantum key or signing a claim, migration, quantum spend, delegation, bond, or attestation requires a normal unlock. Viewing balances and receiving funds do not require an unlock.</p>
)HTML");
}

QString ColdStakeGuide()
{
    return QObject::tr(R"HTML(
<h2>Cold staking, local staking, and running a node</h2>
<p>Cold staking separates <b>ownership</b> from <b>staking operation</b>. The owner key controls the principal. The staker/node key helps produce blocks. A valid cold-stake delegation grants staking authority without granting owner-spend authority.</p>

<h3>Three user roles</h3>
<ul>
<li><b>Stake your own coins:</b> one wallet owns and stakes its own quantum coins while the node stays online.</li>
<li><b>Run a node:</b> this wallet creates a fixed 30-day node bond and publishes a staking public key. Delegators can select it after confirmations and registry discovery.</li>
<li><b>Delegate coins:</b> the owner wallet selects a verified node, creates a cold-stake delegation address, and funds it. The owner retains spend authority.</li>
</ul>

<h3>Run a staking node</h3>
<p>To operate a staking node, open Cold Staking, create a node key, fund the fixed 30-day bond, wait for normal confirmations and registry discovery, and keep the node online. Delegators can then select the verified node from the list instead of entering a raw key.</p>

<h3>Delegate to a node</h3>
<p>To delegate, select a verified node from the list, create a delegation deposit address, choose an amount, and click Delegate coins. The wallet signs a transaction that sends the selected quantum value into the cold-stake contract. The selected node can stake after confirmation; the owner wallet retains spend authority.</p>

<h3>Automatic redelegation is conditional</h3>
<p>When automatic mode is enabled, a normally unlocked private-key owner wallet can move a safe, owner-spendable delegation only after its operator has no observed wins for 6 x the expected interval, clamped to 300-4,050 blocks. A 1,350-block activation probation, attempt and success rate limits, and up to 1,350 blocks of deterministic jitter also apply. The wallet requires a meaningfully better verified target.</p>
<p>An over-cap current pool does not trigger redelegation. Over-cap targets are excluded when an under-cap alternative exists; if every verified candidate is over the cap, the bootstrap fallback can still select one. A missing target or transaction failure leaves the delegation unchanged.</p>

<h3>Stop a delegation</h3>
<p>To stop a delegation, owner-spend the selected output to a fresh wallet-backed quantum address when it is spendable. If a bonded output is still in its unbonding period, the wallet shows its unlock height.</p>

<h3>Gold Rush reward handling inside cold staking</h3>
<p>Gold Rush reward outputs remain locked until Gold Rush ends. After normal maturity and the Gold Rush boundary, they are ordinary direct quantum funds and may be delegated without a required preliminary move. Optional consolidation into a fresh wallet-backed address remains available for organization or key rotation.</p>
)HTML");
}

QString MigrationGuide()
{
    return QObject::tr(R"HTML(
<h2>Migration and final lockout</h2>
<p>Migration moves control from legacy spend paths to quantum-resistant witness programs. During the transition, upgraded wallets track both legacy ledger activity and quantum state.</p>
<p><b>Legacy left</b> means value is still controlled by old signatures. <b>Quantum held</b> means value is already controlled by quantum keys. <b>Gold Rush locked</b> means reward outputs are recorded but cannot be spent until Gold Rush has ended and normal maturity is satisfied.</p>
<p>During Gold Rush, create and back up quantum addresses or use dry-run planning only. Ordinary v14/v16 funding and spending begin at Migration height 6,193,000. Final Lockout and automatic demurrage begin at height 6,922,000.</p>

<h3>Simple migration example</h3>
<ol>
<li>A wallet has 50,000 legacy BLK.</li>
<li>During Migration, click Move legacy to quantum.</li>
<li>The wallet creates a fresh non-HD quantum key and broadcasts a transaction moving the spendable legacy value to its address.</li>
<li>Back up the wallet immediately when it reports the new key, including if transaction construction or broadcast fails after key creation.</li>
<li>After confirmation, the Account tab shows that value under the quantum address.</li>
</ol>

<h3>Gold Rush reward example</h3>
<ol>
<li>The wallet receives a PoW or PoS Gold Rush quantum reward.</li>
<li>The transaction list labels it as <b>PoW - Quantum Claim</b> or <b>PoS - Quantum Stake</b>.</li>
<li>The reward remains locked throughout Gold Rush and must also satisfy normal maturity.</li>
<li>After Gold Rush, the same output is an ordinary direct quantum UTXO. No remigration or fresh-address move is required before a send, local stake, node bond, or delegation.</li>
</ol>
)HTML");
}

QString DemurrageGuide()
{
    return QObject::tr(R"HTML(
<h2>Demurrage and liveness attestations</h2>
<p>Demurrage is an inactivity rule for eligible direct, tiered, and cold-stake quantum outputs. It is inactive throughout Gold Rush and Migration, then activates automatically with Final Lockout at height 6,922,000.</p>
<p>A liveness attestation is a fee-paying transaction that proves the controlling quantum key is still actively managed. The wallet can create attestations only for eligible wallet-backed direct or tiered v16 addresses. A cold-stake output cannot be attested.</p>
<p>Automatic wallet attestations are optional and off by default. Enabling or disabling that local automation does not enable, delay, or disable consensus demurrage or the permanent burn.</p>
<p><b>Example:</b> for an eligible direct quantum output that has not moved for many months, the wallet can send an attestation before it begins to lose effective value. Automatic attempts require staking to be enabled, a normally unlocked private-key wallet, a safe spendable fee input, and available attestation capacity. Construction or broadcast failure can defer an attempt. Merely leaving the wallet online does not guarantee an attestation.</p>
<p>Cold-stake delegation alone is not exempt; a successful coinstake spends and recreates the output and refreshes its activity. The Account tab shows whether outputs are decaying, locked, or protected by a recent qualifying attestation. Mainnet configures no exempt scripts. Any nominal-minus-effective principal realized by a spend is permanently burned and is never paid to a miner, staker, treasury, reward pool, or claim participant.</p>
)HTML");
}

QString AssetsGuide()
{
    return QObject::tr(R"HTML(
<h2>RGB and EUTXO state</h2>
<p>The wallet displays known RGB assets and EUTXO metadata separately from BLK balances.</p>
<ul>
<li><b>RGB</b> tracks client-side asset contracts, assignments, and proofs. The wallet can show known assets, balances, contracts, and assignment counts.</li>
<li><b>EUTXO</b> tracks persisted metadata for the reserved witness-v15 datum/validator commitment shape.</li>
</ul>
<p><b>Important:</b> EUTXO v15 is frozen in v30.1.1 because it has no quantum ownership authorization. Funding and spending are disabled, creation RPCs intentionally fail, and the table is inspection-only. Do not send BLK to a v15 address. Seeing RGB state does not prove a transfer is complete; use the consignment verification and import RPCs described below.</p>
<p><b>Reading RGB entries:</b> an asset may show a balance, contract id, and assignments known to this wallet. This display alone does not prove a completed transfer. The console provides creatergbtransfer for creation, verifyrgbconsignment for validation, and acceptrgbconsignment for wallet import. Check the applicable RPC result and anchor confirmation before treating a transfer as complete.</p>
)HTML");
}

QString AccountSpecificGuide()
{
    return QObject::tr(R"HTML(
<h2>How to use the Account tab</h2>
<p>The Account tab groups wallet-controlled addresses, their balances and spend paths, and outputs that need attention.</p>
<h3>Reading the tree</h3>
<ul>
<li>Top-level rows are wallet addresses or script groups.</li>
<li>Child rows are individual UTXOs under that address.</li>
<li>The Type column tells you whether the output is legacy, direct quantum, cold-stake, EUTXO, or other.</li>
<li>The Amount column on an address row is the sum of its visible child outputs.</li>
<li>The Confirmations column is the lowest child depth for that address, so it is conservative.</li>
</ul>
<h3>Practical examples</h3>
<p><b>Finding spendable legacy BLK:</b> choose the Legacy filter. These are the coins the wallet can use for ordinary legacy sends, control transaction fees, and legacy staking.</p>
<p><b>Finding quantum reward coins:</b> choose the Quantum filter. During Gold Rush, reward outputs are phase-locked. After Gold Rush and maturity, the original outputs are ordinary direct quantum funds; optional consolidation is not a spendability requirement.</p>
<p><b>Checking cold-stake deposits:</b> choose Cold stake. Those rows represent funds in cold-staking contracts. They may be owner-spendable by this wallet, stakable by a selected node, or both, depending on the contract.</p>
<p><b>Auditing advanced assets:</b> use the RGB/EUTXO summary cards and filters to inspect wallet-known metadata. EUTXO v15 funding and spending are disabled in v30.1.1; an EUTXO row is a warning, not an available contract workflow.</p>
)HTML");
}

bool HasAny(const QString& title, std::initializer_list<const char*> needles)
{
    for (const char* needle : needles) {
        if (title.contains(QObject::tr(needle), Qt::CaseInsensitive) ||
            title.contains(QString::fromLatin1(needle), Qt::CaseInsensitive)) {
            return true;
        }
    }
    return false;
}

} // namespace

namespace QuantumGuides {

QString DetailedAppendixForTitle(const QString& title)
{
    QString html = CommonGuide();
    if (HasAny(title, {"Proof-of-Stake", "PoS", "Stake"})) html += PosGuide();
    if (HasAny(title, {"Proof-of-Work", "PoW", "payout"})) html += PowGuide();
    if (HasAny(title, {"Unlock"})) html += UnlockGuide();
    if (HasAny(title, {"Cold", "Delegate", "node", "own quantum"})) html += ColdStakeGuide();
    if (HasAny(title, {"migration", "Gold Rush rewards"})) html += MigrationGuide();
    if (HasAny(title, {"Demurrage", "liveness"})) html += DemurrageGuide();
    if (HasAny(title, {"RGB", "EUTXO", "asset"})) html += AssetsGuide();
    return html;
}

QString AccountGuide()
{
    return AccountSpecificGuide() + CommonGuide() + MigrationGuide() + DemurrageGuide() + AssetsGuide();
}

} // namespace QuantumGuides
