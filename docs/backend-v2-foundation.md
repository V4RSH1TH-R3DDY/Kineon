# Kineon v2 backend foundation

## Reference freeze

The v1 API remains the contract for the existing Swift apps and React dashboard. The backend test suite checks generated OpenAPI against the checked-in contract and freezes the v1 paths and their referenced schemas. Add v2 paths and models separately. Restore service by returning clients to the v1 endpoints and keeping the original SQLite store until any data migration has been reconciled.

The Python scorer, rolling baseline and Calm Mode rules remain the reference for the native port. The checked-in fixtures use public synthetic recipes from `backend/tests/synth.py`. They compare status, refusal reason and activity exactly, with tolerances of 0.1 score points and 0.01 Hz after rounding. Freeze the feature order in the Rust schema and regenerate fixtures only for an intentional reference change.

## Care-team access

- The patient enters their chosen doctor's details during app setup. A verified clinician account must accept the invitation before the system delivers clinical data. Each listed emergency contact sees the same doctor contact details.
- Each emergency contact gets read-only access to the full clinical file after accepting their patient-issued invitation. Removing a contact ends future access. Treating clinicians can add attributable clinical entries. Check the patient relationship and standing grant on every read, write and subscription.
- A first approved visit supplies the clinical record and up to 21 days of calculated tremor readings. The 21-day choice implements the requested two-to-three-week lookback. Show the actual available date range. Use capture timestamps to select the lookback and track receipt timestamps independently.
- The clinician opens the live feed after patient approval. The session closes when the clinician completes the assessment or the patient stops sharing early. Approvals are tied to a visit and are independent of identity-token renewal. Later visits require new approval to send fresh readings.
- The chosen clinician or hospital retains the clinical file after the visit. Care-team access to the saved file uses a standing grant. Closing a live visit preserves already shared data and stops delivery of later readings. Revocation stops future API reads and pushes. Copies already received remain subject to the recipient's record handling.

## Cloud implementation boundary

The next milestone adds OIDC identity, PostgreSQL migrations and patient-scoped processed-event sync. Give uploads stable event IDs, return conflicts for stale medical-record revisions and authorize each cursor page against current grants. WebSocket messages should prompt clients to resume authorized sync. Keep legacy raw-window development routes isolated while the unchanged clients still use them.

Use synthetic patient identities and fixtures for backend validation. Threat-model recipient impersonation, cross-patient reads, replayed uploads, access revoked mid-sync and confidential fields leaking into logs or notifications. Treat production deployment, device integration, external delivery channels and pharmacy fulfilment as separate gates.
