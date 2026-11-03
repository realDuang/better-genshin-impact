using System;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Threading.Tasks;
using BetterGenshinImpact.GameTask.AutoGeniusInvokation.Exception;
using OpenCvSharp;

namespace BetterGenshinImpact.GameTask.AutoPathing;

internal static class PathPositionRecovery
{
    internal static bool IsValidPosition(Point2f position) =>
        float.IsFinite(position.X) && float.IsFinite(position.Y) && position != default;

    internal static bool CanMove(Point2f position, double targetX, double targetY) =>
        IsValidPosition(position) &&
        Math.Sqrt(Math.Pow(position.X - targetX, 2) + Math.Pow(position.Y - targetY, 2)) <= 500;

    internal static async Task<Point2f> AcquireAsync(
        Point2f initialPosition,
        double targetX,
        double targetY,
        Func<CancellationToken, Task<Point2f>> readStablePosition,
        Action stopMovement,
        CancellationToken ct,
        bool requireNearTarget = true)
    {
        var position = initialPosition;
        for (var attempt = 0; attempt < 5; attempt++)
        {
            ct.ThrowIfCancellationRequested();
            if (IsValidPosition(position) && (!requireNearTarget || CanMove(position, targetX, targetY)))
                return position;

            stopMovement();
            if (attempt + 1 < 5)
                position = await readStablePosition(ct);
        }

        ct.ThrowIfCancellationRequested();
        throw new PathPositionUnavailableException("小地图定位多次失败或距离目标过远，停止移动并重试路线");
    }

    internal static void ThrowIfRetryExhausted(RetryException error, int completedAttempts, int maximumAttempts)
    {
        // Position failure must not fall through to the caller as a completed route.
        if (error is PathPositionUnavailableException && completedAttempts >= maximumAttempts)
            ExceptionDispatchInfo.Capture(error).Throw();
    }
}

internal sealed class PathPositionUnavailableException(string message) : RetryException(message)
{
}
