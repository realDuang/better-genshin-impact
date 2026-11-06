using BetterGenshinImpact.GameTask.AutoTrackPath;

namespace BetterGenshinImpact.UnitTest.GameTaskTests.OneDragonTests;

public class TeleportRetryTests
{
    [Fact]
    public async Task FailedPanelRestoresMapBeforeRecomputingAndEnteringAgain()
    {
        var events = new List<string>();
        var attempts = 0;
        var result = await TeleportRetry.RunAsync(() =>
        {
            events.Add($"locate:{++attempts}");
            return attempts == 1 ? Task.FromException<int>(new InvalidOperationException("panel missing"))
                : Task.FromResult(42);
        }, _ => true, (_, attempt) =>
        {
            events.Add($"restore:{attempt}");
            return Task.CompletedTask;
        });
        Assert.Equal(42, result);
        Assert.Equal(new[] { "locate:1", "restore:1", "locate:2" }, events);
    }

    [Fact]
    public async Task ExhaustionPreservesOriginalFailureAndStopsAtThreeAttempts()
    {
        var original = new InvalidOperationException("panel missing");
        var attempts = 0;
        var restores = 0;
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => TeleportRetry.RunAsync<int>(() =>
        {
            attempts++;
            throw original;
        }, _ => true, (_, _) => { restores++; return Task.CompletedTask; }));
        Assert.Same(original, error);
        Assert.Equal(3, attempts);
        Assert.Equal(2, restores);
    }

    [Fact]
    public async Task CancellationAndFailedRestorationDoNotStartAnotherTeleport()
    {
        var attempts = 0;
        await Assert.ThrowsAsync<OperationCanceledException>(() => TeleportRetry.RunAsync<int>(() =>
        {
            attempts++;
            throw new OperationCanceledException();
        }, error => error is not OperationCanceledException,
            (_, _) => throw new Exception("must not restore")));
        Assert.Equal(1, attempts);
        attempts = 0;
        await Assert.ThrowsAsync<OperationCanceledException>(() => TeleportRetry.RunAsync<int>(() =>
        {
            attempts++;
            throw new InvalidOperationException();
        }, _ => true, (_, _) => throw new OperationCanceledException()));
        Assert.Equal(1, attempts);
    }
}
