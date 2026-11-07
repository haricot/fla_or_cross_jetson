/*
 * R4-P4 JetPack native ABI / SM87 device smoke test.
 *
 * Compiled with Ubuntu 24.04 aarch64-linux-gnu-gcc, linked to the signed
 * NVIDIA L4T 39.2.1 libcuda.so.1. CUDA GPU code is *reused* from the pinned
 * Nixpkgs saxpy CUDA 13.2 R4-P2 ELF, not recompiled in this phase.
 *
 * This file intentionally uses only the documented C CUDA Driver ABI. It
 * does not embed third-party CUDA headers or depend on CUDA runtime stubs.
 */
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

typedef int CUresult;
typedef int CUdevice;
typedef unsigned long long CUdeviceptr;
typedef struct CUctx_st *CUcontext;
typedef struct CUmod_st *CUmodule;
typedef struct CUfunc_st *CUfunction;
typedef struct CUstream_st *CUstream;

extern CUresult cuInit(unsigned int flags);
extern CUresult cuDriverGetVersion(int *driver_version);
extern CUresult cuDeviceGet(CUdevice *device, int ordinal);
extern CUresult cuDeviceComputeCapability(int *major, int *minor, CUdevice device);
extern CUresult cuCtxCreate_v2(CUcontext *context, unsigned int flags, CUdevice device);
extern CUresult cuCtxDestroy_v2(CUcontext context);
extern CUresult cuModuleLoad(CUmodule *module, const char *fname);
extern CUresult cuModuleUnload(CUmodule module);
extern CUresult cuModuleGetFunction(CUfunction *function, CUmodule module, const char *name);
extern CUresult cuMemAlloc_v2(CUdeviceptr *dptr, size_t bytesize);
extern CUresult cuMemFree_v2(CUdeviceptr dptr);
extern CUresult cuMemcpyHtoD_v2(CUdeviceptr dst, const void *src, size_t count);
extern CUresult cuMemcpyDtoH_v2(void *dst, CUdeviceptr src, size_t count);
extern CUresult cuLaunchKernel(CUfunction function,
                               unsigned int grid_x, unsigned int grid_y, unsigned int grid_z,
                               unsigned int block_x, unsigned int block_y, unsigned int block_z,
                               unsigned int shared_bytes, CUstream stream,
                               void **kernel_params, void **extra);
extern CUresult cuCtxSynchronize(void);
extern CUresult cuGetErrorName(CUresult error, const char **name);

/* Exactly matches pinned nixpkgs saxpy.cu: saxpy(int,float,float*,float*). */
#define KERNEL_SYMBOL "_Z5saxpyifPfS_"
#define COUNT 1024

static int check(CUresult rc, const char *action) {
    if (rc == 0) return 0;
    const char *name = NULL;
    if (cuGetErrorName(rc, &name) != 0 || name == NULL) name = "unknown";
    fprintf(stderr, "R4_P4_CUDA_FAIL=%s code=%d name=%s\n", action, rc, name);
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s saxpy-sm87.cubin\n", argv[0]);
        return 2;
    }

    CUcontext context = NULL;
    CUmodule module = NULL;
    CUdeviceptr device_x = 0, device_y = 0;
    int failed = 1;

    int driver_version = 0;
    CUdevice device = -1;
    int major = 0, minor = 0;

    if (check(cuInit(0), "cuInit")) goto done;
    if (check(cuDriverGetVersion(&driver_version), "cuDriverGetVersion")) goto done;
    if (check(cuDeviceGet(&device, 0), "cuDeviceGet")) goto done;
    if (check(cuDeviceComputeCapability(&major, &minor, device), "cuDeviceComputeCapability")) goto done;
    printf("R4_P4_DEVICE_CUDA_API=%d compute=%d.%d\n", driver_version, major, minor);
    if (major != 8 || minor != 7) {
        fprintf(stderr, "R4_P4_REJECT=NOT_SM87_TARGET\n");
        goto done;
    }

    if (check(cuCtxCreate_v2(&context, 0, device), "cuCtxCreate")) goto done;
    if (check(cuModuleLoad(&module, argv[1]), "cuModuleLoad")) goto done;

    CUfunction kernel = NULL;
    if (check(cuModuleGetFunction(&kernel, module, KERNEL_SYMBOL), "cuModuleGetFunction")) goto done;

    const int n = COUNT;
    const float a = 2.0f;
    float host_x[COUNT], host_y[COUNT];
    for (int i = 0; i < n; ++i) {
        host_x[i] = 1.0f;
        host_y[i] = 2.0f;
    }
    if (check(cuMemAlloc_v2(&device_x, sizeof(host_x)), "cuMemAlloc_x")) goto done;
    if (check(cuMemAlloc_v2(&device_y, sizeof(host_y)), "cuMemAlloc_y")) goto done;
    if (check(cuMemcpyHtoD_v2(device_x, host_x, sizeof(host_x)), "cuMemcpyHtoD_x")) goto done;
    if (check(cuMemcpyHtoD_v2(device_y, host_y, sizeof(host_y)), "cuMemcpyHtoD_y")) goto done;

    void *params[] = {(void *)&n, (void *)&a, &device_x, &device_y};
    if (check(cuLaunchKernel(kernel, (n + 255u) / 256u, 1, 1, 256, 1, 1,
                             0, NULL, params, NULL), "cuLaunchKernel")) goto done;
    if (check(cuCtxSynchronize(), "cuCtxSynchronize")) goto done;
    if (check(cuMemcpyDtoH_v2(host_y, device_y, sizeof(host_y)), "cuMemcpyDtoH_y")) goto done;

    float max_error = 0.0f;
    for (int i = 0; i < n; ++i) {
        float error = host_y[i] - 4.0f;
        if (error < 0.0f) error = -error;
        if (error > max_error) max_error = error;
    }
    printf("R4_P4_SAXPY_MAX_ABS_ERROR=%g\n", (double)max_error);
    if (max_error <= 1e-5f) {
        puts("R4_P4_DEVICE_SM87_SAXPY=PASS");
        failed = 0;
    } else {
        fputs("R4_P4_DEVICE_SM87_SAXPY=FAIL_NUMERIC\n", stderr);
    }

done:
    if (device_y) (void)cuMemFree_v2(device_y);
    if (device_x) (void)cuMemFree_v2(device_x);
    if (module) (void)cuModuleUnload(module);
    if (context) (void)cuCtxDestroy_v2(context);
    return failed;
}
