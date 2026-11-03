using BetterGenshinImpact.GameTask.AutoGeniusInvokation.Exception;
using BetterGenshinImpact.GameTask.AutoPathing;
using OpenCvSharp;

namespace BetterGenshinImpact.UnitTest.GameTaskTests;

public class PathPositionRecoveryTests
{
    [Fact]
    public async Task FacingADistantTargetStillRequiresAValidPositionButDoesNotRequireTravelRange()
    {
        var position = new Point2f(100, 100);
        var result = await PathPositionRecovery.AcquireAsync(default, 5000, 5000,
            _ => Task.FromResult(position), () => { }, CancellationToken.None,
            requireNearTarget: false);
        Assert.Equal(position, result);
    }

    [Fact]
    public async Task ZeroNanAndDistantFramesStopMovementUntilRealPositionIsRecovered()
    {
        var valid = new Point2f(23764, 17314);
        var frames = new Queue<Point2f>([new(float.NaN, 17314), new(100, 100), valid]);
        var stops = 0;
        var reads = 0;
        var result = await PathPositionRecovery.AcquireAsync(default, 23766.875, 17314.60546875,
            _ =>
            {
                reads++;
                Assert.Equal(reads, stops);
                return Task.FromResult(frames.Dequeue());
            }, () => stops++, CancellationToken.None);

        Assert.Equal(valid, result);
        Assert.Equal(3, stops);
        Assert.Empty(frames);
    }

    [Fact]
    public async Task MissingPositionRemainsRetryableAndNeverReturnsMovableResult()
    {
        var reads = 0;
        var stops = 0;
        var error = await Assert.ThrowsAsync<PathPositionUnavailableException>(() =>
            PathPositionRecovery.AcquireAsync(default, 23766.875, 17314.60546875,
                _ =>
                {
                    reads++;
                    return Task.FromResult(default(Point2f));
                }, () => stops++, CancellationToken.None));

        Assert.IsAssignableFrom<RetryException>(error);
        Assert.Equal(4, reads);
        Assert.Equal(5, stops);
    }

    [Fact]
    public void PositionFailureRetriesOnceThenPropagatesInsteadOfCompletingRoute()
    {
        var error = new PathPositionUnavailableException("position lost");
        PathPositionRecovery.ThrowIfRetryExhausted(error, 1, 2);
        Assert.Same(error, Assert.Throws<PathPositionUnavailableException>(() =>
            PathPositionRecovery.ThrowIfRetryExhausted(error, 2, 2)));
        PathPositionRecovery.ThrowIfRetryExhausted(new RetryException("other retry policy"), 2, 2);
    }

    [Theory]
    [InlineData(100, 100, true)]
    [InlineData(600, 100, true)]
    [InlineData(601, 100, false)]
    [InlineData(0, 0, false)]
    [InlineData(float.NaN, 100, false)]
    [InlineData(float.PositiveInfinity, 100, false)]
    public void MovementRequiresFiniteNonzeroPositionWithinUnchangedDistanceLimit(float x, float y, bool allowed)
    {
        Assert.Equal(allowed, PathPositionRecovery.CanMove(new Point2f(x, y), 100, 100));
    }

    [Fact]
    public async Task CancellationDuringReacquisitionCannotReturnOrResumeMovement()
    {
        using var cts = new CancellationTokenSource();
        var reads = 0;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            PathPositionRecovery.AcquireAsync(default, 100, 100,
                _ =>
                {
                    reads++;
                    cts.Cancel();
                    return Task.FromResult(new Point2f(100, 100));
                }, () => { }, cts.Token));
        Assert.Equal(1, reads);
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(float.NaN, 100)]
    [InlineData(100, float.PositiveInfinity)]
    public void InvalidNavigationSeedsResetInsteadOfPoisoningNextMatch(float x, float y)
    {
        var navigation = new NavigationInstance();
        navigation.SetPrevPosition(23764, 17314);
        navigation.SetPrevPosition(x, y);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        Assert.Equal(-1f, typeof(NavigationInstance).GetField("_prevX", flags)!.GetValue(navigation));
        Assert.Equal(-1f, typeof(NavigationInstance).GetField("_prevY", flags)!.GetValue(navigation));
    }
}
