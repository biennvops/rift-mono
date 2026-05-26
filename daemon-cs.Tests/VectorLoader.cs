using System.Text.Json;

namespace Rift.Daemon.Windows.Tests;

public static class VectorLoader
{
    private static readonly string VectorPath = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "spec", "vectors");

    public static async Task<T?> LoadVectorAsync<T>(string filename)
    {
        var filePath = Path.Combine(VectorPath, filename);
        if (!File.Exists(filePath))
        {
            return default;
        }

        var json = await File.ReadAllTextAsync(filePath);
        return JsonSerializer.Deserialize<T>(json);
    }
}
