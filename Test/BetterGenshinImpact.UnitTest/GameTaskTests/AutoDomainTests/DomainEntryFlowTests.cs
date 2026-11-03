using BetterGenshinImpact.GameTask.AutoDomain;
using BetterGenshinImpact.GameTask.AutoGeniusInvokation.Exception;

namespace BetterGenshinImpact.UnitTest.GameTaskTests.AutoDomainTests;

public class DomainEntryFlowTests
{
    [Fact]
    public async Task MissingNamedTargetNeverPressesUnrelatedInteractionOrRunsLaterUi()
    {
        var calls = new List<string>();
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Run(calls, named: true, selected: false));

        Assert.Contains("目标交互项", error.Message);
        Assert.Equal(new[] { "select-target", "cleanup" }, calls);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task MissingMenuNeverRunsDifficultyOrChallengeUi(bool named)
    {
        var calls = new List<string>();
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Run(calls, named, menu: false));

        Assert.Contains("单人挑战菜单", error.Message);
        Assert.DoesNotContain("difficulty-and-challenge", calls);
        Assert.Equal("cleanup", calls.Last());
        Assert.Equal(named ? new[] { "select-target", "wait-option", "wait-menu", "cleanup" }
            : new[] { "default-interaction", "wait-menu", "cleanup" }, calls);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ConfirmedEntryPreservesExistingActionOrder(bool named)
    {
        var calls = new List<string>();
        await Run(calls, named);

        Assert.Equal(named ? new[] { "select-target", "wait-option", "wait-menu", "difficulty-and-challenge" }
            : new[] { "default-interaction", "wait-menu", "difficulty-and-challenge" }, calls);
    }

    [Fact]
    public async Task CleanupFailureCannotReplaceTheEntryFailure()
    {
        var calls = new List<string>();
        var cleanupError = new Exception("cleanup failed");
        var failures = new List<Exception>();
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            Run(calls, named: true, selected: false, cleanupError: cleanupError, cleanupFailures: failures));

        Assert.Contains("目标交互项", error.Message);
        Assert.Equal(new[] { cleanupError }, failures);
        Assert.Equal(new[] { "select-target", "cleanup" }, calls);
    }

    [Fact]
    public async Task LaterUiFailureIsPreservedAfterCleanup()
    {
        var calls = new List<string>();
        var original = new InvalidOperationException("difficulty recognition failed");
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Run(calls, named: true, continuationError: original));

        Assert.Same(original, error);
        Assert.Equal("cleanup", calls.Last());
    }

    [Theory]
    [InlineData(true, true)]
    [InlineData(false, true)]
    [InlineData(false, false)]
    public async Task CancellationBeforeEntryOrAfterMenuDoesNotSendLaterInput(bool beforeEntry, bool menu)
    {
        using var cts = new CancellationTokenSource();
        var calls = new List<string>();
        if (beforeEntry) cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Run(calls, named: true, menu: menu,
            onMenu: () => cts.Cancel(), ct: cts.Token));

        Assert.DoesNotContain("difficulty-and-challenge", calls);
        Assert.DoesNotContain("cleanup", calls);
        if (beforeEntry) Assert.Empty(calls);
    }

    [Fact]
    public async Task ProjectCancellationExceptionDoesNotTriggerCleanupInput()
    {
        using var cts = new CancellationTokenSource();
        var original = new NormalEndException("取消自动任务");
        var calls = new List<string>();
        Task UnexpectedInput() { calls.Add("unexpected-input"); return Task.CompletedTask; }
        var error = await Assert.ThrowsAsync<NormalEndException>(() => DomainEntryFlow.RunAsync(
            () =>
            {
                calls.Add("select-target");
                cts.Cancel();
                return Task.FromException<bool>(original);
            }, UnexpectedInput, UnexpectedInput, () => Task.FromResult(true),
            UnexpectedInput, UnexpectedInput, _ => { }, cts.Token));

        Assert.Same(original, error);
        Assert.Equal(new[] { "select-target" }, calls);
    }

    private static Task Run(List<string> calls, bool named, bool selected = true, bool menu = true,
        Exception? cleanupError = null, List<Exception>? cleanupFailures = null,
        Exception? continuationError = null, Action? onMenu = null, CancellationToken ct = default)
    {
        return DomainEntryFlow.RunAsync(
            named ? () => { calls.Add("select-target"); return Task.FromResult(selected); } : null,
            () => { calls.Add("default-interaction"); return Task.CompletedTask; },
            () => { calls.Add("wait-option"); return Task.CompletedTask; },
            () => { calls.Add("wait-menu"); onMenu?.Invoke(); return Task.FromResult(menu); },
            () =>
            {
                calls.Add("difficulty-and-challenge");
                return continuationError == null ? Task.CompletedTask : Task.FromException(continuationError);
            },
            () =>
            {
                calls.Add("cleanup");
                return cleanupError == null ? Task.CompletedTask : Task.FromException(cleanupError);
            },
            error => cleanupFailures?.Add(error), ct);
    }
}
