using System;
using System.Runtime.InteropServices;

namespace PCDiagnose.HardwareStability
{
    // Minimal Direct3D 11 compute-shader host used for the GPU_COMPUTE
    // verification stage (spec section 13). D3D11 was chosen over Vulkan
    // because it ships with every Windows 10/11 install (WARP software
    // fallback always available) - see docs/HARDWARE_STABILITY_SPEC.md
    // section 2 for the full rationale. There is no SharpDX/Vortice/NuGet
    // dependency available in this project's build environment, so the
    // COM interfaces are consumed by reading their vtable directly; method
    // slot indices below were verified against the WIDL-generated
    // mingw-w64 d3d11.h / d3dcompiler.h headers (a faithful mirror of the
    // Microsoft Windows SDK IDL) during implementation, not guessed.
    public static class D3D11ComputeVerifier
    {
        private const int E_ABORT = unchecked((int)0x80004004);

        [DllImport("d3d11.dll", CallingConvention = CallingConvention.StdCall)]
        private static extern int D3D11CreateDevice(
            IntPtr pAdapter, int DriverType, IntPtr Software, uint Flags,
            IntPtr pFeatureLevels, uint FeatureLevels, uint SDKVersion,
            out IntPtr ppDevice, out int pFeatureLevel, out IntPtr ppImmediateContext);

        [DllImport("d3dcompiler_47.dll", CallingConvention = CallingConvention.StdCall)]
        private static extern int D3DCompile(
            [MarshalAs(UnmanagedType.LPStr)] string pSrcData, UIntPtr SrcDataSize,
            [MarshalAs(UnmanagedType.LPStr)] string pSourceName,
            IntPtr pDefines, IntPtr pInclude,
            [MarshalAs(UnmanagedType.LPStr)] string pEntrypoint,
            [MarshalAs(UnmanagedType.LPStr)] string pTarget,
            uint Flags1, uint Flags2, out IntPtr ppCode, out IntPtr ppErrorMsgs);

        private const int D3D_DRIVER_TYPE_HARDWARE = 1;
        private const int D3D_DRIVER_TYPE_WARP = 5;
        private const int D3D_FEATURE_LEVEL_11_0 = 0xb000;
        private const int D3D_FEATURE_LEVEL_10_0 = 0xa000;

        private const uint D3D11_BIND_UNORDERED_ACCESS = 0x80;
        private const uint D3D11_RESOURCE_MISC_BUFFER_STRUCTURED = 0x40;
        private const uint D3D11_USAGE_DEFAULT = 0;
        private const uint D3D11_USAGE_STAGING = 3;
        private const uint D3D11_CPU_ACCESS_READ = 0x20000;
        private const uint D3D11_MAP_READ = 1;
        private const int DXGI_ERROR_DEVICE_REMOVED = unchecked((int)0x887A0005);

        [StructLayout(LayoutKind.Sequential)]
        private struct D3D11_BUFFER_DESC
        {
            public uint ByteWidth;
            public uint Usage;
            public uint BindFlags;
            public uint CPUAccessFlags;
            public uint MiscFlags;
            public uint StructureByteStride;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct D3D11_SUBRESOURCE_DATA
        {
            public IntPtr pSysMem;
            public uint SysMemPitch;
            public uint SysMemSlicePitch;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct D3D11_UNORDERED_ACCESS_VIEW_DESC
        {
            public uint Format;             // DXGI_FORMAT_UNKNOWN = 0 for a structured buffer view
            public uint ViewDimension;      // D3D11_UAV_DIMENSION_BUFFER = 1
            public uint FirstElement;
            public uint NumElements;
            public uint Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct D3D11_MAPPED_SUBRESOURCE
        {
            public IntPtr pData;
            public uint RowPitch;
            public uint DepthPitch;
        }

        // ---- vtable slot indices, verified against mingw-w64 d3d11.h/d3dcompiler.h ----
        private const int Slot_IUnknown_Release = 2;
        private const int Slot_Device_CreateBuffer = 3;
        private const int Slot_Device_CreateUnorderedAccessView = 8;
        private const int Slot_Device_CreateComputeShader = 18;
        private const int Slot_Device_GetDeviceRemovedReason = 39;
        private const int Slot_Context_Map = 14;
        private const int Slot_Context_Unmap = 15;
        private const int Slot_Context_Dispatch = 41;
        private const int Slot_Context_CopyResource = 47;
        private const int Slot_Context_CSSetUnorderedAccessViews = 68;
        private const int Slot_Context_CSSetShader = 69;
        private const int Slot_Blob_GetBufferPointer = 3;
        private const int Slot_Blob_GetBufferSize = 4;

        private static IntPtr GetVtableSlot(IntPtr comObject, int slotIndex)
        {
            IntPtr vtable = Marshal.ReadIntPtr(comObject, 0);
            return Marshal.ReadIntPtr(vtable, slotIndex * IntPtr.Size);
        }

        private static TDelegate GetMethod<TDelegate>(IntPtr comObject, int slotIndex) where TDelegate : class
        {
            IntPtr fn = GetVtableSlot(comObject, slotIndex);
            return Marshal.GetDelegateForFunctionPointer<TDelegate>(fn);
        }

        private static int Release(IntPtr comObject)
        {
            if (comObject == IntPtr.Zero) return 0;
            var release = GetMethod<ReleaseDelegate>(comObject, Slot_IUnknown_Release);
            return release(comObject);
        }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int ReleaseDelegate(IntPtr self);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int CreateBufferDelegate(IntPtr self, ref D3D11_BUFFER_DESC desc, IntPtr pInitialData, out IntPtr ppBuffer);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int CreateUnorderedAccessViewDelegate(IntPtr self, IntPtr resource, ref D3D11_UNORDERED_ACCESS_VIEW_DESC desc, out IntPtr ppUAView);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int CreateComputeShaderDelegate(IntPtr self, IntPtr bytecode, UIntPtr bytecodeLength, IntPtr classLinkage, out IntPtr ppShader);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetDeviceRemovedReasonDelegate(IntPtr self);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate void CSSetShaderDelegate(IntPtr self, IntPtr shader, IntPtr classInstances, uint numClassInstances);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate void CSSetUnorderedAccessViewsDelegate(IntPtr self, uint startSlot, uint numUavs, IntPtr uavArray, IntPtr initialCounts);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate void DispatchDelegate(IntPtr self, uint x, uint y, uint z);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate void CopyResourceDelegate(IntPtr self, IntPtr dst, IntPtr src);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int MapDelegate(IntPtr self, IntPtr resource, uint subresource, uint mapType, uint mapFlags, out D3D11_MAPPED_SUBRESOURCE mapped);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate void UnmapDelegate(IntPtr self, IntPtr resource, uint subresource);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate IntPtr GetBufferPointerDelegate(IntPtr self);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate UIntPtr GetBufferSizeDelegate(IntPtr self);

        public class VerifyResult
        {
            public bool Success;
            public bool DeviceLost;
            public bool UsedWarp;
            public int ElementCount;
            public long MismatchCount;
            public string ErrorMessage = "";
            public string CompileErrorMessage = "";
            public int FeatureLevel;
        }

        private const string ShaderSource = @"
RWStructuredBuffer<uint> Input : register(u0);
RWStructuredBuffer<uint> Output : register(u1);

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID)
{
    uint idx = dtid.x;
    uint v = Input[idx];
    uint r = (v << 13) | (v >> (32 - 13));
    r = r ^ 0x9E3779B9u;
    r = r * 2654435761u + idx;
    r = (r >> 7) | (r << (32 - 7));
    Output[idx] = r ^ (idx * 0x85EBCA6Bu);
}
";

        // Bit-exact CPU reference implementation of the same formula the
        // HLSL shader above computes, using C#'s uint (32-bit, wraps on
        // overflow exactly like HLSL uint) so the comparison is exact -
        // no floating point rounding tolerance is needed (spec section 13).
        public static uint ComputeReference(uint v, uint idx)
        {
            uint r = (v << 13) | (v >> (32 - 13));
            r = r ^ 0x9E3779B9u;
            r = r * 2654435761u + idx;
            r = (r >> 7) | (r << (32 - 7));
            return r ^ (idx * 0x85EBCA6Bu);
        }

        public static VerifyResult RunVerification(uint[] inputData)
        {
            var result = new VerifyResult { ElementCount = inputData.Length };
            IntPtr device = IntPtr.Zero, context = IntPtr.Zero;
            IntPtr inputBuffer = IntPtr.Zero, outputBuffer = IntPtr.Zero, stagingBuffer = IntPtr.Zero;
            IntPtr inputUav = IntPtr.Zero, outputUav = IntPtr.Zero;
            IntPtr shaderBlob = IntPtr.Zero, errorBlob = IntPtr.Zero, computeShader = IntPtr.Zero;
            GCHandle inputPin = default(GCHandle);

            try
            {
                int hr = D3D11CreateDevice(IntPtr.Zero, D3D_DRIVER_TYPE_HARDWARE, IntPtr.Zero, 0,
                    IntPtr.Zero, 0, 7 /* D3D11_SDK_VERSION */, out device, out result.FeatureLevel, out context);

                if (hr < 0)
                {
                    result.UsedWarp = true;
                    hr = D3D11CreateDevice(IntPtr.Zero, D3D_DRIVER_TYPE_WARP, IntPtr.Zero, 0,
                        IntPtr.Zero, 0, 7, out device, out result.FeatureLevel, out context);
                }

                if (hr < 0)
                {
                    result.ErrorMessage = string.Format("D3D11CreateDevice failed (HRESULT 0x{0:X8})", hr);
                    return result;
                }

                if (result.FeatureLevel < D3D_FEATURE_LEVEL_10_0)
                {
                    result.ErrorMessage = string.Format("GPU feature level 0x{0:X} is below the minimum required for compute shaders (Compute Shader 4.0, CS_4_0)", result.FeatureLevel);
                    return result;
                }
                string target = result.FeatureLevel >= D3D_FEATURE_LEVEL_11_0 ? "cs_5_0" : "cs_4_0";

                hr = D3DCompile(ShaderSource, (UIntPtr)ShaderSource.Length, "hs_gpu_compute_verify.hlsl",
                    IntPtr.Zero, IntPtr.Zero, "CSMain", target, 0, 0, out shaderBlob, out errorBlob);
                if (hr < 0)
                {
                    if (errorBlob != IntPtr.Zero)
                    {
                        var getPtr = GetMethod<GetBufferPointerDelegate>(errorBlob, Slot_Blob_GetBufferPointer);
                        var getSize = GetMethod<GetBufferSizeDelegate>(errorBlob, Slot_Blob_GetBufferSize);
                        IntPtr p = getPtr(errorBlob);
                        int len = (int)getSize(errorBlob);
                        result.CompileErrorMessage = Marshal.PtrToStringAnsi(p, len);
                    }
                    result.ErrorMessage = string.Format("D3DCompile failed (HRESULT 0x{0:X8}): {1}", hr, result.CompileErrorMessage);
                    return result;
                }

                var blobPtr = GetMethod<GetBufferPointerDelegate>(shaderBlob, Slot_Blob_GetBufferPointer);
                var blobSize = GetMethod<GetBufferSizeDelegate>(shaderBlob, Slot_Blob_GetBufferSize);
                IntPtr bytecodePtr = blobPtr(shaderBlob);
                UIntPtr bytecodeLen = blobSize(shaderBlob);

                var createComputeShader = GetMethod<CreateComputeShaderDelegate>(device, Slot_Device_CreateComputeShader);
                hr = createComputeShader(device, bytecodePtr, bytecodeLen, IntPtr.Zero, out computeShader);
                if (hr < 0)
                {
                    result.ErrorMessage = string.Format("CreateComputeShader failed (HRESULT 0x{0:X8})", hr);
                    return result;
                }

                int count = inputData.Length;
                uint byteWidth = (uint)(count * 4);

                inputPin = GCHandle.Alloc(inputData, GCHandleType.Pinned);
                var createBuffer = GetMethod<CreateBufferDelegate>(device, Slot_Device_CreateBuffer);

                var inDesc = new D3D11_BUFFER_DESC
                {
                    ByteWidth = byteWidth,
                    Usage = D3D11_USAGE_DEFAULT,
                    BindFlags = D3D11_BIND_UNORDERED_ACCESS,
                    CPUAccessFlags = 0,
                    MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
                    StructureByteStride = 4
                };
                var initData = new D3D11_SUBRESOURCE_DATA { pSysMem = inputPin.AddrOfPinnedObject(), SysMemPitch = 0, SysMemSlicePitch = 0 };
                IntPtr initDataPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(D3D11_SUBRESOURCE_DATA)));
                try
                {
                    Marshal.StructureToPtr(initData, initDataPtr, false);
                    hr = createBuffer(device, ref inDesc, initDataPtr, out inputBuffer);
                }
                finally
                {
                    Marshal.FreeHGlobal(initDataPtr);
                }
                if (hr < 0)
                {
                    result.ErrorMessage = string.Format("CreateBuffer(input) failed (HRESULT 0x{0:X8})", hr);
                    return result;
                }

                var outDesc = inDesc; // same layout, no initial data
                hr = createBuffer(device, ref outDesc, IntPtr.Zero, out outputBuffer);
                if (hr < 0)
                {
                    result.ErrorMessage = string.Format("CreateBuffer(output) failed (HRESULT 0x{0:X8})", hr);
                    return result;
                }

                var stagingDesc = new D3D11_BUFFER_DESC
                {
                    ByteWidth = byteWidth,
                    Usage = D3D11_USAGE_STAGING,
                    BindFlags = 0,
                    CPUAccessFlags = D3D11_CPU_ACCESS_READ,
                    MiscFlags = 0,
                    StructureByteStride = 0
                };
                hr = createBuffer(device, ref stagingDesc, IntPtr.Zero, out stagingBuffer);
                if (hr < 0)
                {
                    result.ErrorMessage = string.Format("CreateBuffer(staging) failed (HRESULT 0x{0:X8})", hr);
                    return result;
                }

                var createUav = GetMethod<CreateUnorderedAccessViewDelegate>(device, Slot_Device_CreateUnorderedAccessView);
                var inUavDesc = new D3D11_UNORDERED_ACCESS_VIEW_DESC { Format = 0, ViewDimension = 1, FirstElement = 0, NumElements = (uint)count, Flags = 0 };
                hr = createUav(device, inputBuffer, ref inUavDesc, out inputUav);
                if (hr < 0)
                {
                    result.ErrorMessage = string.Format("CreateUnorderedAccessView(input) failed (HRESULT 0x{0:X8})", hr);
                    return result;
                }
                var outUavDesc = inUavDesc;
                hr = createUav(device, outputBuffer, ref outUavDesc, out outputUav);
                if (hr < 0)
                {
                    result.ErrorMessage = string.Format("CreateUnorderedAccessView(output) failed (HRESULT 0x{0:X8})", hr);
                    return result;
                }

                var csSetShader = GetMethod<CSSetShaderDelegate>(context, Slot_Context_CSSetShader);
                csSetShader(context, computeShader, IntPtr.Zero, 0);

                var csSetUavs = GetMethod<CSSetUnorderedAccessViewsDelegate>(context, Slot_Context_CSSetUnorderedAccessViews);
                IntPtr uavArray = Marshal.AllocHGlobal(IntPtr.Size * 2);
                try
                {
                    Marshal.WriteIntPtr(uavArray, 0, inputUav);
                    Marshal.WriteIntPtr(uavArray, IntPtr.Size, outputUav);
                    csSetUavs(context, 0, 2, uavArray, IntPtr.Zero);
                }
                finally
                {
                    Marshal.FreeHGlobal(uavArray);
                }

                uint threadGroups = (uint)((count + 63) / 64);
                var dispatch = GetMethod<DispatchDelegate>(context, Slot_Context_Dispatch);
                dispatch(context, threadGroups, 1, 1);

                var copyResource = GetMethod<CopyResourceDelegate>(context, Slot_Context_CopyResource);
                copyResource(context, stagingBuffer, outputBuffer);

                var map = GetMethod<MapDelegate>(context, Slot_Context_Map);
                D3D11_MAPPED_SUBRESOURCE mapped;
                hr = map(context, stagingBuffer, 0, D3D11_MAP_READ, 0, out mapped);
                if (hr < 0)
                {
                    if (hr == DXGI_ERROR_DEVICE_REMOVED)
                    {
                        result.DeviceLost = true;
                        var getReason = GetMethod<GetDeviceRemovedReasonDelegate>(device, Slot_Device_GetDeviceRemovedReason);
                        int reason = getReason(device);
                        result.ErrorMessage = string.Format("ERROR_DEVICE_LOST while mapping the result buffer (removed reason 0x{0:X8}) - likely a TDR (driver timeout/reset)", reason);
                    }
                    else
                    {
                        result.ErrorMessage = string.Format("Map(staging) failed (HRESULT 0x{0:X8})", hr);
                    }
                    return result;
                }

                uint[] gpuResult = new uint[count];
                // Marshal.Copy has no uint[] overload; copy as int[] and reinterpret bit-for-bit.
                var tmp = new int[count];
                Marshal.Copy(mapped.pData, tmp, 0, count);
                for (int i = 0; i < count; i++) { gpuResult[i] = unchecked((uint)tmp[i]); }

                var unmap = GetMethod<UnmapDelegate>(context, Slot_Context_Unmap);
                unmap(context, stagingBuffer, 0);

                long mismatches = 0;
                for (int i = 0; i < count; i++)
                {
                    uint expected = ComputeReference(inputData[i], (uint)i);
                    if (gpuResult[i] != expected) { mismatches++; }
                }

                result.MismatchCount = mismatches;
                result.Success = true;
                return result;
            }
            catch (Exception ex)
            {
                result.ErrorMessage = "Unexpected exception: " + ex.Message;
                return result;
            }
            finally
            {
                if (inputPin.IsAllocated) inputPin.Free();
                Release(inputUav);
                Release(outputUav);
                Release(inputBuffer);
                Release(outputBuffer);
                Release(stagingBuffer);
                Release(computeShader);
                Release(shaderBlob);
                Release(errorBlob);
                Release(context);
                Release(device);
            }
        }
    
        // ------------------------------------------------------------------
        // Sustained GPU load (GPU Load / Thermal Validation, combined system
        // test). The verification path above creates a device and runs ONE
        // tiny dispatch, which barely loads a real GPU. This path keeps one
        // device for a whole time slice and runs a heavy integer kernel
        // (each thread loops ROUNDS times) back to back. The number of rounds
        // is calibrated so one dispatch takes about TargetDispatchMs - long
        // enough to keep the GPU busy, far below the 2 s Windows TDR limit.
        // Every few dispatches the output is read back and a rotating sample
        // of elements is compared bit-exactly against the CPU reference.
        // ------------------------------------------------------------------

        public class LoadResult
        {
            public bool Success;
            public bool DeviceLost;
            public bool UsedWarp;
            public int FeatureLevel;
            public int ElementCount;
            public int Rounds;
            public long Dispatches;
            public long VerifiedValues;
            public long MismatchCount;
            public double LastDispatchMs;
            public string ErrorMessage = "";
        }

        private const double TargetDispatchMs = 150.0;
        private const int MaxRounds = 1 << 22;

        private const string LoadShaderTemplate = @"
RWStructuredBuffer<uint> Input : register(u0);
RWStructuredBuffer<uint> Output : register(u1);

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID)
{
    uint idx = dtid.x;
    uint r = Input[idx];
    [loop]
    for (uint k = 0; k < __ROUNDS__u; k++)
    {
        r = (r << 13) | (r >> 19);
        r = r ^ 0x9E3779B9u;
        r = r * 2654435761u + idx + k;
        r = (r >> 7) | (r << 25);
    }
    Output[idx] = r ^ (idx * 0x85EBCA6Bu);
}
";

        // Bit-exact CPU reference of the load kernel (uint wraps like HLSL uint).
        public static uint ComputeLoadReference(uint v, uint idx, int rounds)
        {
            uint r = v;
            for (uint k = 0; k < (uint)rounds; k++)
            {
                r = (r << 13) | (r >> 19);
                r = r ^ 0x9E3779B9u;
                r = unchecked(r * 2654435761u + idx + k);
                r = (r >> 7) | (r << 25);
            }
            return r ^ unchecked(idx * 0x85EBCA6Bu);
        }

        private static IntPtr CompileComputeShader(IntPtr device, string source, string target, out string error)
        {
            error = "";
            IntPtr shaderBlob = IntPtr.Zero, errorBlob = IntPtr.Zero, shader = IntPtr.Zero;
            try
            {
                int hr = D3DCompile(source, (UIntPtr)source.Length, "hs_gpu_load.hlsl", IntPtr.Zero, IntPtr.Zero, "CSMain", target, 0, 0, out shaderBlob, out errorBlob);
                if (hr < 0)
                {
                    string detail = "";
                    if (errorBlob != IntPtr.Zero)
                    {
                        var getPtr = GetMethod<GetBufferPointerDelegate>(errorBlob, Slot_Blob_GetBufferPointer);
                        var getSize = GetMethod<GetBufferSizeDelegate>(errorBlob, Slot_Blob_GetBufferSize);
                        detail = Marshal.PtrToStringAnsi(getPtr(errorBlob), (int)getSize(errorBlob));
                    }
                    error = string.Format("D3DCompile failed (HRESULT 0x{0:X8}): {1}", hr, detail);
                    return IntPtr.Zero;
                }
                var blobPtr = GetMethod<GetBufferPointerDelegate>(shaderBlob, Slot_Blob_GetBufferPointer);
                var blobSize = GetMethod<GetBufferSizeDelegate>(shaderBlob, Slot_Blob_GetBufferSize);
                var createComputeShader = GetMethod<CreateComputeShaderDelegate>(device, Slot_Device_CreateComputeShader);
                hr = createComputeShader(device, blobPtr(shaderBlob), blobSize(shaderBlob), IntPtr.Zero, out shader);
                if (hr < 0)
                {
                    error = string.Format("CreateComputeShader failed (HRESULT 0x{0:X8})", hr);
                    return IntPtr.Zero;
                }
                return shader;
            }
            finally
            {
                Release(shaderBlob);
                Release(errorBlob);
            }
        }

        // Copies the output to the staging buffer and maps it; mapping waits
        // for all queued dispatches, so this is also the synchronization point.
        private static int ReadBack(IntPtr device, IntPtr context, IntPtr stagingBuffer, IntPtr outputBuffer, int[] target, LoadResult result)
        {
            var copyResource = GetMethod<CopyResourceDelegate>(context, Slot_Context_CopyResource);
            copyResource(context, stagingBuffer, outputBuffer);
            var map = GetMethod<MapDelegate>(context, Slot_Context_Map);
            D3D11_MAPPED_SUBRESOURCE mapped;
            int hr = map(context, stagingBuffer, 0, D3D11_MAP_READ, 0, out mapped);
            if (hr < 0)
            {
                if (hr == DXGI_ERROR_DEVICE_REMOVED)
                {
                    result.DeviceLost = true;
                    var getReason = GetMethod<GetDeviceRemovedReasonDelegate>(device, Slot_Device_GetDeviceRemovedReason);
                    result.ErrorMessage = string.Format("ERROR_DEVICE_LOST under sustained load (removed reason 0x{0:X8}) - likely a TDR (driver timeout/reset)", getReason(device));
                }
                else
                {
                    result.ErrorMessage = string.Format("Map(staging) failed (HRESULT 0x{0:X8})", hr);
                }
                return hr;
            }
            Marshal.Copy(mapped.pData, target, 0, target.Length);
            var unmap = GetMethod<UnmapDelegate>(context, Slot_Context_Unmap);
            unmap(context, stagingBuffer, 0);
            return 0;
        }

        public static LoadResult RunLoadSlice(int elementCount, int rounds, int sliceMilliseconds, int sampleCount, int seed)
        {
            var result = new LoadResult();
            int count = Math.Max(64, (elementCount / 64) * 64);
            result.ElementCount = count;
            IntPtr device = IntPtr.Zero, context = IntPtr.Zero, shader = IntPtr.Zero;
            IntPtr inputBuffer = IntPtr.Zero, outputBuffer = IntPtr.Zero, stagingBuffer = IntPtr.Zero;
            IntPtr inputUav = IntPtr.Zero, outputUav = IntPtr.Zero;
            GCHandle inputPin = default(GCHandle);

            try
            {
                int hr = D3D11CreateDevice(IntPtr.Zero, D3D_DRIVER_TYPE_HARDWARE, IntPtr.Zero, 0, IntPtr.Zero, 0, 7, out device, out result.FeatureLevel, out context);
                if (hr < 0)
                {
                    result.UsedWarp = true;
                    hr = D3D11CreateDevice(IntPtr.Zero, D3D_DRIVER_TYPE_WARP, IntPtr.Zero, 0, IntPtr.Zero, 0, 7, out device, out result.FeatureLevel, out context);
                }
                if (hr < 0)
                {
                    result.ErrorMessage = string.Format("D3D11CreateDevice failed (HRESULT 0x{0:X8})", hr);
                    return result;
                }
                if (result.FeatureLevel < D3D_FEATURE_LEVEL_10_0)
                {
                    result.ErrorMessage = string.Format("GPU feature level 0x{0:X} is below the minimum required for compute shaders", result.FeatureLevel);
                    return result;
                }
                string target = result.FeatureLevel >= D3D_FEATURE_LEVEL_11_0 ? "cs_5_0" : "cs_4_0";

                uint[] input = new uint[count];
                var random = new Random(seed);
                for (int i = 0; i < count; i++) { input[i] = (uint)random.Next() ^ ((uint)random.Next() << 16); }
                inputPin = GCHandle.Alloc(input, GCHandleType.Pinned);

                var createBuffer = GetMethod<CreateBufferDelegate>(device, Slot_Device_CreateBuffer);
                var bufferDesc = new D3D11_BUFFER_DESC
                {
                    ByteWidth = (uint)(count * 4),
                    Usage = D3D11_USAGE_DEFAULT,
                    BindFlags = D3D11_BIND_UNORDERED_ACCESS,
                    CPUAccessFlags = 0,
                    MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
                    StructureByteStride = 4
                };
                var initData = new D3D11_SUBRESOURCE_DATA { pSysMem = inputPin.AddrOfPinnedObject(), SysMemPitch = 0, SysMemSlicePitch = 0 };
                IntPtr initDataPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(D3D11_SUBRESOURCE_DATA)));
                try
                {
                    Marshal.StructureToPtr(initData, initDataPtr, false);
                    hr = createBuffer(device, ref bufferDesc, initDataPtr, out inputBuffer);
                }
                finally
                {
                    Marshal.FreeHGlobal(initDataPtr);
                }
                if (hr < 0) { result.ErrorMessage = string.Format("CreateBuffer(input) failed (HRESULT 0x{0:X8})", hr); return result; }
                var outDesc = bufferDesc;
                hr = createBuffer(device, ref outDesc, IntPtr.Zero, out outputBuffer);
                if (hr < 0) { result.ErrorMessage = string.Format("CreateBuffer(output) failed (HRESULT 0x{0:X8})", hr); return result; }
                var stagingDesc = new D3D11_BUFFER_DESC
                {
                    ByteWidth = (uint)(count * 4),
                    Usage = D3D11_USAGE_STAGING,
                    BindFlags = 0,
                    CPUAccessFlags = D3D11_CPU_ACCESS_READ,
                    MiscFlags = 0,
                    StructureByteStride = 0
                };
                hr = createBuffer(device, ref stagingDesc, IntPtr.Zero, out stagingBuffer);
                if (hr < 0) { result.ErrorMessage = string.Format("CreateBuffer(staging) failed (HRESULT 0x{0:X8})", hr); return result; }

                var createUav = GetMethod<CreateUnorderedAccessViewDelegate>(device, Slot_Device_CreateUnorderedAccessView);
                var uavDesc = new D3D11_UNORDERED_ACCESS_VIEW_DESC { Format = 0, ViewDimension = 1, FirstElement = 0, NumElements = (uint)count, Flags = 0 };
                hr = createUav(device, inputBuffer, ref uavDesc, out inputUav);
                if (hr < 0) { result.ErrorMessage = string.Format("CreateUnorderedAccessView(input) failed (HRESULT 0x{0:X8})", hr); return result; }
                var outUavDesc = uavDesc;
                hr = createUav(device, outputBuffer, ref outUavDesc, out outputUav);
                if (hr < 0) { result.ErrorMessage = string.Format("CreateUnorderedAccessView(output) failed (HRESULT 0x{0:X8})", hr); return result; }

                var csSetShader = GetMethod<CSSetShaderDelegate>(context, Slot_Context_CSSetShader);
                var csSetUavs = GetMethod<CSSetUnorderedAccessViewsDelegate>(context, Slot_Context_CSSetUnorderedAccessViews);
                IntPtr uavArray = Marshal.AllocHGlobal(IntPtr.Size * 2);
                try
                {
                    Marshal.WriteIntPtr(uavArray, 0, inputUav);
                    Marshal.WriteIntPtr(uavArray, IntPtr.Size, outputUav);
                    csSetUavs(context, 0, 2, uavArray, IntPtr.Zero);
                }
                finally
                {
                    Marshal.FreeHGlobal(uavArray);
                }

                var dispatch = GetMethod<DispatchDelegate>(context, Slot_Context_Dispatch);
                uint groups = (uint)(count / 64);
                int[] output = new int[count];
                string compileError;
                var watch = new System.Diagnostics.Stopwatch();

                // Calibration (only when no rounds are given): grow the work per
                // dispatch until one dispatch is measurable, then scale it to the
                // target duration.
                if (rounds <= 0)
                {
                    int probe = 16;
                    double probeMs = 0;
                    while (true)
                    {
                        Release(shader);
                        shader = CompileComputeShader(device, LoadShaderTemplate.Replace("__ROUNDS__", probe.ToString()), target, out compileError);
                        if (shader == IntPtr.Zero) { result.ErrorMessage = compileError; return result; }
                        csSetShader(context, shader, IntPtr.Zero, 0);
                        watch.Restart();
                        dispatch(context, groups, 1, 1);
                        if (ReadBack(device, context, stagingBuffer, outputBuffer, output, result) < 0) { return result; }
                        probeMs = watch.Elapsed.TotalMilliseconds;
                        if (probeMs >= 30.0 || probe >= MaxRounds) { break; }
                        probe = Math.Min(MaxRounds, probe * 4);
                    }
                    double scaled = probe * (TargetDispatchMs / Math.Max(1.0, probeMs));
                    rounds = (int)Math.Max(16.0, Math.Min((double)MaxRounds, scaled));
                }
                result.Rounds = rounds;

                Release(shader);
                shader = CompileComputeShader(device, LoadShaderTemplate.Replace("__ROUNDS__", rounds.ToString()), target, out compileError);
                if (shader == IntPtr.Zero) { result.ErrorMessage = compileError; return result; }
                csSetShader(context, shader, IntPtr.Zero, 0);

                var slice = System.Diagnostics.Stopwatch.StartNew();
                // Keep the CPU-side check short (about 40 million kernel rounds
                // per read back) so the GPU is not left idle while verifying;
                // the rotating offset still walks through all elements over time.
                long affordable = 40000000L / Math.Max(1, rounds);
                int sample = (int)Math.Max(16L, Math.Min((long)Math.Min(sampleCount, count), affordable));
                int stride = Math.Max(1, count / sample);
                int offset = 0;
                do
                {
                    // Three dispatches back to back keep the GPU busy; the read
                    // back of the last one is the verification point.
                    watch.Restart();
                    for (int d = 0; d < 3; d++)
                    {
                        dispatch(context, groups, 1, 1);
                        result.Dispatches++;
                    }
                    if (ReadBack(device, context, stagingBuffer, outputBuffer, output, result) < 0) { return result; }
                    result.LastDispatchMs = watch.Elapsed.TotalMilliseconds / 3.0;

                    for (int j = 0; j < sample; j++)
                    {
                        int i = (j * stride + offset) % count;
                        uint expected = ComputeLoadReference(input[i], (uint)i, rounds);
                        if (unchecked((uint)output[i]) != expected) { result.MismatchCount++; }
                        result.VerifiedValues++;
                    }
                    offset = (offset + 1) % stride;
                }
                while (slice.ElapsedMilliseconds < sliceMilliseconds);

                result.Success = true;
                return result;
            }
            catch (Exception ex)
            {
                result.ErrorMessage = "Unexpected exception: " + ex.Message;
                return result;
            }
            finally
            {
                if (inputPin.IsAllocated) inputPin.Free();
                Release(inputUav);
                Release(outputUav);
                Release(inputBuffer);
                Release(outputBuffer);
                Release(stagingBuffer);
                Release(shader);
                Release(context);
                Release(device);
            }
        }
    }
}
