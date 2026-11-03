# Test fixture provenance

`business-outcome` and `completed-branches` contain selected native message
sequences with synthetic metadata. They exercise business failures, ordinary
warning handling, expected resource exhaustion, and reward-state ambiguity.

Dates, run IDs, profile names, process IDs, Windows session IDs, and process-start
instance markers were replaced consistently. Source build paths, where present,
use `C:\src\BetterGI`. The completed-branch `source` labels name test scenarios
only. These substitutions preserve event ordering, run windows, identity matching,
and cross-record relationships. Gameplay messages and exception semantics are
retained. Fixtures contain no credentials, notification targets, device registry,
login state, machine configuration, or complete runtime exports.
