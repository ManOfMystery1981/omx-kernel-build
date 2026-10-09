#!/usr/bin/env bash
# omx-kernel-summary.sh -- compact, screenshot-friendly summary of how the RUNNING kernel was built.
# Reads /proc/config.gz (or /boot/config-<release>); needs no root. Prints no hostname or username.
set -Eeuo pipefail

CFG="${KCONFIG:-}"
if [[ -z "$CFG" ]]; then
  if [[ -r /proc/config.gz ]]; then
    CFG="$(mktemp)"; trap 'rm -f "$CFG"' EXIT
    zcat /proc/config.gz > "$CFG"
  elif [[ -r "/boot/config-$(uname -r)" ]]; then
    CFG="/boot/config-$(uname -r)"
  else
    echo "no kernel config found (/proc/config.gz or /boot/config-$(uname -r))" >&2
    exit 1
  fi
fi

val() {   # val SYMBOL -> y / m / n / <value> / "-" (symbol absent from this kernel)
  local l
  l="$(grep -E "^(# )?CONFIG_$1[ =]" "$CFG" | sed -n '1p' || true)"
  case "$l" in
    "")    echo "-" ;;
    "# "*) echo "n" ;;
    *)     l="${l#*=}"; echo "${l//\"/}" ;;
  esac
}
row() { printf '  %-30s %s\n' "$1" "$2"; }
head_() { printf '\n== %s ==\n' "$1"; }
ver() {   # 190107 -> 19.1.7
  local v="$1"; [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )) && printf '%d.%d.%d' $((v/10000)) $((v/100%100)) $((v%100)) || echo "-"
}

head_ "Kernel"
row "release"      "$(uname -r)"
row "build"        "$(uname -v)"
row "arch"         "$(uname -m)"
img="/boot/vmlinuz-$(uname -r)"
[[ -r "$img" ]] && row "image size" "$(( $(stat -c %s "$img") / 1024 )) KiB"
cpu="$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | sed -n '1p')"
[[ -n "$cpu" ]] && row "cpu" "$cpu"

head_ "Toolchain that built it"
row "compiler"     "$(val CC_VERSION_TEXT | sed 's/ (.*//')"
row "clang / lld / llvm-as" "$(val CC_IS_CLANG) / $(val LD_IS_LLD) / $(val AS_IS_LLVM)"
row "lld version"  "$(ver "$(val LLD_VERSION)")"

head_ "Optimisation"
row "ThinLTO"                 "$(val LTO_CLANG_THIN)"
row "AutoFDO (profile-guided)" "$(val AUTOFDO_CLANG)"
row "Propeller (layout)"      "$(val PROPELLER_CLANG)"
row "native CPU tuning"       "$(val X86_NATIVE_CPU)"
row "optimise for performance" "$(val CC_OPTIMIZE_FOR_PERFORMANCE)"

# Provenance recorded by the build script for the profile-guided stages (no paths or names).
envf=""
for f in "$HOME"/rpmbuild/AFDO/flags-*-final-prop.env; do [[ -r "$f" ]] && envf="$f"; done
if [[ -n "$envf" ]]; then
  pick() { awk -F= -v k="$1" '$1 == k { print $2 }' "$envf" | sed -n '1p'; }
  row "source tag"          "$(pick TAG)"
  row "source commit"       "$(pick COMMIT | cut -c1-12)"
  row "AutoFDO profile sha256" "$(pick AFDO_SHA | cut -c1-16)..."
fi

head_ "Scheduler and timers"
row "preempt dynamic / lazy"  "$(val PREEMPT_DYNAMIC) / $(val PREEMPT_LAZY)"
row "HZ"                      "$(val HZ)"
row "NO_HZ idle / full"       "$(val NO_HZ_IDLE) / $(val NO_HZ_FULL)"

head_ "Build details"
row "module compression"  "$(val MODULE_COMPRESS_ZSTD) zstd / $(val MODULE_COMPRESS_XZ) xz / $(val MODULE_COMPRESS_GZIP) gzip"
row "BTF"                 "$(val DEBUG_INFO_BTF)"
row "KASLR"               "$(val RANDOMIZE_BASE)"
row "kernel headers (IKHEADERS)" "$(val IKHEADERS)"
echo
