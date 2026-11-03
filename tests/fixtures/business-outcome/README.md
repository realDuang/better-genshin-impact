# Sanitized business-outcome fixtures

These fixtures retain selected native BetterGI messages from three observed
scenarios: warnings and sold-out items, domain-selection failure, and teleport
failure. Original process exits were zero.

All dates, run IDs, profile names, process IDs, Windows session IDs, and instance
markers are synthetic substitutes. Date windows and process/session relationships
are preserved so log attribution and outcome rules are exercised unchanged. Any
source build paths use the synthetic `C:\src\BetterGI` prefix.

The files retain stage boundaries, task endings, errors, warnings, naming/reward
cues, and the final flow marker. Unrelated runtime records were omitted. Native
message semantics are preserved; these files are test data, not an archive of a
real machine or a claimed run on the synthetic dates.
