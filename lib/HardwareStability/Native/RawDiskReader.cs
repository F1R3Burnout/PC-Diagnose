using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace PCDiagnose.HardwareStability
{
    // Read-only PhysicalDrive access for the Storage Surface Read stage.
    // GENERIC_READ is the ONLY access right ever requested here. This class
    // must never gain a write-capable open flag or a write syscall - a
    // raw-write path must never be added (spec sections 20/46; HS-027/028/029
    // verify this statically and at runtime).
    public static class RawDiskReader
    {
        private const uint GENERIC_READ = 0x80000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
        private const uint FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileSizeEx(SafeFileHandle hFile, out long lpFileSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ReadFile(
            SafeFileHandle hFile,
            IntPtr lpBuffer,
            uint nNumberOfBytesToRead,
            out uint lpNumberOfBytesRead,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFilePointerEx(
            SafeFileHandle hFile,
            long liDistanceToMove,
            out long lpNewFilePointer,
            uint dwMoveMethod);

        [StructLayout(LayoutKind.Sequential)]
        private struct DISK_GEOMETRY
        {
            public long Cylinders;
            public uint MediaType;
            public uint TracksPerCylinder;
            public uint SectorsPerTrack;
            public uint BytesPerSector;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            SafeFileHandle hDevice,
            uint dwIoControlCode,
            IntPtr lpInBuffer,
            uint nInBufferSize,
            ref DISK_GEOMETRY lpOutBuffer,
            uint nOutBufferSize,
            out uint lpBytesReturned,
            IntPtr lpOverlapped);

        private const uint IOCTL_DISK_GET_DRIVE_GEOMETRY = 0x00070000;

        public class OpenResult
        {
            public bool Success;
            public string ErrorMessage;
            public long TotalBytes;
            public int BytesPerSector;
        }

        public class ReadErrorInfo
        {
            public long Offset;
            public int Win32ErrorCode;
            public string Message;
        }

        // Opens the given \\.\PhysicalDriveN path with GENERIC_READ only and
        // returns its reported size, or a failure reason if it could not be
        // opened safely and read-only (per spec: that must yield SKIPPED, not
        // an exception that aborts the whole run).
        public static OpenResult TryOpenReadOnly(string physicalDrivePath)
        {
            var result = new OpenResult();
            using (var handle = CreateFile(physicalDrivePath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    result.Success = false;
                    result.ErrorMessage = new Win32Exception(Marshal.GetLastWin32Error()).Message;
                    return result;
                }

                long size;
                if (!GetFileSizeEx(handle, out size))
                {
                    result.Success = false;
                    result.ErrorMessage = new Win32Exception(Marshal.GetLastWin32Error()).Message;
                    return result;
                }

                var geometry = new DISK_GEOMETRY();
                uint bytesReturned;
                int sectorSize = 512;
                if (DeviceIoControl(handle, IOCTL_DISK_GET_DRIVE_GEOMETRY, IntPtr.Zero, 0, ref geometry, (uint)Marshal.SizeOf(geometry), out bytesReturned, IntPtr.Zero))
                {
                    sectorSize = (int)geometry.BytesPerSector;
                }

                result.Success = true;
                result.TotalBytes = size;
                result.BytesPerSector = sectorSize;
                return result;
            }
        }

        // Sequentially reads [0, bytesToRead) from the physical drive in
        // blockSizeBytes chunks, GENERIC_READ only, reporting progress and
        // read errors via the supplied callbacks. Never writes anything.
        public static ReadErrorInfo ScanSequentialRead(
            string physicalDrivePath,
            long bytesToRead,
            int blockSizeBytes,
            Action<long, long> onProgress,
            Func<bool> cancelRequested)
        {
            using (var handle = CreateFile(physicalDrivePath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    return new ReadErrorInfo { Offset = 0, Win32ErrorCode = Marshal.GetLastWin32Error(), Message = "Could not open drive read-only" };
                }

                IntPtr buffer = Marshal.AllocHGlobal(blockSizeBytes);
                try
                {
                    long totalRead = 0;
                    while (totalRead < bytesToRead)
                    {
                        if (cancelRequested())
                        {
                            return null;
                        }

                        uint toRead = (uint)Math.Min(blockSizeBytes, bytesToRead - totalRead);
                        uint bytesRead;
                        bool ok = ReadFile(handle, buffer, toRead, out bytesRead, IntPtr.Zero);
                        if (!ok)
                        {
                            int err = Marshal.GetLastWin32Error();
                            return new ReadErrorInfo
                            {
                                Offset = totalRead,
                                Win32ErrorCode = err,
                                Message = new Win32Exception(err).Message
                            };
                        }
                        if (bytesRead == 0)
                        {
                            break; // end of accessible range
                        }
                        totalRead += bytesRead;
                        onProgress(totalRead, bytesToRead);
                    }
                    return null; // no error
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }
    }
}
