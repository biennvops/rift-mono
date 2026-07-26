using System.Buffers.Binary;
using System.Text;

namespace Rift.NotificationExtractor.macOS;

internal sealed class BinaryPropertyListReader
{
    private static readonly DateTimeOffset AppleEpoch = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private readonly byte[] _data;
    private readonly ulong[] _offsets;
    private readonly int _objectRefSize;
    private readonly Dictionary<ulong, object?> _objects = [];

    private BinaryPropertyListReader(byte[] data)
    {
        if (data.Length < 40 || !data.AsSpan(0, 8).SequenceEqual("bplist00"u8))
        {
            throw new InvalidDataException("Notification payload is not a binary property list.");
        }

        var trailer = data.AsSpan(data.Length - 32);
        var offsetIntSize = trailer[6];
        _objectRefSize = trailer[7];
        var objectCount = ReadUnsigned(trailer[8..16]);
        TopObject = ReadUnsigned(trailer[16..24]);
        var offsetTableOffset = ReadUnsigned(trailer[24..32]);

        if (objectCount == 0 || objectCount > 100_000 || TopObject >= objectCount ||
            offsetIntSize is < 1 or > 8 || _objectRefSize is < 1 or > 8)
        {
            throw new InvalidDataException("Notification property list trailer is invalid.");
        }

        var tableLength = checked(objectCount * offsetIntSize);
        if (offsetTableOffset > (ulong)data.Length || tableLength > (ulong)data.Length - offsetTableOffset)
        {
            throw new InvalidDataException("Notification property list offset table is invalid.");
        }

        _data = data;
        _offsets = new ulong[checked((int)objectCount)];
        for (ulong index = 0; index < objectCount; index++)
        {
            var start = checked((int)(offsetTableOffset + index * offsetIntSize));
            _offsets[index] = ReadUnsigned(data.AsSpan(start, offsetIntSize));
            if (_offsets[index] >= (ulong)(data.Length - 32))
            {
                throw new InvalidDataException("Notification property list object offset is invalid.");
            }
        }
    }

    private ulong TopObject { get; }

    public static object? Read(byte[] data)
    {
        var reader = new BinaryPropertyListReader(data);
        return reader.ReadObject(reader.TopObject);
    }

    private object? ReadObject(ulong objectIndex)
    {
        if (_objects.TryGetValue(objectIndex, out var cached))
        {
            return cached;
        }

        if (objectIndex >= (ulong)_offsets.Length)
        {
            throw new InvalidDataException("Notification property list object reference is invalid.");
        }

        var cursor = checked((int)_offsets[objectIndex]);
        var marker = _data[cursor++];
        var type = marker >> 4;
        var info = marker & 0x0f;

        object? value = type switch
        {
            0x0 => info switch
            {
                0x0 => null,
                0x8 => false,
                0x9 => true,
                _ => throw new InvalidDataException("Unsupported property list simple value.")
            },
            0x1 => ReadInteger(ref cursor, 1 << info),
            0x2 => ReadReal(ref cursor, 1 << info),
            0x3 when info == 0x3 => AppleEpoch.AddSeconds(ReadDouble(ref cursor)),
            0x4 => ReadData(ref cursor, ReadCount(info, ref cursor)),
            0x5 => ReadAscii(ref cursor, ReadCount(info, ref cursor)),
            0x6 => ReadUnicode(ref cursor, ReadCount(info, ref cursor)),
            0x8 => ReadUnsignedValue(ref cursor, info + 1),
            0xA => ReadArray(ref cursor, ReadCount(info, ref cursor)),
            0xD => ReadDictionary(objectIndex, ref cursor, ReadCount(info, ref cursor)),
            _ => throw new InvalidDataException($"Unsupported property list object type 0x{type:x}.")
        };

        _objects[objectIndex] = value;
        return value;
    }

    private Dictionary<string, object?> ReadDictionary(ulong objectIndex, ref int cursor, ulong count)
    {
        if (count > 10_000)
        {
            throw new InvalidDataException("Notification property list dictionary is too large.");
        }

        var dictionary = new Dictionary<string, object?>(checked((int)count), StringComparer.Ordinal);
        _objects[objectIndex] = dictionary;
        var keysStart = cursor;
        var valuesStart = checked(cursor + (int)(count * (ulong)_objectRefSize));
        EnsureAvailable(keysStart, checked((int)(count * (ulong)_objectRefSize * 2)));

        for (ulong index = 0; index < count; index++)
        {
            var keyReference = ReadReference(keysStart + checked((int)(index * (ulong)_objectRefSize)));
            var valueReference = ReadReference(valuesStart + checked((int)(index * (ulong)_objectRefSize)));
            var key = ReadObject(keyReference) as string
                ?? throw new InvalidDataException("Notification property list dictionary key is not a string.");
            dictionary[key] = ReadObject(valueReference);
        }

        cursor = checked(valuesStart + (int)(count * (ulong)_objectRefSize));
        return dictionary;
    }

    private List<object?> ReadArray(ref int cursor, ulong count)
    {
        if (count > 10_000)
        {
            throw new InvalidDataException("Notification property list array is too large.");
        }

        EnsureAvailable(cursor, checked((int)(count * (ulong)_objectRefSize)));
        var values = new List<object?>(checked((int)count));
        for (ulong index = 0; index < count; index++)
        {
            values.Add(ReadObject(ReadReference(cursor)));
            cursor += _objectRefSize;
        }
        return values;
    }

    private ulong ReadCount(int info, ref int cursor)
    {
        if (info < 0xF)
        {
            return (ulong)info;
        }

        EnsureAvailable(cursor, 1);
        var marker = _data[cursor++];
        if ((marker >> 4) != 0x1)
        {
            throw new InvalidDataException("Property list extended length is not an integer.");
        }

        var byteCount = 1 << (marker & 0x0f);
        return ReadUnsignedValue(ref cursor, byteCount);
    }

    private long ReadInteger(ref int cursor, int byteCount)
    {
        var unsigned = ReadUnsignedValue(ref cursor, byteCount);
        if (byteCount == 8)
        {
            return unchecked((long)unsigned);
        }
        return checked((long)unsigned);
    }

    private object ReadReal(ref int cursor, int byteCount) => byteCount switch
    {
        4 => ReadSingle(ref cursor),
        8 => ReadDouble(ref cursor),
        _ => throw new InvalidDataException("Unsupported property list real size.")
    };

    private float ReadSingle(ref int cursor)
    {
        EnsureAvailable(cursor, 4);
        var bits = BinaryPrimitives.ReadInt32BigEndian(_data.AsSpan(cursor, 4));
        cursor += 4;
        return BitConverter.Int32BitsToSingle(bits);
    }

    private double ReadDouble(ref int cursor)
    {
        EnsureAvailable(cursor, 8);
        var bits = BinaryPrimitives.ReadInt64BigEndian(_data.AsSpan(cursor, 8));
        cursor += 8;
        return BitConverter.Int64BitsToDouble(bits);
    }

    private byte[] ReadData(ref int cursor, ulong count)
    {
        var length = checked((int)count);
        EnsureAvailable(cursor, length);
        var value = _data.AsSpan(cursor, length).ToArray();
        cursor += length;
        return value;
    }

    private string ReadAscii(ref int cursor, ulong count)
    {
        var length = checked((int)count);
        EnsureAvailable(cursor, length);
        var value = Encoding.ASCII.GetString(_data, cursor, length);
        cursor += length;
        return value;
    }

    private string ReadUnicode(ref int cursor, ulong count)
    {
        var length = checked((int)count * 2);
        EnsureAvailable(cursor, length);
        var value = Encoding.BigEndianUnicode.GetString(_data, cursor, length);
        cursor += length;
        return value;
    }

    private ulong ReadReference(int offset)
    {
        EnsureAvailable(offset, _objectRefSize);
        return ReadUnsigned(_data.AsSpan(offset, _objectRefSize));
    }

    private ulong ReadUnsignedValue(ref int cursor, int byteCount)
    {
        if (byteCount is < 1 or > 8)
        {
            throw new InvalidDataException("Unsupported property list integer size.");
        }
        EnsureAvailable(cursor, byteCount);
        var value = ReadUnsigned(_data.AsSpan(cursor, byteCount));
        cursor += byteCount;
        return value;
    }

    private void EnsureAvailable(int offset, int length)
    {
        if (offset < 0 || length < 0 || offset > _data.Length - length)
        {
            throw new InvalidDataException("Notification property list is truncated.");
        }
    }

    private static ulong ReadUnsigned(ReadOnlySpan<byte> bytes)
    {
        ulong value = 0;
        foreach (var current in bytes)
        {
            value = (value << 8) | current;
        }
        return value;
    }
}
