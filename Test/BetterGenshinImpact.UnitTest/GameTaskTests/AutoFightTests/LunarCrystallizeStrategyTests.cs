using BetterGenshinImpact.GameTask.AutoFight.Script;

namespace BetterGenshinImpact.UnitTest.GameTaskTests.AutoFightTests;

public class LunarCrystallizeStrategyTests
{
    [Fact]
    public void AppendZibaiActions_MatchesFullTeamAndPreservesExistingCommands()
    {
        var originalText = ReadFixture("original-universal.txt");
        var candidateText = ReadFixture("candidate-universal.txt");
        Assert.StartsWith(originalText, candidateText);
        var appendedLine = Assert.Single(candidateText[originalText.Length..]
            .Split(["\r\n", "\r", "\n"], StringSplitOptions.RemoveEmptyEntries));
        Assert.StartsWith("兹白 ", appendedLine);

        var original = CombatScriptParser.ParseContext(originalText, validate: true);
        var candidate = CombatScriptParser.ParseContext(candidateText, validate: true);
        var addition = CombatScriptParser.ParseContext(appendedLine, validate: true);
        string[] team = ["兹白", "哥伦比娅", "莉奈娅", "钟离"];

        Assert.DoesNotContain("兹白", original.AvatarNames);
        Assert.True(addition.AvatarNames.SetEquals(["兹白"]));
        Assert.True(candidate.AvatarNames.SetEquals(original.AvatarNames.Append("兹白")));
        Assert.Equal(3, new CombatScriptBag(original).SelectCombatScript(team).MatchCount);
        Assert.Equal(4, new CombatScriptBag(candidate).SelectCombatScript(team).MatchCount);
        Assert.NotEmpty(addition.CombatCommands);
        Assert.Equal(original.CombatCommands.Count + addition.CombatCommands.Count,
            candidate.CombatCommands.Count);

        for (var index = 0; index < original.CombatCommands.Count; index++)
        {
            var before = original.CombatCommands[index];
            var after = candidate.CombatCommands[index];
            Assert.Equal(before.Name, after.Name);
            Assert.Same(before.Method, after.Method);
            Assert.Equal(before.Args, after.Args);
            Assert.Equal(before.ActivatingRound, after.ActivatingRound);
        }

        Assert.All(candidate.CombatCommands.Skip(original.CombatCommands.Count),
            command => Assert.Equal("兹白", command.Name));
    }

    private static string ReadFixture(string name)
    {
        // Read source fixtures without changing project-wide output-copy settings.
        for (DirectoryInfo? directory = new DirectoryInfo(AppContext.BaseDirectory);
             directory != null;
             directory = directory.Parent)
        {
            if (File.Exists(Path.Combine(directory.FullName, "BetterGenshinImpact.UnitTest.csproj")))
            {
                return File.ReadAllText(Path.Combine(directory.FullName, "Fixtures",
                    "LunarCrystallizeRepair", name));
            }
        }

        throw new DirectoryNotFoundException("The unit-test source directory was not found.");
    }
}
