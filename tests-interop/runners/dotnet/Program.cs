using System.Text.Json;
using Rift.Daemon.Core;

if (args.Length != 1)
{
    Console.Error.WriteLine("usage: Rift.NotificationInteropRunner <records.json>");
    return 2;
}

using var document = JsonDocument.Parse(await File.ReadAllTextAsync(args[0]));
if (document.RootElement.ValueKind != JsonValueKind.Array)
{
    Console.Error.WriteLine("records must be a JSON array");
    return 2;
}

var records = new List<Dictionary<string, object?>>();
foreach (var element in document.RootElement.EnumerateArray())
{
    var record = JsonSerializer.Deserialize<Dictionary<string, object?>>(element.GetRawText());
    if (record is null ||
        !record.TryGetValue("icon", out var rawIcon) ||
        rawIcon is not JsonElement { ValueKind: JsonValueKind.Object } iconElement)
    {
        Console.Error.WriteLine("each record must contain an icon object");
        return 2;
    }

    var icon = JsonSerializer.Deserialize<Dictionary<string, object?>>(iconElement.GetRawText());
    var normalized = NotificationIconNormalizer.Normalize(icon);
    if (normalized is null)
    {
        Console.Error.WriteLine("C# rejected a notification icon");
        return 1;
    }

    record["icon"] = normalized;
    records.Add(record);
}

Console.WriteLine(JsonSerializer.Serialize(records));
return 0;
