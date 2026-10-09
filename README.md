# omx-kernel-build

Build scripts for a natively-compiled **Clang/LLVM + ThinLTO + AutoFDO + Propeller** XanMod kernel on
**OpenMandriva** — from any branch or tag in the XanMod git tree.

This is a full profile-guided optimization (PGO) pipeline, not just a config tweak. The end result is a
kernel built with your own CPU's real execution profiles baked in.

## Scripts

| Script | Purpose |
|---|---|
| `OMX-Kernel-Build-Script-2.9.4.sh` | Main builder (current): fetches the XanMod tree, stamps the config, builds, packages, and installs RPMs |
| `OMX-Kernel-Build-Script-2.9.3.sh` | Previous release (kept for reference) |
| `OMX-Kernel-Build-Script-2.9.2.sh` | Previous release (kept for reference) |
| `OMX-Kernel-Build-Script-2.9.1.sh` | Previous release (kept for reference) |
| `OMX-Kernel-Build-Script-2.9.0.sh` | Previous release (kept for reference) |
| `omx-afdo-profile.sh` | Profiling companion: records branch samples with `perf`, converts them to AutoFDO/Propeller profiles |
| `omx-kernel-summary.sh` | Prints a compact, screenshot-friendly summary of how the running kernel was built (needs `zcat` — install `gzip-utils` or `zutils`) |

## Requirements

- OpenMandriva (x86_64), ~30 GiB free disk
- LLVM/Clang **19+** and `ld.lld` 19+ (AutoFDO/Propeller stages)
- `perf`, `llvm-profgen`, `llvm-profdata`
- `generate_propeller_profiles` from [google/llvm-propeller](https://github.com/google/llvm-propeller),
  or the prebuilt RPM below
- Bare metal recommended — hardware branch sampling (Intel LBR / AMD branch sampling) is required
  for profile collection

### Prebuilt llvm-propeller RPM (OpenMandriva)

Download from the [release page](https://github.com/ManOfMystery1981/omx-kernel-build/releases/tag/propeller-rpm-v1)
(mirror: https://mega.nz/file/O15hgTbA#BcdIRJEl2K69zrH-bhjow9ZtuKEyRR8ddquMDR5QZgU)

## Quick start

```bash
# 1. Plain optimized build (ThinLTO, native CPU tuning, 250 Hz)
./OMX-Kernel-Build-Script-2.9.4.sh --xanmod-7 -y
```

## The 4-pass PGO pipeline

Kernel PGO profiles are tied to the exact source, compiler, and config — the scripts record and verify
the build flags at every stage so a mismatched profile can never silently poison a build.

```bash
# Pass 1: build the AutoFDO-instrumented kernel and boot it
./OMX-Kernel-Build-Script-2.9.4.sh --xanmod-7 --autofdo -y
# ... reboot into it, then record a profile of your real workload:
sudo ./omx-afdo-profile.sh record /usr/src/kernels/$(uname -r)/vmlinux ~/afdo/run1.afdo 3600

# Pass 2 (optional): merge multiple workload profiles
./omx-afdo-profile.sh merge ~/afdo/final.afdo ~/afdo/run1.afdo ~/afdo/run2.afdo

# Pass 3: build the Propeller-labeled kernel with the AutoFDO profile, boot it, record again
./OMX-Kernel-Build-Script-2.9.4.sh --xanmod-7 --afdo-profile ~/afdo/final.afdo --propeller -y
# ... reboot, then:
sudo ./omx-afdo-profile.sh record-propeller /usr/src/kernels/$(uname -r)/vmlinux ~/afdo/prop 3600

# Pass 4: the final kernel — AutoFDO + Propeller profiles applied
./OMX-Kernel-Build-Script-2.9.4.sh --xanmod-7 \
  --afdo-profile ~/afdo/final.afdo \
  --propeller-profile ~/afdo/prop -y
```

The profiler verifies the `vmlinux` build-ID matches the running kernel before every recording, so you
can never profile the wrong binary by accident.

## OpenMandriva-specific fixes baked in

These are real distro quirks discovered the hard way, handled automatically:

- **OM's `ld.lld` defaults to `--gc-sections`/`--icf=safe`** (upstream doesn't), which discards
  `.bss..brk`, the x86 CPU-vendor table, and `kernel_info` — the kernel then dies in `setup_arch`.
  The script wraps `ld.lld` to pin `--icf=none --no-gc-sections`.
- **`-u kernel_info`** is injected into `arch/x86/boot/compressed/Makefile` so `bzImage` links.
- **`llvm-nm` is used for every build step** (2.9.1+). The old GNU-`nm` swap for bzImage is now
  opt-in (`--boot-hacks`) — mixing `nm` implementations between steps made Kconfig silently drop
  ThinLTO and rebuild the whole kernel without it.
- **Polly/pipeliner `-mllvm` flags** are stripped by the Clang wrapper (they break kernel builds).

## Output

Three RPMs land in `~/rpmbuild/RPMS`: the kernel, its modules, and `-devel` headers (DKMS-ready).
The installer verifies the installed packages are byte-identical to what was just built
(`BUILDTIME` check), then regenerates initrd and the GRUB config.

## Useful flags

- `--x86-64-v3` — distributable build for any x86-64-v3 CPU (drops `-march=native`)
- `--xanmod-config v3` — base on XanMod's own tuned config instead of the OM donor config
- `--tag 7.1.13` — pin an exact XanMod tag
- `--dry-run` / `--resume` / `--cleanup` — do what they say

## License

GNU GPL. No warranty.
