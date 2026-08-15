using System.Text.Json;
using System.Text.RegularExpressions;
using Rift.Daemon.Core;

namespace Rift.Conformance;

public static class Runner
{
    private static readonly Regex UuidV4 = new(
        @"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        RegexOptions.CultureInvariant);

    public static async Task<int> RunAsync(string root)
    {
        var notificationResult = await RunSuiteAsync(
            root,
            "notification-sync",
            RunNotificationSyncCase);
        var mediaResult = await RunSuiteAsync(
            root,
            "media-playback-action-correlation",
            RunMediaPlaybackActionCorrelationCase);
        var passed = notificationResult.Passed + mediaResult.Passed;
        var failed = notificationResult.Failed + mediaResult.Failed;

        Console.WriteLine($"Summary: {passed} passed, {failed} failed");
        return failed == 0 ? 0 : 1;
    }

    private static async Task<(int Passed, int Failed)> RunSuiteAsync(
        string root,
        string suiteName,
        Action<JsonElement> runCase)
    {
        var filePath = Path.Combine(root, "testcases", $"{suiteName}.json");
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(filePath));
        var passed = 0;
        var failed = 0;

        foreach (var testCase in document.RootElement.GetProperty("testCases").EnumerateArray())
        {
            var id = testCase.GetProperty("id").GetString()!;
            try
            {
                runCase(testCase);
                Console.WriteLine($"PASS {suiteName}/{id}");
                passed++;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine($"FAIL {suiteName}/{id}: {error.Message}");
                failed++;
            }
        }

        return (passed, failed);
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
            icon.Remove("dataBase64Length");
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

    private static void RunMediaPlaybackActionCorrelationCase(JsonElement testCase)
    {
        var input = testCase.GetProperty("input");
        var expected = testCase.GetProperty("expected");
        var initialRequest = input.GetProperty("initialRequest");
        var retryRequest = input.GetProperty("retryRequest");
        var lateResult = input.GetProperty("lateResult");
        var retryResult = input.GetProperty("retryResult");

        ValidateMediaPlaybackActionPayload(initialRequest, isResult: false);
        ValidateMediaPlaybackActionPayload(retryRequest, isResult: false);
        ValidateMediaPlaybackActionPayload(lateResult, isResult: true);
        ValidateMediaPlaybackActionPayload(retryResult, isResult: true);
        ExpectEqual(lateResult.GetProperty("operationId").GetString(), initialRequest.GetProperty("operationId").GetString());
        ExpectEqual(retryResult.GetProperty("operationId").GetString(), retryRequest.GetProperty("operationId").GetString());

        var initialOperationId = initialRequest.GetProperty("operationId").GetString()!;
        var retryOperationId = retryRequest.GetProperty("operationId").GetString()!;
        if (initialOperationId == retryOperationId)
        {
            throw new InvalidOperationException("retry must use a distinct operationId");
        }

        var pending = new Dictionary<string, JsonElement>(StringComparer.Ordinal)
        {
            [initialOperationId] = initialRequest
        };
        var states = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [initialOperationId] = "Expired",
            [retryOperationId] = "Dispatched"
        };
        pending.Remove(initialOperationId);
        pending[retryOperationId] = retryRequest;

        ApplyMediaPlaybackActionResult(pending, states, lateResult);
        ExpectEqual(states[retryOperationId], expected.GetProperty("stateAfterLateResult").GetString());

        ApplyMediaPlaybackActionResult(pending, states, retryResult);
        ExpectEqual(states[retryOperationId], expected.GetProperty("finalState").GetString());
        ExpectEqual(expected.GetProperty("result").GetString(), "accept");
    }

    private static void ValidateMediaPlaybackActionPayload(JsonElement payload, bool isResult)
    {
        foreach (var field in new[]
                 {
                     "operationId",
                     "playbackId",
                     "sourceDeviceId",
                     "requestingDeviceId",
                     "action"
                 })
        {
            if (!payload.TryGetProperty(field, out var value) ||
                value.ValueKind != JsonValueKind.String ||
                string.IsNullOrEmpty(value.GetString()))
            {
                throw new InvalidOperationException($"{field} is required");
            }
        }

        if (!UuidV4.IsMatch(payload.GetProperty("operationId").GetString()!))
        {
            throw new InvalidOperationException("operationId must be a lowercase UUIDv4");
        }
        if (payload.GetProperty("action").GetString() is not (
            "play" or "pause" or "togglePlayPause" or "next" or "previous" or "seek"))
        {
            throw new InvalidOperationException("unknown media playback action");
        }
        if (isResult &&
            (!payload.TryGetProperty("success", out var success) ||
             success.ValueKind is not (JsonValueKind.True or JsonValueKind.False)))
        {
            throw new InvalidOperationException("success is required on action results");
        }
    }

    private static void ApplyMediaPlaybackActionResult(
        Dictionary<string, JsonElement> pending,
        Dictionary<string, string> states,
        JsonElement result)
    {
        var operationId = result.GetProperty("operationId").GetString()!;
        if (!pending.Remove(operationId, out var request))
        {
            return;
        }

        foreach (var field in new[]
                 {
                     "playbackId",
                     "sourceDeviceId",
                     "requestingDeviceId",
                     "action"
                 })
        {
            ExpectEqual(result.GetProperty(field).GetString(), request.GetProperty(field).GetString());
        }
        states[operationId] = result.GetProperty("success").GetBoolean() ? "Done" : "Failed";
    }

    private static void ExpectEqual(object? actual, object? expected)
    {
        if (!Equals(actual, expected))
        {
            throw new InvalidOperationException($"expected <{expected}> but got <{actual}>");
        }
    }
}
