using System;
using System.Collections.Generic;
using System.Linq;

namespace BetterGenshinImpact.GameTask.AutoTrackPath;

internal sealed class AreaSelectionConfirmation
{
    private int _stableChecks;

    internal static bool HasMultipleAreaRows(IEnumerable<string> areaNames)
    {
        // A single current-area button or map label does not identify the expanded selector.
        return areaNames.Distinct(StringComparer.Ordinal).Take(2).Count() == 2;
    }

    internal bool Observe(bool mapVisible, bool menuVisible, bool clickedCandidateVisible, long elapsedMilliseconds)
    {
        if (!mapVisible || menuVisible || clickedCandidateVisible || elapsedMilliseconds < 120)
        {
            _stableChecks = 0;
            return false;
        }

        return ++_stableChecks >= 2;
    }
}
