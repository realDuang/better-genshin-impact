using System;
using System.Threading.Tasks;

namespace BetterGenshinImpact.GameTask.OneDragon;

internal static class OneDragonExecution
{
    internal static async Task RunAsync(bool isCommandLine, Func<bool, Task<int>> execute,
        Action<int> shutdown, Action<Exception> logFailure)
    {
        if (!isCommandLine)
        {
            await execute(false);
            return;
        }

        var exitCode = 1;
        try
        {
            exitCode = await execute(true);
        }
        catch (Exception exception)
        {
            logFailure(exception);
        }
        finally
        {
            shutdown(exitCode);
        }
    }
}
