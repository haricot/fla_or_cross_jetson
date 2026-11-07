/*
 * Host-side AArch64 link probe, never executed in CI.
 *
 * We deliberately use the tiny, stable CUDA Runtime C ABI here, without
 * requiring a cross-host CUDA compiler. This does not contain an SM87 kernel;
 * the verified SM87 cubin is supplied separately by the R4-P2 artifact.
 */
#include <stdio.h>

/* cudaError_t is an enum (C ABI: int); function has C linkage. */
extern int cudaRuntimeGetVersion(int *runtime_version);

int main(void) {
    int runtime_version = 0;
    if (cudaRuntimeGetVersion(&runtime_version) != 0) {
        return 2;
    }
    printf("CUDA runtime version: %d\n", runtime_version);
    return runtime_version / 1000 == 13 ? 0 : 3;
}
