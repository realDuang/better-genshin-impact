using BetterGenshinImpact.GameTask.OneDragon;

namespace BetterGenshinImpact.UnitTest.GameTaskTests.OneDragonTests;

public class OneDragonExecutionTests
{
    [Fact]
    public async Task CommandLineWaitsForFlowBeforeExitingExactlyOnce()
    {
        var flow = new TaskCompletionSource<int>();
        var exits = new List<int>();
        var commandLine = false;

        var execution = OneDragonExecution.RunAsync(true, value =>
        {
            commandLine = value;
            return flow.Task;
        }, exits.Add, _ => Assert.Fail("The flow did not fail."));

        Assert.True(commandLine);
        Assert.False(execution.IsCompleted);
        Assert.Empty(exits);
        flow.SetResult(0);
        await execution;
        Assert.Equal(new[] { 0 }, exits);
    }

    [Fact]
    public async Task StartupCancellationResultStillExitsWithFailure()
    {
        var exits = new List<int>();
        await OneDragonExecution.RunAsync(true, _ => Task.FromResult(1),
            exits.Add, _ => Assert.Fail("Cancellation returned normally."));

        Assert.Equal(new[] { 1 }, exits);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task CommandLineExceptionIsLoggedBeforeFailureExit(bool synchronousFailure)
    {
        var original = new InvalidOperationException("Game startup failed.");
        var calls = new List<string>();

        await OneDragonExecution.RunAsync(true, _ => synchronousFailure
                ? throw original : Task.FromException<int>(original),
            code => calls.Add($"exit:{code}"), error =>
            {
                Assert.Same(original, error);
                calls.Add("error");
            });

        Assert.Equal(new[] { "error", "exit:1" }, calls);
    }

    [Fact]
    public async Task ManualCancellationReturnLeavesGuiOpen()
    {
        var commandLine = true;
        var exits = new List<int>();

        await OneDragonExecution.RunAsync(false, value =>
        {
            commandLine = value;
            return Task.FromResult(1);
        }, exits.Add, _ => Assert.Fail("The manual flow did not fail."));

        Assert.False(commandLine);
        Assert.Empty(exits);
    }

    [Fact]
    public async Task ManualExceptionKeepsExistingPropagationAndDoesNotExit()
    {
        var original = new InvalidOperationException("Manual flow failed.");
        var exits = new List<int>();
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            OneDragonExecution.RunAsync(false, _ => Task.FromException<int>(original),
                exits.Add, _ => Assert.Fail("The GUI retains its existing exception handling.")));

        Assert.Same(original, error);
        Assert.Empty(exits);
    }

}
