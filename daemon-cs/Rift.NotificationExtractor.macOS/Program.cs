using System.Text.Json;
using Rift.NotificationExtractor.macOS;

const int maximumRequestBytes = 64 * 1024;
var serializerOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web);
var databaseReader = new NotificationDatabaseReader();

while (await Console.In.ReadLineAsync() is { } line)
{
    ExtractorResponse response;
    if (System.Text.Encoding.UTF8.GetByteCount(line) > maximumRequestBytes)
    {
        response = Error(string.Empty, "requestTooLarge", "Extractor requests must not exceed 64 KiB.");
    }
    else
    {
        var requestId = string.Empty;
        try
        {
            var request = JsonSerializer.Deserialize<ExtractorRequest>(line, serializerOptions)
                ?? throw new JsonException("The extractor request was empty.");
            requestId = request.Id;
            response = request.Operation switch
            {
                "getStatus" => Success(request.Id, databaseReader.GetStatus()),
                "scanNotificationChanges" => Success(
                    request.Id,
                    databaseReader.ScanNotificationChanges(request.Cursor ?? 0)),
                "rescanActiveNotifications" => Success(
                    request.Id,
                    databaseReader.RescanActiveNotifications()),
                _ => Error(request.Id, "unknownOperation", "The requested extractor operation is not supported.")
            };
        }
        catch (ExtractorException ex)
        {
            response = Error(requestId, ex.Code, ex.Message);
        }
        catch (JsonException)
        {
            response = Error(requestId, "invalidRequest", "The extractor request was not valid JSON.");
        }
        catch (Exception)
        {
            response = Error(requestId, "internalError", "The extractor could not complete the request.");
        }
    }

    await Console.Out.WriteLineAsync(JsonSerializer.Serialize(response, serializerOptions));
}

static ExtractorResponse Success(string id, object result) => new()
{
    Id = id,
    Ok = true,
    Result = result
};

static ExtractorResponse Error(string id, string code, string message) => new()
{
    Id = id,
    Ok = false,
    Error = new ExtractorError { Code = code, Message = message }
};
