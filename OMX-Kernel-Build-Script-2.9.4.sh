#!/usr/bin/env bash
# omx-kernel v2.9.3
# GNU GPL. NO WARRANTY.
#
# Default: classic XanMod + OM donor .config
# Clang + ld.lld (ICF-safe) + ThinLTO + 250 Hz + native CPU tuning by default
# 2.9 adds selectable LLVM toolchain and distributable x86-64-v3 mode.
# Work tree under /tmp; RPMs under ~/rpmbuild
#
set -Eeuo pipefail

readonly PROGNAME="omx-kernel"
readonly VERSION="2.9.4"
readonly WORKDIR="${TMPDIR:-/tmp}/${PROGNAME}-work-${USER:-user}"
readonly LOG_DIR="${WORKDIR}/logs"
readonly DISK_MIN_GIB=30
readonly RPM_NAME="kernel-xanmod-desktop"
readonly RPM_TOPDIR="${HOME}/rpmbuild"
readonly XANMOD_GIT_GITLAB="https://gitlab.com/xanmod/linux.git"
readonly XANMOD_GIT_GITHUB="https://github.com/xanmod/linux.git"

XANMOD_GIT="${XANMOD_GIT_GITLAB}"
XANMOD_MAJOR=""
JOBS=2
THINLTO=1
FORCE_FETCH=0
DO_RESUME=0
USE_BFD=0
PLAIN_LLD=0   # default: ld.lld wrapper that pins --no-gc-sections --icf=none (OM lld GCs by default)
X86_LEVEL=""
NO_WRAPPERS=0
CCBIN="${HOME}/bin/clang-omx"
CXXBIN="${HOME}/bin/clang++-omx"
LLVM_ROOT="${LLVM_ROOT:-}"
LLVM_WHY=""
RUN_RPMLINT=0
SUDO_KEEPALIVE_PID=""
LLVM_BIN=""
LLVM_CLANG=""
LLVM_CLANGXX=""
LLVM_LLD=""
XANMOD_CFG=""
WANT_NATIVE=0
AUTOFDO=0
AFDO_PROFILE=""
PROPELLER=0
PROPELLER_PREFIX=""
AFDO_FORCE=0
DRY_RUN=0
NO_INSTALL=0
TREE_MODE=""
ASSUME_YES=0
FORCE_TAG=""
USER_SRPM=""
KEEP_TDA18212=0
NO_NATIVE=0
NO_BOOT_HACKS=1   # the GNU-nm swap is opt-in (--boot-hacks): it flips HAS_LTO_CLANG and rebuilds everything
LINKER=ld.lld
KERNEL_VER=""
KERNEL_VER_RPM=""
SAFE_TAG=""
TAG=""
GNUTAR=""

export OMX_KCFLAGS="-march=native -Wno-unknown-warning-option"
export OMX_KCPPFLAGS="-DCONFIG_X86_L1_CACHE_SHIFT=6"

readonly C_RESET=$'\033[0m' C_BOLD=$'\033[1m'
readonly C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_CYAN=$'\033[36m'

declare -A OM_PKG_MAP=(
  [elfutils-libelf-devel]=lib64elfutils-devel
  [openssl-devel]=lib64openssl-devel
  [dwarves]=lib64dwarves
  [ncurses-devel]=lib64ncurses-devel
)

readonly PKGLIST=(
  git make binutils clang lld llvm flex bison bc perl rsync
  elfutils-libelf-devel openssl-devel dwarves ncurses-devel
  rpm-build rpmdevtools tar zstd gnutar dracut cryptsetup xz cpio
)

log() {
  local level="$1" msg="$2" color
  case "$level" in
    INFO) color="${C_CYAN}" ;;
    WARN) color="${C_YELLOW}" ;;
    ERROR) color="${C_RED}" ;;
    OK) color="${C_GREEN}" ;;
    *) color="${C_RESET}" ;;
  esac
  printf '%s %b%-5s%b %s\n' "$(date +%H:%M:%S)" "$color" "$level" "$C_RESET" "$msg" >&2
}
info() { log INFO "$1"; }
warn() { log WARN "$1"; }
err() { log ERROR "$1"; }
ok() { log OK "$1"; }
die() { err "$1"; exit 1; }

ask() {
  local q="$1" def="${2:-n}" a
  if (( ASSUME_YES )) || [[ ! -t 0 ]]; then
    printf '%s' "$def"
    return 0
  fi
  printf '%b%s%b ' "$C_BOLD" "$q" "$C_RESET" >&2
  read -r -t 300 a || a="$def"
  printf '%s' "${a:-$def}"
}

help_menu() {
  cat <<EOF
${PROGNAME} v${VERSION}

Default: classic XanMod (GitLab) + OpenMandriva /boot config as module donor.
Work directory: ${WORKDIR}
RPMs: ${RPM_TOPDIR}/RPMS

Modes:
  --xanmod-7 | --xanmod | --classic   Classic XanMod (default)
  --hybrid | --srpm FILE              OM kernel SRPM base (optional)
  --tag TAG                           Explicit XanMod tag

Toolchain:
  --use-bfd           ld.bfd instead of ld.lld
  --xanmod-config V   Base on XanMod's own CONFIGS/xanmod/gcc/config_x86-64-V (V = v1..v4)
                      instead of the OM donor config. Only LTO, native, localversion and
                      IKHEADERS are stamped; HZ/preempt/NO_HZ etc. stay as XanMod ships them.
                      Native is OFF in this mode unless --native is also given.
  --v3 | --x86-level N  Stamp CONFIG_X86_64_VERSION=N (XanMod CPU level, 1-4) on top of any base config
  --x86-64-v3          Distributable x86-64-v3 build (level 3 + no -march=native)
  --llvm-root DIR      Use the LLVM/Clang toolchain in DIR/bin (default: /opt/llvm-propeller-23 for --propeller
                       builds if present, otherwise the system LLVM toolchain)
  --plain-lld         Raw selected LLVM ld.lld, no wrapper. DIAGNOSTIC ONLY: OM lld garbage-collects by
                      default and the resulting kernel crashes in setup_arch
  --lld-wrapper       (default) ld.lld wrapper pinning --no-gc-sections --icf=none
  --no-wrappers       Use the selected LLVM clang/clang++ directly (the ld.lld wrapper stays)
  Profile-guided pipeline (kernel docs: build-afdo, train-afdo, build-propeller, train-propeller,
  build-optimized). Every stage must use the SAME other flags; the script records and checks them.
    stage 1  --autofdo                              boot it, then: omx-afdo-profile.sh record ...
    stage 2  --afdo-profile F.afdo [--propeller]    (plain AutoFDO build, or the Propeller "labels" build)
    stage 3  --afdo-profile F.afdo --propeller-profile PREFIX   final build (AutoFDO + Propeller)
  --autofdo           CONFIG_AUTOFDO_CLANG=y, no profile. vmlinux saved to ~/rpmbuild/AFDO/. Clang >= 19.
  --afdo-profile FILE CLANG_AUTOFDO_PROFILE=FILE (implies --autofdo)
  --propeller         CONFIG_PROPELLER_CLANG=y (implies --autofdo; needs --afdo-profile and ld.lld >= 19).
                      Builds the labeled kernel you profile with: omx-afdo-profile.sh record-propeller
  --propeller-profile PREFIX
                      CLANG_PROPELLER_PROFILE_PREFIX=PREFIX (needs PREFIX_cc_profile.txt and
                      PREFIX_ld_profile.txt; implies --propeller). Use the same --afdo-profile as stage 2.
  --afdo-force        Continue even if the recorded flags of the previous stage differ
  --native            With --xanmod-config: also enable CONFIG_X86_NATIVE_CPU
                      NOTE: -march=native / X86_NATIVE_CPU tune for the machine you BUILD on; the kernel
                      may not boot on other CPUs.
  --force-thinlto     ThinLTO on (default)
  --no-thinlto        ThinLTO off
  --jobs N            Parallelism (default 2)
  --no-native         Drop -march=native and CONFIG_X86_NATIVE_CPU
  --rpmlint           Run rpmlint on the new RPMs AFTER installing (slow: ~5 min; full output goes to a log file)
  --boot-hacks        Re-enable the old GNU-nm swap for bzImage (NOT with ThinLTO: it silently drops LTO and rebuilds)
  --no-boot-hacks     (default) llvm-nm everywhere; kept for old command lines
                      (implies --force-fetch so the tree is re-cloned unpatched)
  --bisect            --no-thinlto --no-native --no-boot-hacks (boot-debug build)

Other:
  --force-fetch | --resume | --cleanup | --dry-run | --no-install | -y

Examples:
  $0 --xanmod-7 --force-thinlto -y
  $0 --xanmod-7 --tag 7.1.13 --afdo-profile ~/afdo/xanmod-7.1.13-autofdo-heavy-1h.afdo --propeller --force-thinlto -y
  $0 --xanmod-7 --tag 7.1.13 --x86-64-v3 --afdo-profile PROFILE.afdo --propeller-profile PREFIX --force-thinlto -y
EOF
}

select_llvm_toolchain() {
  local prop="${PROPELLER_LLVM_ROOT:-/opt/llvm-propeller-23}"
  LLVM_WHY="--llvm-root"
  if [[ -z "$LLVM_ROOT" ]]; then
    # Propeller builds use the matching toolchain of the Propeller tools; everything else keeps
    # the system LLVM that has actually been boot-tested.
    if (( PROPELLER )) && [[ -x "${prop}/bin/clang" && -x "${prop}/bin/ld.lld" ]]; then
      LLVM_ROOT="$prop"; LLVM_WHY="Propeller build"
    else
      LLVM_ROOT=/usr; LLVM_WHY="system default"
    fi
  fi
  LLVM_BIN="${LLVM_ROOT}/bin"
  LLVM_CLANG="${LLVM_BIN}/clang"
  LLVM_CLANGXX="${LLVM_BIN}/clang++"
  LLVM_LLD="${LLVM_BIN}/ld.lld"
  [[ -x "$LLVM_CLANG" ]] || die "Clang not found: ${LLVM_CLANG}"
  [[ -x "$LLVM_CLANGXX" ]] || die "clang++ not found: ${LLVM_CLANGXX}"
  [[ -x "$LLVM_LLD" ]] || die "ld.lld not found: ${LLVM_LLD}"
  export PATH="${LLVM_BIN}:${HOME}/bin:${PATH}"
}

install_wrappers_all() {
  mkdir -p "${HOME}/bin"
  export OMX_LLVM_CLANG="$LLVM_CLANG"
  export OMX_LLVM_CLANGXX="$LLVM_CLANGXX"
  export OMX_LLVM_LLD="$LLVM_LLD"
  # Strip Polly / bad -mllvm
  cat > "${HOME}/bin/clang-omx" <<'WRAP'
#!/usr/bin/env bash
args=(); prev=""
for a in "$@"; do
  if [[ "$prev" == "-mllvm" ]]; then
    prev=""
    case "$a" in *polly*|*pipeliner*) continue ;; *) args+=("-mllvm" "$a"); continue ;; esac
  fi
  case "$a" in
    -mllvm) prev="-mllvm" ;;
    -mllvm=*polly*|-mllvm=*pipeliner*) ;;
    *) args+=("$a") ;;
  esac
done
[[ -n "$prev" ]] && args+=("$prev")
exec "${OMX_LLVM_CLANG}" "${args[@]}"
WRAP
  cat > "${HOME}/bin/clang++-omx" <<'WRAP'
#!/usr/bin/env bash
args=(); prev=""
for a in "$@"; do
  if [[ "$prev" == "-mllvm" ]]; then
    prev=""
    case "$a" in *polly*|*pipeliner*) continue ;; *) args+=("-mllvm" "$a"); continue ;; esac
  fi
  case "$a" in
    -mllvm) prev="-mllvm" ;;
    -mllvm=*polly*|-mllvm=*pipeliner*) ;;
    *) args+=("$a") ;;
  esac
done
[[ -n "$prev" ]] && args+=("$prev")
exec "${OMX_LLVM_CLANGXX}" "${args[@]}"
WRAP
  # ld.lld: OpenMandriva's lld 19.1.7 defaults to --gc-sections (and --icf=safe), unlike
  # upstream. Under --gc-sections it discards .bss..brk, the x86 CPU-vendor table and
  # kernel_info, and the kernel dies in setup_arch (BUG in extend_brk). Pin the safe defaults.
  cat > "${HOME}/bin/ld.lld" <<'WRAP'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  case "$a" in --icf|--icf=*|--gc-sections|--no-gc-sections) continue ;; esac
  args+=("$a")
done
exec "${OMX_LLVM_LLD}" "${args[@]}" --icf=none --no-gc-sections
WRAP
  sed -i "s|\${OMX_LLVM_CLANG}|${LLVM_CLANG}|"     "${HOME}/bin/clang-omx"
  sed -i "s|\${OMX_LLVM_CLANGXX}|${LLVM_CLANGXX}|" "${HOME}/bin/clang++-omx"
  sed -i "s|\${OMX_LLVM_LLD}|${LLVM_LLD}|"         "${HOME}/bin/ld.lld"
  chmod 0755 "${HOME}/bin/clang-omx" "${HOME}/bin/clang++-omx" "${HOME}/bin/ld.lld"
  export PATH="${HOME}/bin:${PATH}"
}

install_wrappers() {
  install_wrappers_all
  if (( NO_WRAPPERS )); then
    rm -f "${HOME}/bin/clang-omx" "${HOME}/bin/clang++-omx"
  fi
  if (( PLAIN_LLD )); then
    rm -f "${HOME}/bin/ld.lld"
  fi
}

setup_compiler() {
  select_llvm_toolchain
  install_wrappers
  if (( USE_BFD )); then
    LINKER=ld.bfd
    command -v ld.bfd >/dev/null || die "ld.bfd missing"
    warn "Using ld.bfd"
  elif (( PLAIN_LLD )); then
    LINKER="$LLVM_LLD"
    [[ -x "$LINKER" ]] || die "ld.lld missing: $LINKER"
    warn "Using plain ${LINKER} (no wrapper)"
  else
    LINKER="${HOME}/bin/ld.lld"
  fi
  if (( NO_WRAPPERS )); then
    CCBIN="$LLVM_CLANG"
    CXXBIN="$LLVM_CLANGXX"
  fi
  [[ -x "$CCBIN" ]] || die "Clang compiler missing: $CCBIN"
  [[ -x "$CXXBIN" ]] || die "C++ compiler missing: $CXXBIN"
  info "LLVM root: ${LLVM_ROOT} (${LLVM_WHY})"
  info "LLVM toolchain: $("${LLVM_CLANG}" --version | head -n1)"
  info "LLD toolchain:  $("${LLVM_LLD}" --version | head -n1)"
}

make_k_args() {
  MAKE_K=(
    ARCH=x86_64 SRCARCH=x86
    LLVM=1 LLVM_IAS=1
    CC="${CCBIN}"
    LD="${LINKER}"
    AR=llvm-ar NM=llvm-nm STRIP=llvm-strip
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf
    HOSTCC="${CCBIN}"
    HOSTCXX="${CXXBIN}"
    HOSTAR=llvm-ar HOSTLD="${LINKER}"
    "KCFLAGS=${OMX_KCFLAGS}"
    "KCPPFLAGS=${OMX_KCPPFLAGS}"
    ${AFDO_PROFILE:+"CLANG_AUTOFDO_PROFILE=${AFDO_PROFILE}"}
    ${PROPELLER_PREFIX:+"CLANG_PROPELLER_PROFILE_PREFIX=${PROPELLER_PREFIX}"}
  )
}

km() {
  env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS -u MAKEFLAGS \
    make -j"${JOBS}" "${MAKE_K[@]}" "$@"
}

km_ni() {
  local rc
  set +o pipefail
  yes '' 2>/dev/null | km "$@" >/dev/null
  rc=${PIPESTATUS[1]}
  set -o pipefail
  return "$rc"
}

preflight() {
  local disk_gib
  disk_gib="$(df -BG --output=avail "${TMPDIR:-/tmp}" 2>/dev/null | tail -1 | tr -dc '0-9')"
  [[ -n "$disk_gib" ]] || disk_gib="$(df -BG --output=avail "${HOME}" | tail -1 | tr -dc '0-9')"
  (( disk_gib >= DISK_MIN_GIB )) || die "Need >= ${DISK_MIN_GIB} GiB free (prefer /tmp)"
  command -v /usr/bin/nm >/dev/null || die "GNU nm required at /usr/bin/nm"
  setup_compiler
  make_k_args
  info "jobs=${JOBS} ThinLTO=${THINLTO} LD=${LINKER} work=${WORKDIR}"
}

check_deps() {
  local missing=() pkg resolved=()
  for pkg in "${PKGLIST[@]}"; do
    rpm -q "$pkg" &>/dev/null || missing+=("$pkg")
  done
  ((${#missing[@]} == 0)) && return 0
  for pkg in "${missing[@]}"; do
    resolved+=("${OM_PKG_MAP[$pkg]:-$pkg}")
  done
  sudo dnf install -y "${resolved[@]}" || die "deps failed"
}

ensure_gnutar() {
  if command -v gtar >/dev/null; then GNUTAR=$(command -v gtar)
  elif command -v gnutar >/dev/null; then GNUTAR=$(command -v gnutar)
  else GNUTAR=$(command -v tar)
  fi
  [[ -n "$GNUTAR" ]] || die "tar missing"
}

do_cleanup() {
  info "Removing ${WORKDIR} and related rpmbuild kernel trees..."
  rm -rf "${WORKDIR}"
  rm -rf "${RPM_TOPDIR}/BUILD/"*kernel* "${RPM_TOPDIR}/BUILDROOT/"* 2>/dev/null || true
  rm -f "${RPM_TOPDIR}/SPECS/${PROGNAME}.spec" \
        "${RPM_TOPDIR}/SOURCES/${RPM_NAME}-"*.tar \
        "${RPM_TOPDIR}/SOURCES/config-"* 2>/dev/null || true
  ok "Cleaned (next build will re-clone)"
}

patch_compressed_makefile() {
  local tree="$1" mf="${1}/arch/x86/boot/compressed/Makefile"
  [[ -f "$mf" ]] || return 0
  # REQUIRED with ld.lld: --gc-sections drops kernel_info from compressed/vmlinux, so
  # bzImage fails with "undefined symbol: ZO_kernel_info". Keep it with -u, inserted
  # ABOVE the trailing "-T" line (next to the existing -u efi_pe_entry).
  sed -i '/^LDFLAGS_vmlinux += -u kernel_info[[:space:]]*$/d' "$mf"
  sed -i '/^LDFLAGS_vmlinux += --undefined=kernel_info/d' "$mf"
  sed -i '/^LDFLAGS_vmlinux += -T[[:space:]]*$/i LDFLAGS_vmlinux += -u kernel_info' "$mf"
  grep -q -- '-u kernel_info' "$mf" || die "kernel_info retention not applied (Makefile layout changed)"
  # OPTIONAL hack (disabled by --no-boot-hacks): GNU nm for the offsets
  (( NO_BOOT_HACKS )) && return 0
  sed -i 's|\$(NM)|/usr/bin/nm|g' "$mf"
}

stamp_autofdo() {
  local f="$1"
  sed -i -e '/^CONFIG_AUTOFDO_CLANG=/d' -e '/^# CONFIG_AUTOFDO_CLANG /d' "$f"
  if (( AUTOFDO )); then echo 'CONFIG_AUTOFDO_CLANG=y' >> "$f"; fi
}

stamp_propeller() {
  local f="$1"
  sed -i -e '/^CONFIG_PROPELLER_CLANG=/d' -e '/^# CONFIG_PROPELLER_CLANG /d' "$f"
  if (( PROPELLER )); then echo 'CONFIG_PROPELLER_CLANG=y' >> "$f"; fi
}

stamp_minimal_config() {
  local f="${1}/.config"
  [[ -f "$f" ]] || die "No .config"
  sed -i \
    -e '/^CONFIG_LTO_/d' -e '/^# CONFIG_LTO_/d' \
    -e '/^CONFIG_LOCALVERSION_AUTO=/d' -e '/^# CONFIG_LOCALVERSION_AUTO /d' \
    -e '/^CONFIG_X86_NATIVE_CPU=/d' -e '/^# CONFIG_X86_NATIVE_CPU /d' \
    -e '/^CONFIG_IKHEADERS=/d' -e '/^# CONFIG_IKHEADERS /d' \
    -e '/^CONFIG_X86_64_VERSION=/d' \
    "$f"
  [[ -n "$X86_LEVEL" ]] && echo "CONFIG_X86_64_VERSION=${X86_LEVEL}" >> "$f"
  printf '%s\n' '# CONFIG_LOCALVERSION_AUTO is not set' '# CONFIG_IKHEADERS is not set' >> "$f"
  if (( NO_NATIVE )); then
    echo '# CONFIG_X86_NATIVE_CPU is not set' >> "$f"
  else
    echo 'CONFIG_X86_NATIVE_CPU=y' >> "$f"
  fi
  if (( THINLTO )); then
    printf '%s\n' '# CONFIG_LTO_NONE is not set' 'CONFIG_LTO_CLANG=y' 'CONFIG_LTO_CLANG_THIN=y' '# CONFIG_LTO_CLANG_FULL is not set' >> "$f"
  else
    echo 'CONFIG_LTO_NONE=y' >> "$f"
  fi
}

stamp_critical_config() {
  local f="${1}/.config"
  [[ -f "$f" ]] || die "No .config"
  stamp_autofdo "$f"
  stamp_propeller "$f"
  if [[ -n "$XANMOD_CFG" ]]; then stamp_minimal_config "$1"; return 0; fi
  sed -i \
    -e '/^CONFIG_64BIT=/d' -e '/^CONFIG_X86_64=/d' -e '/^CONFIG_X86_32=/d' \
    -e '/^CONFIG_X86_L1_CACHE_SHIFT=/d' -e '/^CONFIG_SMP=/d' \
    -e '/^CONFIG_MODULES=/d' -e '/^CONFIG_MODVERSIONS=/d' \
    -e '/^CONFIG_GENKSYMS=/d' -e '/^CONFIG_GENDWARFKSYMS=/d' \
    -e '/^CONFIG_HZ=/d' -e '/^CONFIG_HZ_1000=/d' -e '/^CONFIG_HZ_250=/d' \
    -e '/^CONFIG_HZ_PERIODIC=/d' -e '/^CONFIG_NO_HZ=/d' \
    -e '/^CONFIG_NO_HZ_IDLE=/d' -e '/^CONFIG_NO_HZ_FULL=/d' \
    -e '/^CONFIG_LTO_/d' -e '/^# CONFIG_LTO_/d' \
    -e '/^CONFIG_LOCALVERSION_AUTO=/d' -e '/^CONFIG_PREEMPT_DYNAMIC=/d' \
    -e '/^CONFIG_X86_NATIVE_CPU=/d' -e '/^# CONFIG_X86_NATIVE_CPU /d' \
    -e '/^CONFIG_DEBUG_INFO=/d' -e '/^CONFIG_DEBUG_INFO_NONE=/d' \
    -e '/^CONFIG_DEBUG_INFO_DWARF/d' -e '/^CONFIG_DEBUG_INFO_COMPRESSED/d' \
    -e '/^CONFIG_DEBUG_INFO_BTF=/d' -e '/^CONFIG_DEBUG_INFO_BTF_MODULES=/d' \
    -e '/^CONFIG_MODULE_ALLOW_BTF_MISMATCH=/d' -e '/^CONFIG_GDB_SCRIPTS=/d' \
    -e '/^CONFIG_BUILTIN_MODULE_RANGES=/d' \
    -e '/^CONFIG_LD_DEAD_CODE_ELIMINATION=/d' \
    -e '/^CONFIG_EARLY_PRINTK/d' -e '/^# CONFIG_EARLY_PRINTK/d' \
    -e '/^CONFIG_IKHEADERS=/d' -e '/^# CONFIG_IKHEADERS /d' \
    -e '/^CONFIG_X86_64_VERSION=/d' \
    "$f"
  [[ -n "$X86_LEVEL" ]] && echo "CONFIG_X86_64_VERSION=${X86_LEVEL}" >> "$f"
  cat >> "$f" <<'EOF'
CONFIG_64BIT=y
CONFIG_X86_64=y
# CONFIG_X86_32 is not set
CONFIG_X86_L1_CACHE_SHIFT=6
CONFIG_SMP=y
CONFIG_MODULES=y
CONFIG_MODVERSIONS=y
CONFIG_GENKSYMS=y
# CONFIG_GENDWARFKSYMS is not set
CONFIG_HZ=250
CONFIG_HZ_250=y
# CONFIG_HZ_1000 is not set
# CONFIG_HZ_PERIODIC is not set
CONFIG_NO_HZ=y
# CONFIG_NO_HZ_IDLE is not set
CONFIG_NO_HZ_FULL=y
CONFIG_PREEMPT_DYNAMIC=y
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF5=y
CONFIG_DEBUG_INFO_COMPRESSED_ZSTD=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_MODULE_ALLOW_BTF_MISMATCH=y
CONFIG_GDB_SCRIPTS=y
# CONFIG_BUILTIN_MODULE_RANGES is not set
# CONFIG_LD_DEAD_CODE_ELIMINATION is not set
CONFIG_EARLY_PRINTK=y
CONFIG_EARLY_PRINTK_EFI=y
# CONFIG_IKHEADERS is not set
EOF
  if (( NO_NATIVE )); then
    echo '# CONFIG_X86_NATIVE_CPU is not set' >> "$f"
  else
    echo 'CONFIG_X86_NATIVE_CPU=y' >> "$f"
  fi
  if (( THINLTO )); then
    cat >> "$f" <<'EOF'
# CONFIG_LTO_NONE is not set
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y
# CONFIG_LTO_CLANG_FULL is not set
EOF
  else
    echo 'CONFIG_LTO_NONE=y' >> "$f"
  fi
}

settle_config() {
  local tree="$1"
  stamp_critical_config "$tree"
  (cd "$tree" && km_ni olddefconfig) || die "olddefconfig failed"
  stamp_critical_config "$tree"
  (cd "$tree" && km_ni olddefconfig) || die "olddefconfig pass 2 failed"
  stamp_critical_config "$tree"
  [[ -n "$XANMOD_CFG" ]] || grep -q '^CONFIG_HZ=250$' "${tree}/.config" || die "HZ!=250"
  grep -q '^CONFIG_MODULES=y$' "${tree}/.config" || die "MODULES missing"
  grep -q '^CONFIG_X86_L1_CACHE_SHIFT=6$' "${tree}/.config" || \
    echo 'CONFIG_X86_L1_CACHE_SHIFT=6' >> "${tree}/.config"
  if (( THINLTO )); then
    grep -q '^CONFIG_LTO_CLANG_THIN=y$' "${tree}/.config" || die "ThinLTO missing"
  fi
  if (( NO_NATIVE )); then
    grep -q '^CONFIG_X86_NATIVE_CPU=y' "${tree}/.config" && die "NATIVE_CPU still on"
  fi
  if (( AUTOFDO )); then
    grep -q '^CONFIG_AUTOFDO_CLANG=y' "${tree}/.config" || die "CONFIG_AUTOFDO_CLANG did not stick (needs Clang >= 19 and a tree that has the option)"
  fi
  if (( PROPELLER )); then
    grep -q '^CONFIG_PROPELLER_CLANG=y' "${tree}/.config" || die "CONFIG_PROPELLER_CLANG did not stick (needs Clang/ld.lld >= 19, CONFIG_AUTOFDO_CLANG, and a tree that has the option)"
  fi
  info "Final config (boot-relevant):"
  grep -E '^(# )?CONFIG_(X86_NATIVE_CPU|LTO_CLANG_THIN|LTO_NONE|HZ|PREEMPT[A-Z_]*|NO_HZ[A-Z_]*|AUTOFDO_CLANG|PROPELLER_CLANG|EARLY_PRINTK|EFI_STUB|DRM_SIMPLEDRM|SYSFB_SIMPLEFB|DEBUG_INFO_BTF|RD_ZSTD|X86_64_VERSION)[ =]' \
    "${tree}/.config" >&2 || true
}

find_build_tree() {
  find "${RPM_TOPDIR}/BUILD" -type d -name "${RPM_NAME}-*" 2>/dev/null | while read -r p; do
    [[ -f "${p}/Makefile" && -d "${p}/arch/x86" ]] && echo "$p"
  done | head -n1
}

do_resume() {
  local tree
  setup_compiler; make_k_args
  tree="$(find_build_tree)"
  [[ -n "$tree" ]] || die "No BUILD tree for --resume"
  info "Resume: ${tree}"
  patch_compressed_makefile "$tree"
  (cd "$tree" && rm -f arch/x86/boot/bzImage arch/x86/boot/setup.elf \
    arch/x86/boot/zoffset.h arch/x86/boot/compressed/vmlinux 2>/dev/null
    km_ni bzImage) || die "resume bzImage failed"
  ok "bzImage ok"
  exit 0
}

choose_tree_mode() {
  case "${TREE_MODE}" in hybrid|classic) return 0 ;; esac
  if (( ASSUME_YES )); then
    TREE_MODE=classic
    XANMOD_MAJOR="${XANMOD_MAJOR:-7}"
    return 0
  fi
  printf '\n%sClassic XanMod (default)%s — XanMod tree + OM /boot config donor\n' "$C_BOLD" "$C_RESET" >&2
  printf '%sHybrid (optional)%s — OpenMandriva SRPM sources + stamps\n' "$C_BOLD" "$C_RESET" >&2
  local ans
  ans="$(ask '1) Classic  2) Hybrid  [1]:' 1)"
  case "$ans" in 2) TREE_MODE=hybrid ;; *) TREE_MODE=classic; XANMOD_MAJOR="${XANMOD_MAJOR:-7}" ;; esac
}

xanmod_tags() {
  git ls-remote --tags --refs "${XANMOD_GIT}" 2>/dev/null | awk -F/ '{print $NF}' | sort -rV
}

pick_xanmod_tag() {
  local tags=() filtered=() t
  mapfile -t tags < <(xanmod_tags)
  ((${#tags[@]})) || die "No tags from ${XANMOD_GIT}"
  if [[ -n "$FORCE_TAG" ]]; then
    for t in "${tags[@]}"; do [[ "$t" == "$FORCE_TAG" ]] && { TAG="$FORCE_TAG"; info "Tag ${TAG}"; return 0; }; done
    die "Tag '${FORCE_TAG}' not in ${XANMOD_GIT}"
  fi
  if [[ "$XANMOD_MAJOR" == 7 ]]; then
    for t in "${tags[@]}"; do [[ "$t" == 7.* ]] && filtered+=("$t"); done
    ((${#filtered[@]})) || die "No 7.x tags"
    tags=("${filtered[@]}")
  fi
  TAG="${tags[0]}"
  info "Tag ${TAG}"
}

have_usable_tree() {
  [[ -f "${WORKDIR}/linux/Makefile" && -d "${WORKDIR}/linux/arch/x86" ]]
}

fetch_xanmod_source() {
  local dir="${WORKDIR}/linux"
  mkdir -p "${WORKDIR}"
  if (( ! FORCE_FETCH )) && have_usable_tree; then
    TAG="${TAG:-reused}"
    ok "Reusing ${dir}"
    patch_compressed_makefile "$dir"
    return 0
  fi
  [[ -n "$TAG" ]] || die "No tag"
  info "Clone ${TAG} → ${dir}"
  rm -rf "$dir"
  git clone --depth 1 --branch "$TAG" "$XANMOD_GIT" "$dir" || die "clone failed"
  rm -rf "${dir}/.git"
  patch_compressed_makefile "$dir"
}

unpack_kernel_srpm() {
  local srpm="$1" label="$2" tarball major minor patch
  rm -rf "${WORKDIR}/om-src" "${WORKDIR}/linux"
  mkdir -p "${WORKDIR}/om-src" "${WORKDIR}/linux"
  (cd "${WORKDIR}/om-src" && rpm2cpio "$srpm" | cpio -idmu --quiet) || die "srpm unpack failed"
  tarball="$(find "${WORKDIR}/om-src" -maxdepth 1 -type f -name 'linux-*.tar.*' | head -n1)"
  [[ -n "$tarball" ]] || die "no linux tarball in SRPM"
  tar -xf "$tarball" -C "${WORKDIR}/linux" --strip-components=1 || die "extract failed"
  major=$(awk '/^VERSION/{print $3}' "${WORKDIR}/linux/Makefile")
  minor=$(awk '/^PATCHLEVEL/{print $3}' "${WORKDIR}/linux/Makefile")
  patch=$(awk '/^SUBLEVEL/{print $3}' "${WORKDIR}/linux/Makefile")
  TAG="${label}-${major}.${minor}.${patch}"
  patch_compressed_makefile "${WORKDIR}/linux"
}

fetch_om_base() {
  local srpm
  mkdir -p "${WORKDIR}"
  if (( ! FORCE_FETCH )) && have_usable_tree; then
    TAG="${TAG:-om-reused}"
    ok "Reusing ${WORKDIR}/linux"
    patch_compressed_makefile "${WORKDIR}/linux"
    return 0
  fi
  if [[ -n "$USER_SRPM" ]]; then
    unpack_kernel_srpm "$USER_SRPM" om-srpm
    return 0
  fi
  (cd "${WORKDIR}" && dnf download --source kernel-rc) || true
  srpm="$(find "${WORKDIR}" -maxdepth 1 -name 'kernel-rc-*.src.rpm' | head -n1)"
  if [[ -z "$srpm" ]]; then
    (cd "${WORKDIR}" && dnf download --source kernel-release-desktop) || die "OM SRPM download failed"
    srpm="$(find "${WORKDIR}" -maxdepth 1 -name 'kernel-release-desktop-*.src.rpm' | head -n1)"
  fi
  [[ -n "$srpm" ]] || die "no OM SRPM"
  unpack_kernel_srpm "$srpm" om
}

pick_donor_config() {
  local f
  for f in "/boot/config-$(uname -r)" /boot/config-*-desktop*; do
    [[ -r "$f" ]] && { echo "$f"; return 0; }
  done
  echo "/boot/config-$(uname -r)"
}

synthesize_config() {
  local tree="${WORKDIR}/linux" donor
  [[ -f "${tree}/Makefile" ]] || die "No tree ${tree}"
  donor="$(pick_donor_config)"
  patch_compressed_makefile "$tree"
  if [[ -n "$XANMOD_CFG" ]]; then
    local xc="${tree}/CONFIGS/xanmod/gcc/config_x86-64-v${XANMOD_CFG}"
    [[ -r "$xc" ]] || die "XanMod config missing: ${xc} (found: $(ls "${tree}"/CONFIGS/xanmod/* 2>/dev/null | tr '\n' ' '))"
    info "Base: XanMod ${xc##*/} (no OM donor)"
    cp "$xc" "${tree}/.config"
  elif [[ -r "$donor" ]]; then
    info "Donor: ${donor}"
    cp "$donor" "${tree}/.config"
  else
    (cd "$tree" && km_ni defconfig) || die "defconfig failed"
  fi
  if (( ! KEEP_TDA18212 )) && [[ -f "${tree}/drivers/media/tuners/tda18212.c" ]]; then
    sed -i 's/buf\[2\] = priv->cfg->xtout ? 0x43 : 0x40;/buf[2] = 0x40;/' \
      "${tree}/drivers/media/tuners/tda18212.c" || true
  fi
  rm -f "${tree}/localversion"* "${tree}/.scmversion"
  printf '%s\n' '-xanmod1' > "${tree}/localversion"
  sed -i '/^CONFIG_LOCALVERSION=/d;/^CONFIG_LOCALVERSION_AUTO=/d' "${tree}/.config"
  printf '%s\n' 'CONFIG_LOCALVERSION=""' '# CONFIG_LOCALVERSION_AUTO is not set' >> "${tree}/.config"
  settle_config "$tree"
  (cd "$tree" && km_ni tools/objtool) || warn "objtool warnings"
  (cd "$tree" && km_ni prepare) || die "prepare failed"
  mkdir -p "${tree}/include/generated"
  grep -q 'CONFIG_X86_L1_CACHE_SHIFT' "${tree}/include/generated/autoconf.h" 2>/dev/null || \
    echo '#define CONFIG_X86_L1_CACHE_SHIFT 6' >> "${tree}/include/generated/autoconf.h"
  KERNEL_VER="$(cd "$tree" && km -s kernelrelease | tail -n1 | tr -d '[:space:]')"
  [[ "$KERNEL_VER" =~ ^[0-9]+\.[0-9]+ ]] || die "bad kernelrelease: ${KERNEL_VER}"
  KERNEL_VER_RPM="${KERNEL_VER//-/.}"
  ok "Configured ${KERNEL_VER}"
}

prepare_sources() {
  local dirname="${RPM_NAME}-${SAFE_TAG}" tmpdir="${WORKDIR}/tar-tmp"
  mkdir -p "${RPM_TOPDIR}/SOURCES" "$tmpdir"
  rm -rf "${tmpdir:?}/${dirname:?}"
  cp -a "${WORKDIR}/linux" "${tmpdir}/${dirname}"
  rm -rf "${tmpdir}/${dirname}/.git"
  (cd "$tmpdir" && "$GNUTAR" -cf "${RPM_TOPDIR}/SOURCES/${dirname}.tar" "$dirname") || die "tar failed"
  cp "${WORKDIR}/linux/.config" "${RPM_TOPDIR}/SOURCES/config-${SAFE_TAG}"
  ok "Tarball ready"
}

afdo_stage() {
  if (( ! AUTOFDO )); then echo none
  elif [[ -n "$PROPELLER_PREFIX" ]]; then echo final-prop
  elif (( PROPELLER )); then echo prop1
  elif [[ -n "$AFDO_PROFILE" ]]; then echo final-afdo
  else echo afdo1
  fi
}

afdo_parent_stage() {
  case "$1" in
    prop1|final-afdo) echo afdo1 ;;
    final-prop) echo prop1 ;;
    *) echo "" ;;
  esac
}

# Everything that must not change between the profiling build and the build that consumes
# its profile (AutoFDO/Propeller profiles are tied to the exact source, compiler and config).
afdo_snapshot() {
  local commit sha=""
  commit="$(git -C "${WORKDIR}/linux" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ -n "$AFDO_PROFILE" ]]; then sha="$(sha256sum "$AFDO_PROFILE" | cut -d' ' -f1)"; fi
  printf '%s=%q\n' \
    TAG "${TAG:-unknown}" COMMIT "$commit" THINLTO "$THINLTO" NO_NATIVE "$NO_NATIVE" \
    X86_LEVEL "${X86_LEVEL:-}" XANMOD_CFG "${XANMOD_CFG:-}" USE_BFD "$USE_BFD" \
    NO_WRAPPERS "$NO_WRAPPERS" \
    CLANG "$("$LLVM_CLANG" --version 2>/dev/null | head -n1)" \
    LLD "$("$LLVM_LLD" --version 2>/dev/null | head -n1)" \
    AFDO_SHA "$sha"
}

afdo_record_or_verify() {
  (( AUTOFDO )) || return 0
  local stage parent dir f pf cur d
  stage="$(afdo_stage)"; parent="$(afdo_parent_stage "$stage")"
  dir="${RPM_TOPDIR}/AFDO"; mkdir -p "$dir"
  f="${dir}/flags-${SAFE_TAG}-${stage}.env"
  cur="$(afdo_snapshot)"
  if [[ -n "$parent" ]]; then
    pf="${dir}/flags-${SAFE_TAG}-${parent}.env"
    if [[ -r "$pf" ]]; then
      if [[ "$stage" == final-prop ]]; then
        d="$(diff <(printf '%s\n' "$cur") "$pf" || true)"
      else
        d="$(diff <(printf '%s\n' "$cur" | grep -v '^AFDO_SHA=') <(grep -v '^AFDO_SHA=' "$pf") || true)"
      fi
      if [[ -n "$d" ]]; then
        printf '%s\n' "$d" >&2
        if (( AFDO_FORCE )); then
          warn "stage ${stage} differs from ${parent} (shown above; '<' = now, '>' = ${parent}); continuing (--afdo-force)"
        else
          die "stage ${stage} differs from the recorded ${parent} build (see diff above). Rebuild with the same flags/tag, or pass --afdo-force"
        fi
      else
        ok "stage ${stage}: build flags match the recorded ${parent} build"
      fi
    else
      warn "no record of the ${parent} build (${pf}); cannot verify the profile matches these flags"
    fi
  fi
  printf '%s\n' "$cur" > "$f"
  info "stage ${stage}: flags recorded in ${f}"
}

generate_spec() {
  local name="${RPM_NAME}" dirname="${RPM_NAME}-${SAFE_TAG}"
  local ver="${KERNEL_VER_RPM}" kv="${KERNEL_VER}"
  local cpu_desc="x86-64 native"
  (( NO_NATIVE )) && cpu_desc="x86-64${X86_LEVEL:+-v${X86_LEVEL}}"
  local spec="${RPM_TOPDIR}/SPECS/${PROGNAME}.spec"
  local prep_hacks bz_nm kinfo_hack extra_hacks afdo_arg afdo_save prop_arg
  mkdir -p "${RPM_TOPDIR}/SPECS"
  read -r -d '' kinfo_hack <<'PH' || true
MF=arch/x86/boot/compressed/Makefile
sed -i '/^LDFLAGS_vmlinux += -u kernel_info[[:space:]]*$/d' "$MF"
sed -i '/^LDFLAGS_vmlinux += --undefined=kernel_info/d' "$MF"
sed -i '/^LDFLAGS_vmlinux += -T[[:space:]]*$/i LDFLAGS_vmlinux += -u kernel_info' "$MF"
grep -q -- '-u kernel_info' "$MF" || { echo "kernel_info retention not applied" >&2; exit 1; }
PH
  if (( NO_BOOT_HACKS )); then
    prep_hacks="${kinfo_hack}"
    bz_nm='llvm-nm'
  else
    bz_nm='/usr/bin/nm'
    read -r -d '' extra_hacks <<'PH' || true
sed -i 's|$(NM)|/usr/bin/nm|g' "$MF"
PH
    prep_hacks="${kinfo_hack}"$'\n'"${extra_hacks}"
  fi
  afdo_arg=""; afdo_save=""; prop_arg=""
  if [[ -n "$AFDO_PROFILE" ]]; then afdo_arg="CLANG_AUTOFDO_PROFILE=${AFDO_PROFILE}"; fi
  if [[ -n "$PROPELLER_PREFIX" ]]; then prop_arg="CLANG_PROPELLER_PROFILE_PREFIX=${PROPELLER_PREFIX}"; fi
  case "$(afdo_stage)" in
    afdo1|prop1) afdo_save="install -D -m 0644 vmlinux ${RPM_TOPDIR}/AFDO/vmlinux-%{kernel_ver}-$(afdo_stage)" ;;
  esac
  cat > "$spec" <<EOF
Name:           ${name}
Version:        ${ver}
Release:        1%{?dist}
Summary:        XanMod desktop kernel (Clang/LLVM/ld.lld)
License:        GPL-2.0-only
Group:          System/Kernel and hardware
URL:            https://xanmod.org/
ExclusiveArch:  x86_64
%global kernel_ver ${kv}
AutoReq:        no
AutoProv:       no
%global _use_internal_dependency_generator 0
%global __find_provides %{nil}
%global __find_requires %{nil}
%global debug_package %{nil}
%global __find_debuginfo /bin/true
Source0:        ${dirname}.tar
Source1:        config-${SAFE_TAG}
BuildRequires:  make binutils clang llvm lld flex bison bc perl gnutar rsync zstd
BuildRequires:  elfutils-libelf-devel openssl-devel dwarves
Provides:       installonlypkg(kernel)
Requires:       %{name}-modules = %{version}-%{release}

%description
XanMod ${kv}: Clang/LLVM, ${cpu_desc}, ThinLTO, 250 Hz, NO_HZ_FULL.
Module set from OpenMandriva donor config where applicable.

%package modules
Summary: Loadable modules for %{name}
AutoReq: no
AutoProv: no
Provides: installonlypkg(kernel)
%description modules
Modules for %{kernel_ver}.

%package devel
Summary: Development files for %{name}
AutoReq: no
AutoProv: no
Provides: kernel-devel-uname-r = %{kernel_ver}
%description devel
Headers and Module.symvers for DKMS.

%prep
%setup -q -n ${dirname}
cp %{SOURCE1} .config
${prep_hacks}

%build
export PATH=${LLVM_BIN}:${HOME}/bin:\$PATH
export LLVM=1 LLVM_IAS=1
make -j${JOBS} ARCH=x86_64 SRCARCH=x86 \\
  CC=${CCBIN} LD=${LINKER} \\
  AR=llvm-ar NM=llvm-nm STRIP=llvm-strip OBJCOPY=llvm-objcopy \\
  HOSTCC=${CCBIN} HOSTCXX=${CXXBIN} HOSTLD=${LINKER} \\
  LLVM=1 LLVM_IAS=1 \\
  KCFLAGS="${OMX_KCFLAGS}" KCPPFLAGS="${OMX_KCPPFLAGS}" ${afdo_arg} ${prop_arg} \\
  olddefconfig </dev/null
make -j${JOBS} ARCH=x86_64 SRCARCH=x86 \\
  CC=${CCBIN} LD=${LINKER} \\
  AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \\
  HOSTCC=${CCBIN} HOSTCXX=${CXXBIN} HOSTLD=${LINKER} \\
  LLVM=1 LLVM_IAS=1 \\
  KCFLAGS="${OMX_KCFLAGS}" KCPPFLAGS="${OMX_KCPPFLAGS}" ${afdo_arg} ${prop_arg} \\
  modules
test -s Module.symvers
omx_snap() { grep -E '^(# )?CONFIG_(LTO_CLANG_THIN|LTO_NONE|AUTOFDO_CLANG|PROPELLER_CLANG|X86_NATIVE_CPU|X86_64_VERSION|MODULE_COMPRESS_[A-Z0-9]+)[ =]' .config | sort; }
omx_snap > .omx-snap-before
make -j${JOBS} ARCH=x86_64 SRCARCH=x86 \\
  CC=${CCBIN} LD=${LINKER} \\
  AR=llvm-ar NM=${bz_nm} OBJCOPY=llvm-objcopy \\
  HOSTCC=${CCBIN} HOSTCXX=${CXXBIN} HOSTLD=${LINKER} \\
  LLVM=1 LLVM_IAS=1 \\
  KCFLAGS="${OMX_KCFLAGS}" KCPPFLAGS="${OMX_KCPPFLAGS}" ${afdo_arg} ${prop_arg} \\
  syncconfig </dev/null
omx_snap > .omx-snap-after
if ! cmp -s .omx-snap-before .omx-snap-after; then
  echo "ERROR: .config changed when re-synced for bzImage: a tool differs between make steps (Kconfig reads NM/AR/LD/CC output). Aborting before a full rebuild." >&2
  diff .omx-snap-before .omx-snap-after >&2 || true
  exit 1
fi
rm -f arch/x86/boot/bzImage arch/x86/boot/setup.elf arch/x86/boot/zoffset.h \\
  arch/x86/boot/compressed/vmlinux
make -j${JOBS} ARCH=x86_64 SRCARCH=x86 \\
  CC=${CCBIN} LD=${LINKER} \\
  AR=llvm-ar NM=${bz_nm} OBJCOPY=llvm-objcopy \\
  HOSTCC=${CCBIN} HOSTCXX=${CXXBIN} HOSTLD=${LINKER} \\
  LLVM=1 LLVM_IAS=1 \\
  KCFLAGS="${OMX_KCFLAGS}" KCPPFLAGS="${OMX_KCPPFLAGS}" ${afdo_arg} ${prop_arg} \\
  bzImage
test -s arch/x86/boot/bzImage

%install
rm -rf %{buildroot}
export PATH=${LLVM_BIN}:${HOME}/bin:\$PATH
KREL=%{kernel_ver}
MODROOT=%{buildroot}/lib/modules/\$KREL
BOOTROOT=%{buildroot}/boot
SRCDIR=%{buildroot}/usr/src/kernels/\$KREL
mkdir -p "\$BOOTROOT" "\$MODROOT" "\$SRCDIR"
export PATH=${HOME}/bin:\$PATH
make ARCH=x86_64 INSTALL_MOD_PATH=%{buildroot} INSTALL_MOD_STRIP=1 STRIP=llvm-strip \\
  CC=${CCBIN} LD=${LINKER} LLVM=1 LLVM_IAS=1 \\
  KCFLAGS="${OMX_KCFLAGS}" KCPPFLAGS="${OMX_KCPPFLAGS}" ${afdo_arg} ${prop_arg} \\
  modules_install
${afdo_save}
install -m 0644 arch/x86/boot/bzImage "\$BOOTROOT/vmlinuz-\$KREL"
install -m 0644 System.map "\$BOOTROOT/System.map-\$KREL"
install -m 0644 .config "\$BOOTROOT/config-\$KREL"
rsync -a --delete \\
  --exclude='.git/' --exclude='arch/x86/boot/' \\
  --exclude='*.o' --exclude='*.a' --exclude='*.cmd' --exclude='*.ko' \\
  --exclude='*.mod' --exclude='*.mod.c' \\
  ./ "\$SRCDIR/"
cp -af Module.symvers .config "\$SRCDIR/"
rm -f "\$MODROOT/build" "\$MODROOT/source"
ln -sfn /usr/src/kernels/\$KREL "\$MODROOT/build"
ln -sfn /usr/src/kernels/\$KREL "\$MODROOT/source"

%files
/boot/vmlinuz-%{kernel_ver}
/boot/System.map-%{kernel_ver}
/boot/config-%{kernel_ver}

%files modules
/lib/modules/%{kernel_ver}

%files devel
/usr/src/kernels/%{kernel_ver}

%posttrans
depmod -a %{kernel_ver} || echo "depmod failed" >&2
dracut --force --kver %{kernel_ver} /boot/initrd-%{kernel_ver}.img || echo "dracut FAILED for %{kernel_ver}" >&2
grub2-mkconfig -o /boot/grub2/grub.cfg || echo "grub2-mkconfig failed" >&2
exit 0

%changelog
* $(date '+%a %b %d %Y') ${PROGNAME} - ${ver}-1
- v${VERSION}: LLVM toolchain selection, x86-64-v3 distributable mode, corrected Propeller/AFDO toolchain tracking, rpmlint pass; 2.9.1: GNU-nm swap opt-in + config guard, Propeller LLVM only for Propeller builds, baked wrapper paths
EOF
  ok "Spec written"
}

run_rpmbuild() {
  info "rpmbuild (main + modules + devel)..."
  mkdir -p "$LOG_DIR"
  local logfile="${LOG_DIR}/rpmbuild.log" rc
  set +e
  rpmbuild -bb --nodeps --nocheck \
    --define "debug_package %{nil}" \
    --define "__find_debuginfo /bin/true" \
    --define "__find_provides %{nil}" \
    --define "__find_requires %{nil}" \
    --define "_build_pkgcheck %{nil}" \
    --define "_build_pkgcheck_set %{nil}" \
    --define "_build_pkgcheck_srpm %{nil}" \
    --define "_unpackaged_files_terminate_build 0" \
    "${RPM_TOPDIR}/SPECS/${PROGNAME}.spec" 2>&1 | tee "$logfile"
  rc=${PIPESTATUS[0]}
  set -e
  (( rc == 0 )) || die "rpmbuild failed: ${logfile}"
  local n
  n=$(find "${RPM_TOPDIR}/RPMS" -name "${RPM_NAME}*.rpm" | wc -l)
  (( n >= 3 )) || die "Expected 3 RPMs, found ${n}"
  ok "RPMs ready"
  ls -lh "${RPM_TOPDIR}/RPMS"/x86_64/${RPM_NAME}*.rpm 2>/dev/null || \
    find "${RPM_TOPDIR}/RPMS" -name "${RPM_NAME}*.rpm" -ls
}

run_rpmlint() {
  command -v rpmlint >/dev/null 2>&1 || {
    warn "rpmlint not installed; skipping package lint"
    return 0
  }
  local -a rpms
  mapfile -t rpms < <(find "${RPM_TOPDIR}/RPMS" -type f -name "${RPM_NAME}*-${KERNEL_VER_RPM}-*.rpm" | sort)
  ((${#rpms[@]})) || die "no RPMs found for rpmlint"
  local log="${WORKDIR}/logs/rpmlint.log"
  mkdir -p "$(dirname "$log")"
  info "rpmlint (kernel RPMs; takes several minutes; full output: ${log})..."
  local rc=0
  rpmlint "${rpms[@]}" >"$log" 2>&1 || rc=$?
  tail -n 2 "$log" >&2
  if (( rc != 0 )); then
    warn "rpmlint reported findings (build/install is not blocked)"
  else
    ok "rpmlint clean"
  fi
}

install_rpms() {
  (( NO_INSTALL )) && { info "--no-install; RPMs in ${RPM_TOPDIR}/RPMS"; return 0; }
  local -a rpms
  mapfile -t rpms < <(find "${RPM_TOPDIR}/RPMS" -name "${RPM_NAME}*-${KERNEL_VER_RPM}-*.rpm" | sort)
  ((${#rpms[@]})) || die "no RPMs for ${KERNEL_VER_RPM}"
  # rpm directly: dnf rejected the large -devel package with a bogus header-digest error here
  sudo rpm -Uvh --replacepkgs --oldpackage "${rpms[@]}" || die "rpm install failed. The RPMs are built and intact; install them by hand with: sudo rpm -Uvh --replacepkgs --oldpackage ${RPM_TOPDIR}/RPMS/x86_64/${RPM_NAME}*-${KERNEL_VER_RPM}-*.rpm"
  # verify the installed packages are the ones just built (BUILDTIME must match)
  local r name bt_f bt_i
  for r in "${rpms[@]}"; do
    name="$(rpm -qp --qf '%{NAME}' "$r")"
    bt_f="$(rpm -qp --qf '%{BUILDTIME}' "$r")"
    bt_i="$(rpm -q --qf '%{BUILDTIME}\n' "$name" | sort -n | tail -1)"
    [[ "$bt_f" == "$bt_i" ]] || die "installed ${name} is NOT the package just built"
  done
  info "vmlinuz: $(ls -l --time-style=long-iso "/boot/vmlinuz-${KERNEL_VER}" | awk '{print $6, $7}')"
  info "initrd : $(ls -l --time-style=long-iso "/boot/initrd-${KERNEL_VER}.img" | awk '{print $6, $7}')"
  info "LTO    : $(grep -E '^CONFIG_LTO_(NONE|CLANG_THIN)=' "/boot/config-${KERNEL_VER}" | tr '\n' ' ')"
  ok "Installed and verified"
}

maybe_cleanup_prompt() {
  local a
  a="$(ask 'Clean work tree under /tmp (re-clone next time)? [y/N]:' n)"
  case "${a,,}" in y|yes) do_cleanup ;; *) info "Kept ${WORKDIR} for reuse" ;; esac
}

start_sudo_keepalive() {
  (( NO_INSTALL )) && return 0
  [[ $EUID -eq 0 ]] && return 0
  sudo -v || die "sudo is needed to install the RPMs (use --no-install to skip installing)"
  # refresh the sudo timestamp for as long as this script lives; no extra privileges are taken
  (
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null || exit 0
      sleep "${OMX_SUDO_KEEPALIVE_INTERVAL:-50}"
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "${SUDO_KEEPALIVE_PID:-0}" 2>/dev/null || true' EXIT
}

main() {
  while (($#)); do
    case "$1" in
      -h|--help) help_menu; exit 0 ;;
      --resume) DO_RESUME=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-install) NO_INSTALL=1 ;;
      --cleanup) do_cleanup; exit 0 ;;
      --force-fetch) FORCE_FETCH=1 ;;
      --jobs|-j) JOBS="${2:?}"; shift ;;
      --srpm) USER_SRPM="${2:?}"; TREE_MODE=hybrid; shift ;;
      --tag) FORCE_TAG="${2:?}"; TREE_MODE=classic; shift ;;
      --hybrid) TREE_MODE=hybrid ;;
      --xanmod|--classic) TREE_MODE=classic ;;
      --xanmod-7|--7|--xanmod-latest) TREE_MODE=classic; XANMOD_MAJOR=7 ;;
      --xanmod-github) TREE_MODE=classic; XANMOD_GIT="${XANMOD_GIT_GITHUB}" ;;
      --use-bfd) USE_BFD=1 ;;
      --xanmod-config) XANMOD_CFG="${2:?}"; XANMOD_CFG="${XANMOD_CFG#v}"; shift ;;
      --native) WANT_NATIVE=1 ;;
      --autofdo) AUTOFDO=1 ;;
      --propeller) PROPELLER=1; AUTOFDO=1 ;;
      --propeller-profile) [[ $# -ge 2 ]] || die "--propeller-profile needs a prefix"; PROPELLER_PREFIX="$2"; PROPELLER=1; AUTOFDO=1; shift ;;
      --afdo-force) AFDO_FORCE=1 ;;
      --afdo-profile) [[ $# -ge 2 ]] || die "--afdo-profile needs a file"; AFDO_PROFILE="$2"; AUTOFDO=1; shift ;;
      --plain-lld) PLAIN_LLD=1 ;;
      --lld-wrapper) PLAIN_LLD=0 ;;
      --v3) X86_LEVEL=3 ;;
      --x86-64-v3) X86_LEVEL=3; NO_NATIVE=1 ;;
      --x86-level) X86_LEVEL="${2:?}"; shift ;;
      --llvm-root) LLVM_ROOT="${2:?}"; shift ;;
      --no-wrappers) NO_WRAPPERS=1 ;;
      --no-thinlto) THINLTO=0 ;;
      --no-native) NO_NATIVE=1 ;;
      --no-boot-hacks) NO_BOOT_HACKS=1; FORCE_FETCH=1 ;;
      --boot-hacks) NO_BOOT_HACKS=0 ;;
      --rpmlint) RUN_RPMLINT=1 ;;
      --bisect) THINLTO=0; NO_NATIVE=1; NO_BOOT_HACKS=1; FORCE_FETCH=1 ;;
      --force-thinlto) THINLTO=1 ;;
      --keep-tda18212) KEEP_TDA18212=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      *) die "Unknown: $1" ;;
    esac
    shift
  done
  [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "bad --jobs"
  if (( AUTOFDO )); then
    if [[ -n "$AFDO_PROFILE" ]]; then
      [[ -r "$AFDO_PROFILE" ]] || die "AutoFDO profile not readable: ${AFDO_PROFILE}"
      AFDO_PROFILE="$(readlink -f "$AFDO_PROFILE")"
    fi
    if (( PROPELLER )); then
      if (( USE_BFD )); then die "Propeller needs ld.lld (drop --use-bfd)"; fi
      [[ -n "$AFDO_PROFILE" ]] || die "Propeller stages need --afdo-profile (documented pipeline: build-afdo, train-afdo, build-propeller, train-propeller, build-optimized)"
    fi
    if [[ -n "$PROPELLER_PREFIX" ]]; then
      PROPELLER_PREFIX="$(realpath -m "$PROPELLER_PREFIX")"
      [[ -r "${PROPELLER_PREFIX}_cc_profile.txt" && -r "${PROPELLER_PREFIX}_ld_profile.txt" ]] \
        || die "missing ${PROPELLER_PREFIX}_cc_profile.txt and/or ${PROPELLER_PREFIX}_ld_profile.txt"
      # v23 generate_propeller_profiles emits 'g' edge-weight lines that this
      # build's LLVM 19 rejects (LLVM ERROR: invalid specifier: 'g', abort).
      # Sanitize into a .llvm19 profile pair and build from that instead;
      # the user's originals are never modified.
      if grep -q '^g[[:space:]]' "${PROPELLER_PREFIX}_cc_profile.txt" 2>/dev/null; then
        pp_sanitized="${PROPELLER_PREFIX}.llvm19"
        grep -v '^g[[:space:]]' "${PROPELLER_PREFIX}_cc_profile.txt" > "${pp_sanitized}_cc_profile.txt" || true
        [[ -s "${pp_sanitized}_cc_profile.txt" ]] \
          || die "sanitized Propeller CC profile is empty (input was all 'g' lines?)"
        cp "${PROPELLER_PREFIX}_ld_profile.txt" "${pp_sanitized}_ld_profile.txt"
        info "Propeller CC profile: stripped 'g' lines (v23 tool output vs LLVM 19); building with ${pp_sanitized}"
        PROPELLER_PREFIX="$pp_sanitized"
      fi
    fi
  fi
  [[ -z "$X86_LEVEL" || "$X86_LEVEL" =~ ^[1-4]$ ]] || die "--x86-level takes 1-4"
  if [[ -n "$LLVM_ROOT" ]]; then
    [[ -d "$LLVM_ROOT/bin" ]] || die "LLVM root has no bin directory: $LLVM_ROOT"
  fi
  if [[ -n "$XANMOD_CFG" ]]; then
    [[ "$XANMOD_CFG" =~ ^[1-4]$ ]] || die "--xanmod-config takes v1, v2, v3 or v4"
    if (( WANT_NATIVE )); then NO_NATIVE=0; else NO_NATIVE=1; fi
  fi
  (( NO_NATIVE )) && OMX_KCFLAGS="-Wno-unknown-warning-option"
  if (( USE_BFD && THINLTO )); then die "ThinLTO needs ld.lld: with --use-bfd add --no-thinlto"; fi
  info "flags: THINLTO=${THINLTO} NO_NATIVE=${NO_NATIVE} NO_BOOT_HACKS=${NO_BOOT_HACKS} USE_BFD=${USE_BFD} XANMOD_CFG=${XANMOD_CFG:-donor} X86_LEVEL=${X86_LEVEL:-default} PLAIN_LLD=${PLAIN_LLD} NO_WRAPPERS=${NO_WRAPPERS} LLVM_ROOT=${LLVM_ROOT:-auto} AUTOFDO=${AUTOFDO} AFDO_PROFILE=${AFDO_PROFILE:-none} PROPELLER=${PROPELLER} PROPELLER_PREFIX=${PROPELLER_PREFIX:-none} STAGE=$(afdo_stage)"
  mkdir -p "$WORKDIR" "$LOG_DIR" "${RPM_TOPDIR}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  printf '\n%b▶ %s v%s%b\n\n' "$C_BOLD$C_CYAN" "$PROGNAME" "$VERSION" "$C_RESET"
  start_sudo_keepalive
  check_deps
  preflight
  if (( AUTOFDO )); then
    _cv="$("$LLVM_CLANG" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9]*\).*/\1/p' | head -n1)"
    [[ "${_cv:-0}" -ge 19 ]] || die "AutoFDO needs Clang >= 19 (found ${_cv:-none})"
    if (( PROPELLER )); then
      _lv="$("$LLVM_LLD" --version 2>/dev/null | sed -n 's/.*LLD \([0-9][0-9]*\).*/\1/p' | head -n1)"
      [[ "${_lv:-0}" -ge 19 ]] || die "Propeller needs ld.lld >= 19 (found ${_lv:-none})"
    fi
  fi
  (( DO_RESUME )) && do_resume
  choose_tree_mode
  ensure_gnutar
  if [[ "$TREE_MODE" == hybrid ]]; then
    info "Hybrid (OM SRPM base)"
    fetch_om_base
  else
    info "Classic XanMod"
    pick_xanmod_tag
    fetch_xanmod_source
  fi
  SAFE_TAG="$(printf '%s' "$TAG" | tr '/:[:space:]' '---' | tr -cd 'A-Za-z0-9._+-')"
  [[ -n "$SAFE_TAG" ]] || SAFE_TAG=unknown
  (( DRY_RUN )) && { ok "Dry-run done"; exit 0; }
  afdo_record_or_verify
  synthesize_config
  prepare_sources
  generate_spec
  run_rpmbuild
  install_rpms
  if (( RUN_RPMLINT )); then run_rpmlint; fi
  maybe_cleanup_prompt
  ok "Done"
}

main "$@"
