namespace Rift.Daemon.Tests.Core;

internal static class TestFiles
{
    /// <summary>
    /// Deletes a temp file with a bounded retry. On Windows, background send
    /// tasks can briefly keep the source file open after the observable part
    /// of a scenario has completed, which fails an immediate delete.
    /// </summary>
    public static async Task DeleteWithRetryAsync(string path)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
                return;
            }
            catch (IOException) when (attempt < 50)
            {
                await Task.Delay(20);
            }
        }
    }
}
