using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Rift.Daemon.Core;

[SupportedOSPlatform("linux")]
[SupportedOSPlatform("osx")]
internal static class Interop
{
    [DllImport("libc")]
    private static extern uint getuid();

    public static uint GetUid() => getuid();
}
