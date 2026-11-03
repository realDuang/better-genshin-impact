using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace BetterGenshinImpact.GameTask.AutoDomain;

internal static class DevelopmentGuideScanner
{
    internal static async Task<string?> SelectFirstAsync(
        IReadOnlyList<string> knownNames,
        Func<CancellationToken, Task<IReadOnlyList<string>>> readRows,
        Func<int, CancellationToken, Task> scroll,
        CancellationToken ct)
    {
        var candidates = knownNames.Select(name => (Name: name, Normalized: NormalizeName(name))).ToArray();
        ct.ThrowIfCancellationRequested();
        await scroll(20, ct);
        for (var page = 0; page < 20; page++)
        {
            // Recheck the same view before scrolling so a transient OCR miss does not skip a target.
            for (var attempt = 0; attempt < 2; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                var rows = await readRows(ct);
                ct.ThrowIfCancellationRequested();
                foreach (var row in rows)
                {
                    var recognized = NormalizeName(row);
                    var matches = candidates.Where(candidate => recognized.Contains(candidate.Normalized)).ToArray();
                    if (matches.Length == 1)
                        return matches[0].Name;
                }
            }

            if (page + 1 < 20)
            {
                ct.ThrowIfCancellationRequested();
                // Small overlapping advances keep entries visible across successive captures.
                await scroll(-3, ct);
            }
        }

        return null;
    }

    private static string NormalizeName(string text)
    {
        var name = Regex.Replace(text, @"\s+", "");
        // Correct only established whole-name variants; never use fuzzy matches to select a domain.
        return name.Replace("菫色之庭", "堇色之庭").Replace("董色之庭", "堇色之庭");
    }
}
