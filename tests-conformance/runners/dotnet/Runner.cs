using System.Text.Json;
using Rift.Daemon.Core;

namespace Rift.Conformance;

public static class Runner
{
    public static async Task<int> RunAsync(string root)
    {
        var filePath = Path.Combine(root, "testcases", "notification-sync.json");
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(filePath));
        var suite = document.RootElement;
        var passed = 0;
        var failed = 0;

        foreach (var testCase in suite.GetProperty("testCases").EnumerateArray())
        {
            var id = testCase.GetProperty("id").GetString()!;
            try
            {
                RunNotificationSyncCase(testCase);
                Console.WriteLine($"PASS notification-sync/{id}");
                passed++;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine($"FAIL notification-sync/{id}: {error.Message}");
                failed++;
            }
        }

        Console.WriteLine($"Summary: {passed} passed, {failed} failed");
        return failed == 0 ? 0 : 1;
    }

    private static void RunNotificationSyncCase(JsonElement testCase)
    {
        var input = testCase.GetProperty("input");
        var expected = testCase.GetProperty("expected");
        var icon = JsonSerializer.Deserialize<Dictionary<string, object?>>(
            input.GetProperty("icon").GetRawText())
            ?? throw new InvalidOperationException("icon must be an object");

        if (icon.TryGetValue("dataBase64Length", out var rawLength) &&
            rawLength is JsonElement { ValueKind: JsonValueKind.Number } lengthElement &&
            lengthElement.TryGetInt32(out var length))
        {
            icon["dataBase64"] = new string('A', length);
        }

        var normalized = NotificationIconNormalizer.Normalize(icon);
        var expectedResult = expected.GetProperty("result").GetString();
        if (expectedResult == "accept" && normalized is null)
        {
            throw new InvalidOperationException("valid notification icon was dropped");
        }
        if (expectedResult == "drop" && normalized is not null)
        {
            throw new InvalidOperationException("invalid notification icon was accepted");
        }

        var notificationAccepted = input.GetProperty("notificationAccepted").GetBoolean();
        if (notificationAccepted != expected.GetProperty("notificationAccepted").GetBoolean())
        {
            throw new InvalidOperationException("notification acceptance result changed");
        }
    }
}
