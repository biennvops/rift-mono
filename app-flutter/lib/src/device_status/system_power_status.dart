import 'dart:ffi' as ffi;

final class SystemPowerStatus extends ffi.Struct {
  @ffi.Uint8()
  external int acLineStatus;

  @ffi.Uint8()
  external int batteryFlag;

  @ffi.Uint8()
  external int batteryLifePercent;

  @ffi.Uint8()
  external int reserved;

  @ffi.Uint32()
  external int batteryLifeTime;

  @ffi.Uint32()
  external int batteryFullLifeTime;
}
