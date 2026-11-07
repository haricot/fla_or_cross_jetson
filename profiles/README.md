# Jetson platform profiles — fix14

Built-in profiles target JetPack 7.2.1 / Jetson Linux R39.2.1.

Authoritative NVIDIA references used for board configuration names and Force Recovery USB product IDs:

- Jetson Linux R39.2.1 Quick Start / Jetson Modules and Configurations:
  https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/IN/QuickStart.html
- CUDA GPU Compute Capability:
  https://developer.nvidia.com/cuda/gpus
- CUDA for Tegra 13.3 / CUDA Upgrade Package:
  https://docs.nvidia.com/cuda/cuda-for-tegra-appnote/

`PLATFORM_HARDWARE_TESTED=yes` means this project itself completed the end-to-end
headless flash and post-flash gates on that profile. It does not mean NVIDIA
certification. At fix14, only `orin-nano-super` has that status.

Use:

```bash
./jetsonctl platform list
./jetsonctl platform show orin-nano-super
./jetsonctl --platform agx-orin profile
```

`--nvidia-board-config` is intentionally an expert override. It does not change
SoC, recovery PID, CUDA architecture or flash layout; use a matching `--platform`
whenever a built-in profile exists.
