using System;
using System.Threading.Tasks;

namespace BetterGenshinImpact.GameTask.AutoTrackPath;

internal static class TeleportRetry
{
    internal static async Task<T> RunAsync<T>(Func<Task<T>> execute, Func<Exception, bool> canRetry,
        Func<Exception, int, Task> restore, int attempts = 3)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await execute();
            }
            catch (Exception exception) when (attempt < attempts && canRetry(exception))
            {
                await restore(exception, attempt);
            }
        }
    }
}
