($transaction | length) == 1 and
.schema == 1 and .result == "passed" and
.image == $transaction[0].candidate_image and
.image_id == $transaction[0].candidate_image_id and
.source_commit == $transaction[0].source_commit and
(.duration_seconds | type) == "number" and .duration_seconds == (.duration_seconds | floor) and
.duration_seconds >= 3600 and
(.total_sample_rounds | type) == "number" and
.total_sample_rounds == (.total_sample_rounds | floor) and .total_sample_rounds >= 4 and
.nodes_healthy == 32 and .pos_active == 32 and .regular_pow_active == 31 and
.free_claim_node == 30 and .free_claim_regular_pow == false and
.free_claim_broadcasts_paused == true and
.claim_recovery_fee_unchanged == true and .fee_payments_authorized == false and
.quantum_special_nodes == [31,32] and .vpn_proofs_valid_unique == 32 and
.final_concurrent_dynamic_gate == true and .global_chain_convergence == true and
.final_exact_32_generation_fence == true and
.external_supervisors_maintenance_inhibited == true and
.supervisor_freshness_deferred_to_finalization == true and
(has("supervisor_exact_32_fresh") | not) and
.replay_state_schema == 12 and .replay_state_valid_nodes == 32 and
.donation_defaults_off_nodes == 32 and
.activation_wallet_transaction_sets_unchanged == true and
.wallet_transaction_guard_unchanged_nodes == 32 and
(.claim_recovery_baseline_sha256s | type) == "object" and
(.claim_recovery_baseline_sha256s | keys) ==
    [range(1;33) | tostring | if length == 1 then "0" + . else . end] and
all(.claim_recovery_baseline_sha256s[];
    type == "string" and test("^[0-9a-f]{64}$")) and
(.claim_recovery_baseline_set_sha256 | type) == "string" and
(.claim_recovery_baseline_set_sha256 | test("^[0-9a-f]{64}$"))
