using System;
using System.Text.Json.Serialization;

namespace Rift.Daemon.Core.Protocol;

public class RiftMessageEnvelope
{
    [JsonPropertyName("rift")]
    public string Rift { get; set; } = "0.1-draft";

    [JsonPropertyName("type")]
    public string Type { get; set; } = string.Empty;

    [JsonPropertyName("messageId")]
    public Guid MessageId { get; set; } = Guid.NewGuid();

    [JsonPropertyName("sourceDeviceId")]
    public string SourceDeviceId { get; set; } = string.Empty;

    [JsonPropertyName("payload")]
    public object Payload { get; set; } = new();

    [JsonPropertyName("operationId")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Guid? OperationId { get; set; }
}

public class SessionHelloPayload
{
    [JsonPropertyName("supportedVersions")]
    public string[] SupportedVersions { get; set; } = { "0.1-draft" };

    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("implementationId")]
    public string ImplementationId { get; set; } = string.Empty;

    [JsonPropertyName("capabilities")]
    public CapabilityInfo[] Capabilities { get; set; } = Array.Empty<CapabilityInfo>();

    [JsonPropertyName("identityProof")]
    public string IdentityProof { get; set; } = string.Empty;
}

public class SessionAcceptPayload
{
    [JsonPropertyName("selectedVersion")]
    public string SelectedVersion { get; set; } = "0.1-draft";

    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("identityVerified")]
    public bool IdentityVerified { get; set; } = true;

    [JsonPropertyName("identityProof")]
    public string IdentityProof { get; set; } = string.Empty;

    [JsonPropertyName("capabilities")]
    public CapabilityInfo[] Capabilities { get; set; } = Array.Empty<CapabilityInfo>();
}

public class CapabilityInfo
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("version")]
    public int Version { get; set; }
}
