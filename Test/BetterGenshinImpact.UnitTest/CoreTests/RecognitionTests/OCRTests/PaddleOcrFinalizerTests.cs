using System.Reflection;
using System.Runtime.CompilerServices;
using BetterGenshinImpact.Core.Recognition.OCR.Paddle;

namespace BetterGenshinImpact.UnitTest.CoreTests.RecognitionTests.OCRTests;

public class PaddleOcrFinalizerTests
{
    [Theory]
    [InlineData(typeof(Det))]
    [InlineData(typeof(Rec))]
    public void FailedSessionConstruction_DoesNotThrowFromFinalizer(Type type)
    {
        // A field initializer can throw before the session is assigned. Suppress
        // automatic finalization so the previous failure is safe to assert here.
        var instance = RuntimeHelpers.GetUninitializedObject(type);
        GC.SuppressFinalize(instance);
        var finalize = type.GetMethod("Finalize", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.DeclaredOnly);
        Assert.NotNull(finalize);
        Assert.Null(Record.Exception(() => finalize.Invoke(instance, null)));
    }
}
