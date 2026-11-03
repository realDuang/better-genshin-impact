using System;
using System.Threading;
using System.Threading.Tasks;

namespace BetterGenshinImpact.GameTask.AutoDomain;

internal static class DomainEntryFlow
{
    internal static async Task RunAsync(
        Func<Task<bool>>? selectNamedOption,
        Func<Task> pressDefaultOption,
        Func<Task> waitForOptionToDisappear,
        Func<Task<bool>> waitForMenu,
        Func<Task> enterConfirmedDomain,
        Func<Task> returnToMainUi,
        Action<Exception> logCleanupFailure,
        CancellationToken ct)
    {
        try
        {
            ct.ThrowIfCancellationRequested();
            if (selectNamedOption != null)
            {
                var selected = await selectNamedOption();
                ct.ThrowIfCancellationRequested();
                if (!selected)
                    throw new InvalidOperationException("秘境入口：未确认目标交互项");

                await waitForOptionToDisappear();
            }
            else
            {
                await pressDefaultOption();
            }

            ct.ThrowIfCancellationRequested();
            var menuFound = await waitForMenu();
            ct.ThrowIfCancellationRequested();
            if (!menuFound)
                throw new InvalidOperationException("秘境入口：未检测到单人挑战菜单");

            await enterConfirmedDomain();
        }
        catch (Exception error) when (error is not OperationCanceledException && !ct.IsCancellationRequested)
        {
            try
            {
                await returnToMainUi();
            }
            catch (Exception cleanupError)
            {
                logCleanupFailure(cleanupError);
            }
            throw;
        }
    }
}
