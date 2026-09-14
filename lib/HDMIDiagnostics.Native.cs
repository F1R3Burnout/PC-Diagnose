using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace PCDiagnose.Display
{
    public sealed class DisplayPathRecord
    {
        public string SourceName { get; set; }
        public string MonitorFriendlyName { get; set; }
        public string MonitorDevicePath { get; set; }
        public string AdapterDevicePath { get; set; }
        public long AdapterLuid { get; set; }
        public uint SourceId { get; set; }
        public uint TargetId { get; set; }
        public string OutputTechnology { get; set; }
        public string Rotation { get; set; }
        public string Scaling { get; set; }
        public string ScanLineOrdering { get; set; }
        public bool TargetAvailable { get; set; }
        public uint StatusFlags { get; set; }
        public uint Width { get; set; }
        public uint Height { get; set; }
        public int PositionX { get; set; }
        public int PositionY { get; set; }
        public double RefreshRateHz { get; set; }
        public double PhysicalRefreshRateHz { get; set; }
        public ulong PixelRateHz { get; set; }
        public uint PreferredWidth { get; set; }
        public uint PreferredHeight { get; set; }
        public bool FriendlyNameFromEdid { get; set; }
        public bool EdidIdsValid { get; set; }
        public ushort EdidManufacturerId { get; set; }
        public ushort EdidProductCodeId { get; set; }
        public uint ConnectorInstance { get; set; }
        public bool AdvancedColorInfoAvailable { get; set; }
        public bool AdvancedColorSupported { get; set; }
        public bool AdvancedColorEnabled { get; set; }
        public bool WideColorEnforced { get; set; }
        public bool AdvancedColorForceDisabled { get; set; }
        public string ColorEncoding { get; set; }
        public uint BitsPerColorChannel { get; set; }
        public bool SdrWhiteLevelAvailable { get; set; }
        public double SdrWhiteLevelNits { get; set; }
    }

    public static class DisplayConfigReader
    {
        private const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
        private const uint QDC_VIRTUAL_MODE_AWARE = 0x00000010;
        private const uint QDC_VIRTUAL_REFRESH_RATE_AWARE = 0x00000040;
        private const uint DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE = 0x00000008;
        private const uint INVALID_MODE_INDEX = 0xFFFFFFFF;
        private const int ERROR_SUCCESS = 0;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID
        {
            public uint LowPart;
            public int HighPart;

            public long ToInt64()
            {
                return ((long)HighPart << 32) | LowPart;
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_RATIONAL
        {
            public uint Numerator;
            public uint Denominator;

            public double Value
            {
                get { return Denominator == 0 ? 0.0 : (double)Numerator / Denominator; }
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_2DREGION
        {
            public uint cx;
            public uint cy;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct POINTL
        {
            public int x;
            public int y;
        }

        private enum DISPLAYCONFIG_MODE_INFO_TYPE : uint
        {
            SOURCE = 1,
            TARGET = 2,
            DESKTOP_IMAGE = 3
        }

        private enum DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY : uint
        {
            OTHER = 0xFFFFFFFF,
            HD15 = 0,
            SVIDEO = 1,
            COMPOSITE_VIDEO = 2,
            COMPONENT_VIDEO = 3,
            DVI = 4,
            HDMI = 5,
            LVDS = 6,
            D_JPN = 8,
            SDI = 9,
            DISPLAYPORT_EXTERNAL = 10,
            DISPLAYPORT_EMBEDDED = 11,
            UDI_EXTERNAL = 12,
            UDI_EMBEDDED = 13,
            SDTVDONGLE = 14,
            MIRACAST = 15,
            INDIRECT_WIRED = 16,
            INDIRECT_VIRTUAL = 17,
            INTERNAL = 0x80000000
        }

        private enum DISPLAYCONFIG_ROTATION : uint
        {
            IDENTITY = 1,
            ROTATE90 = 2,
            ROTATE180 = 3,
            ROTATE270 = 4
        }

        private enum DISPLAYCONFIG_SCALING : uint
        {
            IDENTITY = 1,
            CENTERED = 2,
            STRETCHED = 3,
            ASPECTRATIOCENTEREDMAX = 4,
            CUSTOM = 5,
            PREFERRED = 128
        }

        private enum DISPLAYCONFIG_SCANLINE_ORDERING : uint
        {
            UNSPECIFIED = 0,
            PROGRESSIVE = 1,
            INTERLACED = 2,
            INTERLACED_UPPERFIELDFIRST = 2,
            INTERLACED_LOWERFIELDFIRST = 3
        }

        private enum DISPLAYCONFIG_PIXELFORMAT : uint
        {
            PIXELFORMAT_8BPP = 1,
            PIXELFORMAT_16BPP = 2,
            PIXELFORMAT_24BPP = 3,
            PIXELFORMAT_32BPP = 4,
            PIXELFORMAT_NONGDI = 5
        }

        private enum DISPLAYCONFIG_COLOR_ENCODING : uint
        {
            RGB = 0,
            YCBCR444 = 1,
            YCBCR422 = 2,
            YCBCR420 = 3,
            INTENSITY = 4
        }

        private enum DISPLAYCONFIG_DEVICE_INFO_TYPE : uint
        {
            GET_SOURCE_NAME = 1,
            GET_TARGET_NAME = 2,
            GET_TARGET_PREFERRED_MODE = 3,
            GET_ADAPTER_NAME = 4,
            GET_ADVANCED_COLOR_INFO = 9,
            GET_SDR_WHITE_LEVEL = 11
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_PATH_SOURCE_INFO
        {
            public LUID adapterId;
            public uint id;
            public uint modeInfoIdx;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_PATH_TARGET_INFO
        {
            public LUID adapterId;
            public uint id;
            public uint modeInfoIdx;
            public DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY outputTechnology;
            public DISPLAYCONFIG_ROTATION rotation;
            public DISPLAYCONFIG_SCALING scaling;
            public DISPLAYCONFIG_RATIONAL refreshRate;
            public DISPLAYCONFIG_SCANLINE_ORDERING scanLineOrdering;
            [MarshalAs(UnmanagedType.Bool)] public bool targetAvailable;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_PATH_INFO
        {
            public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
            public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
            public uint flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_VIDEO_SIGNAL_INFO
        {
            public ulong pixelRate;
            public DISPLAYCONFIG_RATIONAL hSyncFreq;
            public DISPLAYCONFIG_RATIONAL vSyncFreq;
            public DISPLAYCONFIG_2DREGION activeSize;
            public DISPLAYCONFIG_2DREGION totalSize;
            public uint additionalSignalInfo;
            public DISPLAYCONFIG_SCANLINE_ORDERING scanLineOrdering;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_TARGET_MODE
        {
            public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_SOURCE_MODE
        {
            public uint width;
            public uint height;
            public DISPLAYCONFIG_PIXELFORMAT pixelFormat;
            public POINTL position;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_DESKTOP_IMAGE_INFO
        {
            public POINTL PathSourceSize;
            public DISPLAYCONFIG_2DREGION DesktopImageRegion;
            public DISPLAYCONFIG_2DREGION DesktopImageClip;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct DISPLAYCONFIG_MODE_INFO_UNION
        {
            [FieldOffset(0)] public DISPLAYCONFIG_TARGET_MODE targetMode;
            [FieldOffset(0)] public DISPLAYCONFIG_SOURCE_MODE sourceMode;
            [FieldOffset(0)] public DISPLAYCONFIG_DESKTOP_IMAGE_INFO desktopImageInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_MODE_INFO
        {
            public DISPLAYCONFIG_MODE_INFO_TYPE infoType;
            public uint id;
            public LUID adapterId;
            public DISPLAYCONFIG_MODE_INFO_UNION modeInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_DEVICE_INFO_HEADER
        {
            public DISPLAYCONFIG_DEVICE_INFO_TYPE type;
            public uint size;
            public LUID adapterId;
            public uint id;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DISPLAYCONFIG_TARGET_DEVICE_NAME
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            public uint flags;
            public DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY outputTechnology;
            public ushort edidManufactureId;
            public ushort edidProductCodeId;
            public uint connectorInstance;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DISPLAYCONFIG_ADAPTER_NAME
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string adapterDevicePath;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_TARGET_PREFERRED_MODE
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            public uint width;
            public uint height;
            public DISPLAYCONFIG_TARGET_MODE targetMode;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            public uint value;
            public DISPLAYCONFIG_COLOR_ENCODING colorEncoding;
            public uint bitsPerColorChannel;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_SDR_WHITE_LEVEL
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            public uint SDRWhiteLevel;
        }

        [DllImport("user32.dll")]
        private static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

        [DllImport("user32.dll")]
        private static extern int QueryDisplayConfig(uint flags, ref uint numPathArrayElements,
            [Out] DISPLAYCONFIG_PATH_INFO[] pathInfoArray, ref uint numModeInfoArrayElements,
            [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, IntPtr currentTopologyId);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME requestPacket);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME requestPacket);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_ADAPTER_NAME requestPacket);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_PREFERRED_MODE requestPacket);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO requestPacket);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SDR_WHITE_LEVEL requestPacket);

        private static DISPLAYCONFIG_DEVICE_INFO_HEADER Header(DISPLAYCONFIG_DEVICE_INFO_TYPE type, int size, LUID adapterId, uint id)
        {
            return new DISPLAYCONFIG_DEVICE_INFO_HEADER
            {
                type = type,
                size = (uint)size,
                adapterId = adapterId,
                id = id
            };
        }

        private static uint GetModeIndex(uint rawIndex, bool virtualMode)
        {
            if (rawIndex == INVALID_MODE_INDEX) return INVALID_MODE_INDEX;
            return virtualMode ? (rawIndex >> 16) & 0xFFFF : rawIndex;
        }

        public static DisplayPathRecord[] GetActivePaths()
        {
            uint flags = QDC_ONLY_ACTIVE_PATHS | QDC_VIRTUAL_MODE_AWARE | QDC_VIRTUAL_REFRESH_RATE_AWARE;
            uint pathCount;
            uint modeCount;
            int result = GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount);
            if (result != ERROR_SUCCESS)
            {
                flags = QDC_ONLY_ACTIVE_PATHS;
                result = GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount);
            }
            if (result != ERROR_SUCCESS) throw new Win32Exception(result, "GetDisplayConfigBufferSizes failed");

            DISPLAYCONFIG_PATH_INFO[] paths;
            DISPLAYCONFIG_MODE_INFO[] modes;
            do
            {
                paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
                modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
                result = QueryDisplayConfig(flags, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
                if (result == ERROR_INSUFFICIENT_BUFFER)
                {
                    result = GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount);
                    if (result != ERROR_SUCCESS) throw new Win32Exception(result, "GetDisplayConfigBufferSizes retry failed");
                }
            } while (result == ERROR_INSUFFICIENT_BUFFER);

            if (result != ERROR_SUCCESS) throw new Win32Exception(result, "QueryDisplayConfig failed");

            var records = new List<DisplayPathRecord>();
            for (int index = 0; index < pathCount; index++)
            {
                DISPLAYCONFIG_PATH_INFO path = paths[index];
                var record = new DisplayPathRecord
                {
                    AdapterLuid = path.targetInfo.adapterId.ToInt64(),
                    SourceId = path.sourceInfo.id,
                    TargetId = path.targetInfo.id,
                    OutputTechnology = path.targetInfo.outputTechnology.ToString(),
                    Rotation = path.targetInfo.rotation.ToString(),
                    Scaling = path.targetInfo.scaling.ToString(),
                    ScanLineOrdering = path.targetInfo.scanLineOrdering.ToString(),
                    TargetAvailable = path.targetInfo.targetAvailable,
                    StatusFlags = path.targetInfo.statusFlags,
                    RefreshRateHz = path.targetInfo.refreshRate.Value
                };

                bool virtualMode = (path.flags & DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE) != 0;
                uint sourceIndex = GetModeIndex(path.sourceInfo.modeInfoIdx, virtualMode);
                if (sourceIndex != INVALID_MODE_INDEX && sourceIndex < modeCount && modes[sourceIndex].infoType == DISPLAYCONFIG_MODE_INFO_TYPE.SOURCE)
                {
                    DISPLAYCONFIG_SOURCE_MODE sourceMode = modes[sourceIndex].modeInfo.sourceMode;
                    record.Width = sourceMode.width;
                    record.Height = sourceMode.height;
                    record.PositionX = sourceMode.position.x;
                    record.PositionY = sourceMode.position.y;
                }

                uint targetIndex = GetModeIndex(path.targetInfo.modeInfoIdx, virtualMode);
                if (targetIndex != INVALID_MODE_INDEX && targetIndex < modeCount && modes[targetIndex].infoType == DISPLAYCONFIG_MODE_INFO_TYPE.TARGET)
                {
                    DISPLAYCONFIG_VIDEO_SIGNAL_INFO signal = modes[targetIndex].modeInfo.targetMode.targetVideoSignalInfo;
                    record.PixelRateHz = signal.pixelRate;
                    record.PhysicalRefreshRateHz = signal.vSyncFreq.Value;
                    if (record.Width == 0) record.Width = signal.activeSize.cx;
                    if (record.Height == 0) record.Height = signal.activeSize.cy;
                }

                var targetName = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
                targetName.header = Header(DISPLAYCONFIG_DEVICE_INFO_TYPE.GET_TARGET_NAME,
                    Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME)), path.targetInfo.adapterId, path.targetInfo.id);
                if (DisplayConfigGetDeviceInfo(ref targetName) == ERROR_SUCCESS)
                {
                    record.MonitorFriendlyName = targetName.monitorFriendlyDeviceName;
                    record.MonitorDevicePath = targetName.monitorDevicePath;
                    record.OutputTechnology = targetName.outputTechnology.ToString();
                    record.FriendlyNameFromEdid = (targetName.flags & 0x1) != 0;
                    record.EdidIdsValid = (targetName.flags & 0x4) != 0;
                    record.EdidManufacturerId = targetName.edidManufactureId;
                    record.EdidProductCodeId = targetName.edidProductCodeId;
                    record.ConnectorInstance = targetName.connectorInstance;
                }

                var sourceName = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
                sourceName.header = Header(DISPLAYCONFIG_DEVICE_INFO_TYPE.GET_SOURCE_NAME,
                    Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME)), path.sourceInfo.adapterId, path.sourceInfo.id);
                if (DisplayConfigGetDeviceInfo(ref sourceName) == ERROR_SUCCESS)
                    record.SourceName = sourceName.viewGdiDeviceName;

                var adapterName = new DISPLAYCONFIG_ADAPTER_NAME();
                adapterName.header = Header(DISPLAYCONFIG_DEVICE_INFO_TYPE.GET_ADAPTER_NAME,
                    Marshal.SizeOf(typeof(DISPLAYCONFIG_ADAPTER_NAME)), path.targetInfo.adapterId, path.targetInfo.id);
                if (DisplayConfigGetDeviceInfo(ref adapterName) == ERROR_SUCCESS)
                    record.AdapterDevicePath = adapterName.adapterDevicePath;

                var preferredMode = new DISPLAYCONFIG_TARGET_PREFERRED_MODE();
                preferredMode.header = Header(DISPLAYCONFIG_DEVICE_INFO_TYPE.GET_TARGET_PREFERRED_MODE,
                    Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_PREFERRED_MODE)), path.targetInfo.adapterId, path.targetInfo.id);
                if (DisplayConfigGetDeviceInfo(ref preferredMode) == ERROR_SUCCESS)
                {
                    record.PreferredWidth = preferredMode.width;
                    record.PreferredHeight = preferredMode.height;
                }

                var color = new DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO();
                color.header = Header(DISPLAYCONFIG_DEVICE_INFO_TYPE.GET_ADVANCED_COLOR_INFO,
                    Marshal.SizeOf(typeof(DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO)), path.targetInfo.adapterId, path.targetInfo.id);
                if (DisplayConfigGetDeviceInfo(ref color) == ERROR_SUCCESS)
                {
                    record.AdvancedColorInfoAvailable = true;
                    record.AdvancedColorSupported = (color.value & 0x1) != 0;
                    record.AdvancedColorEnabled = (color.value & 0x2) != 0;
                    record.WideColorEnforced = (color.value & 0x4) != 0;
                    record.AdvancedColorForceDisabled = (color.value & 0x8) != 0;
                    record.ColorEncoding = color.colorEncoding.ToString();
                    record.BitsPerColorChannel = color.bitsPerColorChannel;
                }

                var white = new DISPLAYCONFIG_SDR_WHITE_LEVEL();
                white.header = Header(DISPLAYCONFIG_DEVICE_INFO_TYPE.GET_SDR_WHITE_LEVEL,
                    Marshal.SizeOf(typeof(DISPLAYCONFIG_SDR_WHITE_LEVEL)), path.targetInfo.adapterId, path.targetInfo.id);
                if (DisplayConfigGetDeviceInfo(ref white) == ERROR_SUCCESS)
                {
                    record.SdrWhiteLevelAvailable = true;
                    record.SdrWhiteLevelNits = white.SDRWhiteLevel / 1000.0 * 80.0;
                }

                records.Add(record);
            }
            return records.ToArray();
        }
    }
}
