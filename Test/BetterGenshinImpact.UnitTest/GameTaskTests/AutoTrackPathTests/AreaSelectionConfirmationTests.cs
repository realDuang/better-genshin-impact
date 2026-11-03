using BetterGenshinImpact.GameTask.AutoTrackPath;

namespace BetterGenshinImpact.UnitTest.GameTaskTests.AutoTrackPathTests;

public class AreaSelectionConfirmationTests
{
    [Fact]
    public void CurrentAreaButtonAndDuplicateMapTextDoNotIdentifyExpandedMenu()
    {
        Assert.False(AreaSelectionConfirmation.HasMultipleAreaRows(["枫丹", "枫丹"]));
        Assert.False(AreaSelectionConfirmation.HasMultipleAreaRows([]));
        Assert.True(AreaSelectionConfirmation.HasMultipleAreaRows(["蒙德", "璃月", "须弥"]));
    }

    [Fact]
    public void MissingTargetWhileOtherMenuRowsRemainDoesNotConfirmSelection()
    {
        var confirmation = new AreaSelectionConfirmation();
        var menuVisible = AreaSelectionConfirmation.HasMultipleAreaRows(["蒙德", "璃月", "须弥", "纳塔"]);
        for (var elapsed = 120; elapsed <= 600; elapsed += 80)
            Assert.False(confirmation.Observe(true, menuVisible, false, elapsed));
    }

    [Fact]
    public void ClickedRowRemainingVisibleDoesNotConfirmSelection()
    {
        var confirmation = new AreaSelectionConfirmation();
        Assert.False(confirmation.Observe(true, false, true, 200));
        Assert.False(confirmation.Observe(true, false, true, 600));
    }

    [Fact]
    public void WaitsForMinimumDelayAndTwoStableMapFrames()
    {
        var confirmation = new AreaSelectionConfirmation();
        Assert.False(confirmation.Observe(true, false, false, 80));
        Assert.False(confirmation.Observe(true, false, false, 120));
        Assert.True(confirmation.Observe(true, false, false, 200));
    }

    [Fact]
    public void MissingMapDuringAnimationResetsConfirmation()
    {
        var confirmation = new AreaSelectionConfirmation();
        Assert.False(confirmation.Observe(true, false, false, 120));
        Assert.False(confirmation.Observe(false, false, false, 200));
        Assert.False(confirmation.Observe(true, false, false, 280));
        Assert.True(confirmation.Observe(true, false, false, 360));
    }

    [Fact]
    public void ReturningMenuResetsConfirmation()
    {
        var confirmation = new AreaSelectionConfirmation();
        Assert.False(confirmation.Observe(true, false, false, 120));
        Assert.False(confirmation.Observe(true, true, false, 200));
        Assert.False(confirmation.Observe(true, false, false, 280));
        Assert.True(confirmation.Observe(true, false, false, 360));
    }
}
