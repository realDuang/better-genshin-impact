using BetterGenshinImpact.GameTask.AutoDomain;

namespace BetterGenshinImpact.UnitTest.GameTaskTests.AutoDomainTests;

public class DevelopmentGuideScannerTests
{
    private static readonly string[] KnownDomains = ["荒坠的圣迹", "塞西莉亚苗圃", "堇色之庭"];

    [Fact]
    public async Task ScansPastWeeklyBossesAndSelectsFirstSupportedRow()
    {
        var scrolls = new List<int>();
        var page = -1;
        var result = await DevelopmentGuideScanner.SelectFirstAsync(KnownDomains,
            _ => Task.FromResult<IReadOnlyList<string>>(page == 0
                ? ["月的研究所", "挪德卡莱", "待解「弈局]", "蒙德"]
                : ["塞西莉亚苗圃", "荒坠的圣迹"]),
            (notches, _) =>
            {
                scrolls.Add(notches);
                page = notches > 0 ? 0 : page + 1;
                return Task.CompletedTask;
            }, CancellationToken.None);

        Assert.Equal("塞西莉亚苗圃", result);
        Assert.Equal(new[] { 20, -3 }, scrolls);
    }

    [Theory]
    [InlineData("赝月的研究所")]
    [InlineData("当前暂无可获取的培养素材")]
    [InlineData("无法识别的文字")]
    [InlineData("荒坠的圣迹塞西莉亚苗圃")]
    public async Task UnmatchedOrAmbiguousRowsRemainFailureAtScrollLimit(string row)
    {
        var reads = 0;
        var scrolls = new List<int>();
        var result = await DevelopmentGuideScanner.SelectFirstAsync(KnownDomains,
            _ =>
            {
                reads++;
                return Task.FromResult<IReadOnlyList<string>>([row]);
            },
            (notches, _) =>
            {
                scrolls.Add(notches);
                return Task.CompletedTask;
            }, CancellationToken.None);

        Assert.Null(result);
        Assert.Equal(40, reads);
        Assert.Equal(20, scrolls.Count);
        Assert.Equal(20, scrolls[0]);
        Assert.All(scrolls.Skip(1), notches => Assert.Equal(-3, notches));
    }

    [Fact]
    public async Task RetriesRecognitionBeforeScrollingAndPreservesKnownNameNormalization()
    {
        var reads = 0;
        var scrolls = new List<int>();
        var result = await DevelopmentGuideScanner.SelectFirstAsync(KnownDomains,
            _ => Task.FromResult<IReadOnlyList<string>>(++reads == 1 ? [] : ["董 色 之 庭"]),
            (notches, _) =>
            {
                scrolls.Add(notches);
                return Task.CompletedTask;
            }, CancellationToken.None);

        Assert.Equal("堇色之庭", result);
        Assert.Equal(new[] { 20 }, scrolls);
        Assert.Equal(2, reads);
    }

    [Fact]
    public async Task CanSelectTargetOnFinalPageWithoutScrollingBeyondLimit()
    {
        var page = -1;
        var result = await DevelopmentGuideScanner.SelectFirstAsync(KnownDomains,
            _ => Task.FromResult<IReadOnlyList<string>>(page == 19 ? ["荒坠的圣迹"] : []),
            (notches, _) =>
            {
                page = notches > 0 ? 0 : page + 1;
                return Task.CompletedTask;
            }, CancellationToken.None);

        Assert.Equal("荒坠的圣迹", result);
        Assert.Equal(19, page);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task CancellationStopsBeforeInputOrBeforeAcceptingCapturedTarget(bool cancelBeforeStart)
    {
        using var cts = new CancellationTokenSource();
        var scrolls = 0;
        var reads = 0;
        if (cancelBeforeStart) cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            DevelopmentGuideScanner.SelectFirstAsync(KnownDomains,
                _ =>
                {
                    reads++;
                    cts.Cancel();
                    return Task.FromResult<IReadOnlyList<string>>(["荒坠的圣迹"]);
                },
                (_, _) =>
                {
                    scrolls++;
                    return Task.CompletedTask;
                }, cts.Token));

        Assert.Equal(cancelBeforeStart ? 0 : 1, scrolls);
        Assert.Equal(cancelBeforeStart ? 0 : 1, reads);
    }

    [Fact]
    public async Task RecognitionExceptionRemainsVisibleAndDoesNotContinueScrolling()
    {
        var error = new InvalidOperationException("capture failed");
        var scrolls = 0;
        var actual = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DevelopmentGuideScanner.SelectFirstAsync(KnownDomains,
                _ => Task.FromException<IReadOnlyList<string>>(error),
                (_, _) =>
                {
                    scrolls++;
                    return Task.CompletedTask;
                }, CancellationToken.None));

        Assert.Same(error, actual);
        Assert.Equal(1, scrolls);
    }
}
