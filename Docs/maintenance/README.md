# Downstream reliability maintenance

This personal fork records independently maintainable changes on official BetterGI **0.66.0**, commit `0af68c28f6b0e714d5304625ce644736d508022e`. The working branch is `duang/automation-reliability-20261103`. No upstream pull request is required for this branch.

## Patch inventory

| Commit | Behavior |
| --- | --- |
| `240c7012` | Keep ONNX session options alive during native initialization; guard partially constructed OCR finalizers. |
| `e849241a` | Reset and scan the development guide before selecting a uniquely matched material domain. |
| `85d5fe02` | Recover the region menu and confirm area selection before remembering a map center. |
| `a777470a` | Stop movement while recovering invalid positions; protect the navigation seed and propagate exhausted recovery. |
| `b606dd01` | Reuse the existing remaining-cooldown fallback for Zibai and preserve the combat-strategy regression fixtures. |

[Automation](../../Automation/README.md) contains the existing unattended runner, session cleanup, deterministic reporting, and their source dependencies. [Automation tests](../../tests/) use synthetic fixture identities. These scripts require an explicitly configured Windows installation; cloning this repository does not provision a machine or run the game.

The combat fixtures are owned by the main repository under `Test/BetterGenshinImpact.UnitTest/Fixtures/LunarCrystallizeRepair`, outside the upstream test-assets submodule. Their attributes preserve original bytes. The candidate fixture records the one-line strategy addition; it is not an automatically installed user configuration.

## Build and focused verification

Use Windows with an SDK capable of building the .NET 8 Windows/WPF target and the matching .NET 8 runtime. The recorded checkout validation used the PC's installed toolchain. Package references stay on the release versions; do not replace native ONNX libraries independently.

From the repository root:

```powershell
dotnet test Test/BetterGenshinImpact.UnitTest/BetterGenshinImpact.UnitTest.csproj `
  -c Release -p:Platform=x64 `
  --filter "FullyQualifiedName~DevelopmentGuideScannerTests|FullyQualifiedName~LunarCrystallizeStrategyTests|FullyQualifiedName~CombatScriptParserTests|FullyQualifiedName~PaddleOcrFinalizerTests|FullyQualifiedName~AreaSelectionConfirmationTests|FullyQualifiedName~PathPositionRecoveryTests"

python -m unittest discover -s tests -p "test_*.py"

Get-ChildItem tests/Test-*.ps1 | ForEach-Object {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" }
}

dotnet publish BetterGenshinImpact/BetterGenshinImpact.csproj `
  -c Release -p:Platform=x64 -p:PublishProfile=FolderProfile `
  -p:SelfContained=false -p:PublishSelfContained=false
```

The explicit publish properties preserve the existing framework-dependent distribution layout. Test outputs and build artifacts are not source inputs. These focused tests do not require updating the test-assets submodule to its moving remote branch.

On 2026-11-03 the new checkout passed all **37 focused C# tests** after moving the combat fixtures. The new Windows checkout also passed **16 Python tests**, all **six Windows PowerShell suites**, and a separate build of the launcher. Detailed results remain in local verification artifacts. The repository does not include raw machine logs, user profiles, tokens, delivery receipts, crash dumps, or installed binaries.

## Native acceptance already performed

Before recording these changes in Git, the repaired application ran an actual five-step OneDragon flow on 2026-11-03 from **13:30:51 to 13:37:18 UTC+8**. It performed mail and crafting interactions, selected and entered a domain, executed combat, detected challenge completion, then reached the reward tree. At that point it recognized 16 original resin and zero condensed resin, so it ended without claiming that domain reward. Guild and teapot operations followed. The final daily-reward check reported already claimed; process/task exit was zero and owned-session cleanup completed.

An earlier acceptance run completed two challenges in the same domain and claimed both rewards, consuming 20 original resin each time. The final run had no native ERR entries. Its single resin warning was classified as an expected stop only because the same step supplied normal-stop and completion evidence.

The historical OCR access violation was not reproduced by the short pressure probe; the lifetime fix does not prove the only cause of that crash. Cold boot, physical WOL, and shutdown cycles were not part of this acceptance. Recording and testing this checkout did not replay the game or replace the installed application.

## Upgrade policy

Fetch upstream releases into a separate candidate branch. Inspect each logical patch against the selected release, remove equivalent upstream fixes, then port only the remainder. A textually clean cherry-pick is not gameplay acceptance. Retain the accepted build and machine-local configuration for rollback.

At the 2026-11-03 review, official `main` was `07d38b31b5531c342d318316f3240ed62b56e825`; the default `refactor/20260930` branch was `9e3a0b008b063e144982818d46f00c00081ffbd2`. Those development snapshots already replace guide scanning and OCR ownership, so the corresponding old patches should be retired after equivalent behavior is validated. They still have relevant map/navigation gaps. Do not automatically merge the moving default branch into this release-based maintenance branch.

Native result improvements should reuse upstream typed task results and repair OneDragon child-result aggregation and persistence before software exit. Keep scheduling, child ownership, cleanup, delivery, and WOL eligibility external. Preserve separate process and business outcomes: assigning a new nonzero native exit code for game failure can accidentally trigger the outer runner's crash retry.

Recommended candidate acceptance covers successful gameplay, a failed step with normal process exit, expected resin exhaustion, cancellation, missing terminal evidence, and cleanup before any retry. Preserve ordinary native logs alongside machine-readable results.
