variable "RUST_TOOLCHAIN" { default = "stable" }
variable "CUDA_VERSION" { default = "13.3" }
variable "CUDA_VERSION_FULL" { default = "13.3.0" }
variable "CUDA_CROSS_PACKAGE" { default = "cuda-cross-sbsa-13-3" }
variable "CUDA_CROSS_REPO" { default = "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/cross-linux-sbsa" }
variable "CUDA_KEYRING_VERSION" { default = "1.1-1" }
variable "CROSS_IMAGE" { default = "fla-or-cross-jetson:jp721-cuda133" }
variable "CROSS_IMAGE_FINGERPRINT" { default = "unknown" }
variable "SDK_MANAGER_BOOTSTRAP_IMAGE" { default = "ubuntu:24.04" }
variable "SDK_MANAGER_APT_DISTRO" { default = "ubuntu2404" }
variable "SDK_MANAGER_APT_VERSION_PREFIX" { default = "26.1" }
variable "SDK_MANAGER_IMAGE" { default = "fla-or-cross-jetson-sdkm:jp721-sdkm261" }
variable "SDK_MANAGER_IMAGE_FINGERPRINT" { default = "unknown" }

target "cross" {
  context = "."
  dockerfile = "containers/cross.Dockerfile"
  platforms = ["linux/amd64"]
  tags = [CROSS_IMAGE]
  args = {
    RUST_TOOLCHAIN = RUST_TOOLCHAIN
    CUDA_VERSION = CUDA_VERSION
    CUDA_VERSION_FULL = CUDA_VERSION_FULL
    CUDA_CROSS_PACKAGE = CUDA_CROSS_PACKAGE
    CUDA_CROSS_REPO = CUDA_CROSS_REPO
    CUDA_KEYRING_VERSION = CUDA_KEYRING_VERSION
    CROSS_IMAGE_FINGERPRINT = CROSS_IMAGE_FINGERPRINT
  }
  output = ["type=docker"]
}

target "sdkmanager" {
  context = "."
  dockerfile = "containers/sdkmanager.Dockerfile"
  platforms = ["linux/amd64"]
  tags = [SDK_MANAGER_IMAGE]
  args = {
    SDK_MANAGER_BOOTSTRAP_IMAGE = SDK_MANAGER_BOOTSTRAP_IMAGE
    SDK_MANAGER_APT_DISTRO = SDK_MANAGER_APT_DISTRO
    SDK_MANAGER_APT_VERSION_PREFIX = SDK_MANAGER_APT_VERSION_PREFIX
    SDK_MANAGER_IMAGE_FINGERPRINT = SDK_MANAGER_IMAGE_FINGERPRINT
  }
  output = ["type=docker"]
}
