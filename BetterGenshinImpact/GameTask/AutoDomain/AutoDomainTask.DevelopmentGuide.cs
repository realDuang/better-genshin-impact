using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using BetterGenshinImpact.Core.Recognition;
using BetterGenshinImpact.Core.Script.Dependence;
using BetterGenshinImpact.Core.Simulator;
using BetterGenshinImpact.Core.Simulator.Extensions;
using BetterGenshinImpact.GameTask.Common.Job;
using BetterGenshinImpact.GameTask.Common.Element.Assets;
using BetterGenshinImpact.Helpers;
using Microsoft.Extensions.Logging;
using static BetterGenshinImpact.GameTask.Common.TaskControl;

namespace BetterGenshinImpact.GameTask.AutoDomain;

public partial class AutoDomainTask
{
    public const string DevelopmentGuideOption = "根据提升指南选择秘境";
    private string? _guideDomainName;

    // 提升指南目前按简体中文界面识别；失败时停止，不回退到另一个秘境。
    private async Task ClickGuideText(string text, double x, double y, double w, double h)
    {
        for (var attempt = 0; attempt < 12; attempt++)
        {
            _ct.ThrowIfCancellationRequested();
            using var screen = CaptureToRectArea();
            var matches = screen.FindMulti(RecognitionObject.Ocr(
                screen.Width * x, screen.Height * y, screen.Width * w, screen.Height * h));
            try
            {
                var match = matches.FirstOrDefault(r => r.Text.Replace(" ", "") == text);
                if (match != null)
                {
                    match.Click();
                    await Delay(700, _ct);
                    return;
                }
            }
            finally
            {
                foreach (var match in matches) match.Dispose();
            }
            await Delay(300, _ct);
        }
        throw new InvalidOperationException($"提升指南：未找到{text}，请检查游戏语言和界面");
    }

    private async Task SelectDevelopmentGuideDestination()
    {
        _guideDomainName = null;
        await new ReturnMainUiTask().Start(_ct);
        Simulation.SendInput.SimulateAction(GIActions.OpenAdventurerHandbook);
        await Delay(1000, _ct);
        await ClickGuideText("秘境", 0.1, 0.2, 0.1, 0.6);
        await ClickGuideText("提升指南", 0.2, 0.17, 0.18, 0.15);
        var knownNames = MapLazyAssets.Get().DomainPositionMap.Keys.ToList();
        var attempt = 0;
        _guideDomainName = await DevelopmentGuideScanner.SelectFirstAsync(knownNames, ReadRows, ScrollList, _ct);
        if (_guideDomainName == null)
            throw new InvalidOperationException("提升指南秘境名称识别或地图匹配失败，请查看前面的OCR日志；这不代表没有培养目标");
        Logger.LogInformation("提升指南选择秘境：{Name}", _guideDomainName);
        await new ReturnMainUiTask().Start(_ct);

        async Task<IReadOnlyList<string>> ReadRows(CancellationToken ct)
        {
            await Delay(500, ct);
            using var screen = CaptureToRectArea();
            var rows = screen.FindMulti(RecognitionObject.Ocr(
                screen.Width * 0.39, screen.Height * 0.28, screen.Width * 0.18, screen.Height * 0.46));
            try
            {
                var texts = rows.OrderBy(r => r.Y).Select(r => r.Text).ToArray();
                Logger.LogInformation("提升指南秘境OCR（第{Attempt}次）：{Text}", ++attempt, string.Join(" | ", texts));
                return texts;
            }
            finally
            {
                foreach (var row in rows) row.Dispose();
            }
        }

        async Task ScrollList(int notches, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            using (var screen = CaptureToRectArea())
                GlobalMethod.MoveMouseTo((int)(screen.Width * 0.52), (int)(screen.Height * 0.45));
            await Delay(100, ct);
            for (var i = 0; i < Math.Abs(notches); i++)
            {
                ct.ThrowIfCancellationRequested();
                Simulation.SendInput.Mouse.VerticalScroll(Math.Sign(notches));
                await Delay(70, ct);
            }
            await Delay(600, ct);
        }
    }

    private async Task SelectDevelopmentGuideLevel()
    {
        using (var screen = CaptureToRectArea())
            GlobalMethod.MoveMouseTo(screen.Width / 4, screen.Height / 2);
        for (var i = 0; i < 80; i++)
        {
            Simulation.SendInput.Mouse.VerticalScroll(-1);
            await Delay(20, _ct);
        }
        await Delay(600, _ct);
        using var capture = CaptureToRectArea();
        var rows = capture.FindMulti(RecognitionObject.Ocr(0, capture.Height * 0.14,
            capture.Width * 0.47, capture.Height * 0.84));
        try
        {
            var levels = rows.Where(r => r.Text.Contains("秘境"))
                .Select(r => (Region: r, Tier: Regex.Match(r.Text.Trim(), @"[IVXⅠⅡⅢⅣⅤⅥ]+$", RegexOptions.IgnoreCase).Value))
                .Where(r => r.Tier.Length > 0).OrderByDescending(r => r.Region.Y).ToList();
            if (levels.Count == 0)
                throw new InvalidOperationException("提升指南：未识别到秘境最高难度");
            var highestTier = levels[0].Tier;
            // 周日/限时全开可能有多个同难度材料本，逐个核对需求角色。
            foreach (var level in levels.Where(r => r.Tier == highestTier).OrderBy(r => r.Region.Y))
            {
                level.Region.Click();
                await Delay(700, _ct);
                using var detail = CaptureToRectArea();
                using var text = detail.Find(RecognitionObject.Ocr(detail.Width * 0.48,
                    detail.Height * 0.55, detail.Width * 0.5, detail.Height * 0.28));
                if (text.Text.Contains("需求角色"))
                {
                    Logger.LogInformation("提升指南确认所需关卡：{Name}", level.Region.Text);
                    return;
                }
            }
            throw new InvalidOperationException("提升指南：最高难度没有需求角色，停止挑战");
        }
        finally
        {
            foreach (var row in rows) row.Dispose();
        }
    }
}
