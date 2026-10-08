#!/usr/bin/env bash
# omx-afdo-profile.sh
#
# Collect and convert AutoFDO / Propeller profiles for a Clang-built
# Linux kernel.
#
# Workflow:
#
#   STAGE 1 — AutoFDO
#
#   Build:
#     OMX-Kernel-Build-Script.sh ... --autofdo
#
#   Boot that kernel, then:
#     sudo omx-afdo-profile.sh record VMLINUX run1.afdo 3600
#
#   Or run a specific workload:
#     sudo omx-afdo-profile.sh record VMLINUX run1.afdo -- COMMAND...
#
#   Repeat for additional workloads if desired.
#
#   Merge:
#     omx-afdo-profile.sh merge final.afdo run1.afdo run2.afdo
#
#
#   STAGE 2 — AutoFDO + Propeller profiling kernel
#
#   Build with:
#     ... --afdo-profile final.afdo --propeller
#
#   Boot that kernel, then:
#     sudo omx-afdo-profile.sh record-propeller VMLINUX PREFIX 3600
#
#   This produces:
#     PREFIX.perf.data
#     PREFIX_cc_profile.txt
#     PREFIX_ld_profile.txt
#
#
#   STAGE 3 — Final optimized kernel
#
#   Build with:
#     ... --afdo-profile final.afdo --propeller-profile PREFIX
#
#
# Rescue / conversion:
#
#   AutoFDO:
#     omx-afdo-profile.sh convert VMLINUX PERF.data OUT.afdo
#
#   Propeller:
#     omx-afdo-profile.sh convert-propeller VMLINUX PREFIX PERF.data
#
#
# Requirements:
#   - perf
#   - llvm-profgen + llvm-profdata (LLVM >= 19)
#   - generate_propeller_profiles from google/llvm-propeller
#     (found via PROPELLER_TOOL, PATH, then /opt/llvm-propeller*/bin)
#     OR create_llvm_prof from a compatible AutoFDO/Propeller build
#     Prebuilt RPM (OpenMandriva) with generate_propeller_profiles:
#     https://mega.nz/file/O15hgTbA#BcdIRJEl2K69zrH-bhjow9ZtuKEyRR8ddquMDR5QZgU
#   - Intel LBR or AMD branch-sampling hardware
#
# The kernel vmlinux must correspond EXACTLY to the kernel being profiled.
#
# Reference:
#   Linux Documentation/dev-tools/autofdo.rst
#   Linux Documentation/dev-tools/propeller.rst

set -Eeuo pipefail


# ---------------------------------------------------------------------------
# Basic helpers
# ---------------------------------------------------------------------------

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

need() {
    command -v "$1" >/dev/null 2>&1 ||
        die "missing required tool: $1"
}


give_back() {
    # Files written under sudo are root-owned; give them to the invoking user.
    [[ -n "${SUDO_UID:-}" ]] || return 0

    chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$@" 2>/dev/null || true
}


# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'

Usage:

  AutoFDO recording:
    omx-afdo-profile.sh record VMLINUX OUT.afdo [SECONDS]
    omx-afdo-profile.sh record VMLINUX OUT.afdo -- COMMAND...

  Convert existing AutoFDO perf data:
    omx-afdo-profile.sh convert VMLINUX PERF.data OUT.afdo

  Merge AutoFDO profiles:
    omx-afdo-profile.sh merge OUT.afdo IN1.afdo [IN2.afdo ...]

  Propeller recording:
    omx-afdo-profile.sh record-propeller VMLINUX PREFIX [SECONDS]
    omx-afdo-profile.sh record-propeller VMLINUX PREFIX -- COMMAND...

  Convert existing Propeller perf data:
    omx-afdo-profile.sh convert-propeller VMLINUX PREFIX PERF.data
    omx-afdo-profile.sh convert-propeller VMLINUX PREFIX PERF1.data PERF2.data ...

Examples:

  sudo omx-afdo-profile.sh record \
      /usr/src/kernels/$(uname -r)/vmlinux \
      ~/afdo/xanmod.afdo \
      3600

  sudo omx-afdo-profile.sh record-propeller \
      /usr/src/kernels/$(uname -r)/vmlinux \
      ~/afdo/xanmod-propeller \
      3600

  omx-afdo-profile.sh merge \
      ~/afdo/final.afdo \
      ~/afdo/workload1.afdo \
      ~/afdo/workload2.afdo

Environment:

  AFDO_PERIOD=500009
      Hardware branch sample period. Default: 500009.

  AFDO_ALLOW_VM=1
      Permit operation inside a VM. Hardware branch sampling normally
      requires bare-metal PMU/LBR support.

  PROPELLER_TOOL=/path/to/generate_propeller_profiles
      Use this converter instead of searching PATH and /opt/llvm-propeller*.

  PROPELLER_ARGS='--flag {BIN} {PROF} {CC} {LD} ...'
      Custom converter flags if the installed tool's interface differs from
      the kernel's propeller.rst. Placeholders: {BIN} vmlinux, {PROF} perf
      data, {CC} cc profile, {LD} ld profile.

USAGE
}


# ---------------------------------------------------------------------------
# LLVM version checking
# ---------------------------------------------------------------------------

llvm_major() {
    "$1" --version 2>/dev/null |
        sed -n 's/.*version \([0-9][0-9]*\).*/\1/p' |
        head -n1
}

need_llvm19() {
    local tool version

    for tool in "$@"; do
        need "$tool"

        version="$(llvm_major "$tool")"

        [[ "${version:-0}" -ge 19 ]] ||
            die "$tool must come from LLVM >= 19 (found ${version:-unknown})"
    done
}


# ---------------------------------------------------------------------------
# VMLINUX validation
# ---------------------------------------------------------------------------

check_vmlinux_file() {
    local vmlinux="$1"

    [[ -e "$vmlinux" ]] ||
        die "no such file: $vmlinux"

    [[ ! -d "$vmlinux" ]] ||
        die "VMLINUX must be the vmlinux FILE, not a directory: $vmlinux"

    need readelf

    readelf -h "$vmlinux" >/dev/null 2>&1 ||
        die "not a valid ELF file: $vmlinux"
}


# ---------------------------------------------------------------------------
# Verify VMLINUX matches the currently running kernel
# ---------------------------------------------------------------------------

running_build_id() {
    local id="" out

    # Test hook / manual override.
    if [[ -n "${AFDO_RUNNING_BUILDID:-}" ]]; then
        printf '%s\n' "$AFDO_RUNNING_BUILDID"
        return 0
    fi

    out="$(perf buildid-list -k 2>/dev/null || true)"
    id="$(awk 'NR == 1 { print $1 }' <<<"$out")"

    # Fallback: parse the GNU build-id note exposed by the running kernel.
    if [[ -z "$id" && -r /sys/kernel/notes ]] && command -v python3 >/dev/null 2>&1; then
        id="$(python3 - <<'NOTES_PY' 2>/dev/null || true
import struct
b = open('/sys/kernel/notes', 'rb').read(); i = 0
while i + 12 <= len(b):
    n, d, t = struct.unpack_from('<III', b, i); i += 12
    name = b[i:i+n]; i += (n + 3) & ~3
    desc = b[i:i+d]; i += (d + 3) & ~3
    if t == 3 and name.startswith(b'GNU'):
        print(desc.hex()); break
NOTES_PY
)"
    fi

    printf '%s\n' "$id"
}

vmlinux_build_id() {
    local out

    out="$(readelf -n "$1" 2>/dev/null || true)"
    awk '/Build ID/ { print $3 }' <<<"$out" | sed -n '1p'
}

check_vmlinux_matches_running() {
    local running_id vmlinux_id

    running_id="$(running_build_id)"
    vmlinux_id="$(vmlinux_build_id "$1")"

    if [[ -n "$running_id" && -n "$vmlinux_id" ]]; then
        if [[ "$running_id" != "$vmlinux_id" ]]; then
            die \
                "VMLINUX build-id ($vmlinux_id) differs from the running kernel ($running_id). " \
                "You are using the wrong vmlinux for this boot."
        fi

        printf 'OK: vmlinux matches running kernel %s\n' "$(uname -r)" >&2
        printf '    Build-ID: %s\n' "$vmlinux_id" >&2
    else
        warn \
            "could not compare build-IDs automatically. " \
            "Make absolutely sure VMLINUX belongs to running kernel $(uname -r)."
    fi
}


# ---------------------------------------------------------------------------
# Detect CPU and configure branch sampling
#
# Linux kernel Propeller documentation specifies:
#
# Intel:
#   BR_INST_RETIRED.NEAR_TAKEN:k
#
# AMD:
#   RETIRED_TAKEN_BRANCH_INSTRUCTIONS:k
#
# Both require:
#   -a -N -b -c <period>
# ---------------------------------------------------------------------------

setup_sampling() {
    [[ $EUID -eq 0 ]] ||
        die "run as root (system-wide branch sampling requires root permissions)"

    need perf

    if grep -qw hypervisor /proc/cpuinfo &&
       [[ "${AFDO_ALLOW_VM:-0}" != 1 ]]; then

        die \
            "running inside a VM: hardware branch sampling is normally unavailable. " \
            "Set AFDO_ALLOW_VM=1 only if your VM exposes the required PMU/LBR facility."
    fi

    period="${AFDO_PERIOD:-500009}"

    [[ "$period" =~ ^[0-9]+$ ]] ||
        die "AFDO_PERIOD must be a positive integer"

    # Determine CPU vendor explicitly.
    if grep -q 'GenuineIntel' /proc/cpuinfo; then

        cpu_vendor="Intel"

        event_args=(
            -e
            BR_INST_RETIRED.NEAR_TAKEN:k
        )

    elif grep -q 'AuthenticAMD' /proc/cpuinfo; then

        cpu_vendor="AMD"

        event_args=(
            --pfm-events
            RETIRED_TAKEN_BRANCH_INSTRUCTIONS:k
        )

    else

        die \
            "unsupported CPU vendor. " \
            "This script currently supports Intel LBR and AMD branch sampling."
    fi

    printf 'CPU vendor: %s\n' "$cpu_vendor" >&2
    printf 'Branch event: %s\n' "${event_args[*]}" >&2
    printf 'Sample period: %s\n' "$period" >&2

    # Verify that perf can actually open the branch event before doing
    # a potentially long recording.
    local tmp rc=0

    tmp="$(mktemp)"

    # NOTE: "if ! cmd; then rc=$?" would always record 0 (the negated status),
    # which silently disabled this check. Capture the real status instead.
    perf record \
        "${event_args[@]}" \
        -a \
        -N \
        -b \
        -c "$period" \
        -o "$tmp" \
        -- sleep 1 >/dev/null 2>&1 || rc=$?

    rm -f "$tmp"

    if [[ $rc -ne 0 ]]; then

        cat >&2 <<EOF

ERROR: perf could not initialize hardware branch sampling.

CPU vendor: $cpu_vendor
Event: ${event_args[*]}
Period: $period

The kernel Propeller documentation expects this event:

  Intel:
    BR_INST_RETIRED.NEAR_TAKEN:k

  AMD:
    RETIRED_TAKEN_BRANCH_INSTRUCTIONS:k

Check the PMU exposed by your system with:

  perf list | grep -E 'BR_INST_RETIRED|RETIRED_TAKEN_BRANCH|branch|LBR'

EOF

        die "hardware branch sampling is unavailable or restricted on this system"
    fi

    printf 'OK: hardware branch sampling is available.\n' >&2
}


# ---------------------------------------------------------------------------
# Record perf branch samples
# ---------------------------------------------------------------------------

run_sampling() {
    local perfdata="$1"
    shift

    local load

    if [[ "${1:-}" == "--" ]]; then
        shift

        [[ $# -gt 0 ]] ||
            die "-- requires a command"

        load=("$@")

    else
        local seconds="${1:-120}"

        [[ "$seconds" =~ ^[0-9]+$ ]] ||
            die "SECONDS must be a non-negative integer"

        load=(sleep "$seconds")
    fi

    mkdir -p "$(dirname "$perfdata")"

    printf '\n' >&2
    printf 'Sampling branch execution...\n' >&2
    printf '  Period: %s\n' "$period" >&2
    printf '  Event:  %s\n' "${event_args[*]}" >&2
    printf '  Load:   %s\n' "${load[*]}" >&2
    printf '  Output: %s\n' "$perfdata" >&2
    printf '\n' >&2

    perf record \
        "${event_args[@]}" \
        -a \
        -N \
        -b \
        -c "$period" \
        -o "$perfdata" \
        -- "${load[@]}"
}


# ---------------------------------------------------------------------------
# Convert AutoFDO profile
# ---------------------------------------------------------------------------

convert_afdo() {
    local vmlinux="$1"
    local perfdata="$2"
    local output="$3"

    need_llvm19 llvm-profgen

    [[ -r "$vmlinux" ]] ||
        die "cannot read vmlinux: $vmlinux"

    [[ -r "$perfdata" ]] ||
        die "cannot read perf data: $perfdata"

    mkdir -p "$(dirname "$output")"

    printf 'Converting AutoFDO profile with llvm-profgen...\n' >&2

    llvm-profgen \
        --kernel \
        --binary="$vmlinux" \
        --perfdata="$perfdata" \
        -o "$output"

    give_back "$perfdata" "$output"

    printf 'Profile written: %s\n' "$output" >&2
}


# ---------------------------------------------------------------------------
# Locate Propeller conversion tool
# ---------------------------------------------------------------------------

find_propeller_tool() {
    local f best=""

    # 1. Explicit override.
    if [[ -n "${PROPELLER_TOOL:-}" ]]; then
        if [[ -x "$PROPELLER_TOOL" ]] || command -v "$PROPELLER_TOOL" >/dev/null 2>&1; then
            printf '%s\n' "$PROPELLER_TOOL"
            return 0
        fi
        return 1
    fi

    # 2. PATH.
    if command -v generate_propeller_profiles >/dev/null 2>&1; then
        printf '%s\n' generate_propeller_profiles
        return 0
    fi

    # 3. /opt installs (e.g. /opt/llvm-propeller-23/bin). sudo resets PATH, so
    #    these are searched explicitly; the newest match wins.
    shopt -s nullglob
    # shellcheck disable=SC2231
    for f in ${PROPELLER_SEARCH_GLOB:-/opt/llvm-propeller*/bin/generate_propeller_profiles}; do
        [[ -x "$f" ]] && best="$f"
    done
    shopt -u nullglob

    if [[ -n "$best" ]]; then
        printf '%s\n' "$best"
        return 0
    fi

    # 4. AutoFDO's converter (older Propeller workflow).
    if command -v create_llvm_prof >/dev/null 2>&1; then
        printf '%s\n' create_llvm_prof
        return 0
    fi

    return 1
}


# ---------------------------------------------------------------------------
# Convert Propeller profile
# ---------------------------------------------------------------------------

convert_propeller() {
    local vmlinux="$1"
    local prefix="$2"

    shift 2

    [[ $# -gt 0 ]] ||
        die "at least one perf.data file is required"

    local tool
    local profile
    local list=""

    tool="$(find_propeller_tool)" ||
        die \
            "no Propeller conversion tool found (searched PROPELLER_TOOL, PATH, " \
            "/opt/llvm-propeller*/bin, create_llvm_prof). " \
            "Set PROPELLER_TOOL=/path/to/generate_propeller_profiles."

    [[ -r "$vmlinux" ]] ||
        die "cannot read vmlinux: $vmlinux"

    local perfdata

    for perfdata in "$@"; do
        [[ -r "$perfdata" ]] ||
            die "cannot read perf data: $perfdata"
    done

    mkdir -p "$(dirname "$prefix")"

    # One perf.data:
    #
    #   --profile=file
    #
    # Multiple perf.data files:
    #
    #   --profile=@filelist
    #
    # This is the interface documented by Linux's propeller.rst.
    if [[ $# -eq 1 ]]; then

        profile="$1"

    else

        list="$(mktemp)"

        # Always remove the temporary list on exit.
        trap 'rm -f "$list"' RETURN

        printf '%s\n' "$@" > "$list"

        profile="@${list}"
    fi

    printf '\n' >&2
    printf 'Converting Propeller profile...\n' >&2
    printf '  Tool:    %s\n' "$tool" >&2
    printf '  Binary:  %s\n' "$vmlinux" >&2
    printf '  Profile: %s\n' "$profile" >&2
    printf '\n' >&2

    if [[ -n "${PROPELLER_ARGS:-}" ]]; then
        # Custom flags for tools whose interface differs from propeller.rst.
        # Placeholders: {BIN} vmlinux, {PROF} perf data (or @list),
        #               {CC} cc profile, {LD} ld profile.
        local args="$PROPELLER_ARGS"

        args="${args//\{BIN\}/$vmlinux}"
        args="${args//\{PROF\}/$profile}"
        args="${args//\{CC\}/${prefix}_cc_profile.txt}"
        args="${args//\{LD\}/${prefix}_ld_profile.txt}"

        printf '  Custom flags: %s\n\n' "$args" >&2

        # shellcheck disable=SC2086
        "$tool" $args
    else
        "$tool" \
            --binary="$vmlinux" \
            --profile="$profile" \
            --format=propeller \
            --propeller_output_module_name \
            --out="${prefix}_cc_profile.txt" \
            --propeller_symorder="${prefix}_ld_profile.txt"
    fi

    [[ -s "${prefix}_cc_profile.txt" ]] ||
        die "Propeller CC profile was not generated"

    [[ -s "${prefix}_ld_profile.txt" ]] ||
        die "Propeller linker/symbol-order profile was not generated"

    give_back "${prefix}_cc_profile.txt" "${prefix}_ld_profile.txt" "$@"

    printf '\n' >&2
    printf 'Propeller profiles written:\n' >&2
    printf '  CC / basic-block profile: %s_cc_profile.txt\n' "$prefix" >&2
    printf '  LD / symbol-order profile: %s_ld_profile.txt\n' "$prefix" >&2
}


# ---------------------------------------------------------------------------
# Main command
# ---------------------------------------------------------------------------

cmd="${1:-}"

[[ -n "$cmd" ]] ||
    {
        usage
        exit 1
    }

shift || true


case "$cmd" in

    # -----------------------------------------------------------------------
    # AutoFDO recording
    # -----------------------------------------------------------------------

    record)

        [[ $# -ge 2 ]] ||
            {
                usage
                exit 1
            }

        vmlinux="$1"
        out="$2"

        shift 2

        check_vmlinux_file "$vmlinux"

        need_llvm19 llvm-profgen

        setup_sampling

        check_vmlinux_matches_running "$vmlinux"

        perfdata="${out%.afdo}.perf.data"

        run_sampling "$perfdata" "$@"

        give_back "$perfdata"

        printf '\nRaw AutoFDO samples kept in:\n  %s\n\n' \
            "$perfdata" >&2

        convert_afdo \
            "$vmlinux" \
            "$perfdata" \
            "$out"

        ;;


    # -----------------------------------------------------------------------
    # Convert existing AutoFDO perf data
    # -----------------------------------------------------------------------

    convert)

        [[ $# -eq 3 ]] ||
            {
                usage
                exit 1
            }

        check_vmlinux_file "$1"

        [[ -r "$2" ]] ||
            die "cannot read $2"

        convert_afdo "$1" "$2" "$3"

        ;;


    # -----------------------------------------------------------------------
    # Merge AutoFDO profiles
    # -----------------------------------------------------------------------

    merge)

        [[ $# -ge 2 ]] ||
            die "merge requires OUT.afdo plus at least one input profile"

        out="$1"

        shift

        need_llvm19 llvm-profdata

        printf 'Merging AutoFDO profiles...\n' >&2

        llvm-profdata merge \
            -o "$out" \
            "$@"

        give_back "$out"

        printf 'Merged profile written: %s\n' "$out" >&2

        ;;


    # -----------------------------------------------------------------------
    # Propeller recording
    # -----------------------------------------------------------------------

    record-propeller)

        [[ $# -ge 2 ]] ||
            {
                usage
                exit 1
            }

        vmlinux="$1"
        prefix="$2"

        shift 2

        check_vmlinux_file "$vmlinux"

        # Fail now, not after an hour of recording.
        tool_check="$(find_propeller_tool)" ||
            die "no Propeller converter found; set PROPELLER_TOOL=/path/to/generate_propeller_profiles"

        printf 'Propeller converter: %s\n' "$tool_check" >&2

        setup_sampling

        check_vmlinux_matches_running "$vmlinux"

        perfdata="${prefix}.perf.data"

        run_sampling "$perfdata" "$@"

        give_back "$perfdata"

        printf '\nRaw Propeller samples kept in:\n  %s\n\n' \
            "$perfdata" >&2

        convert_propeller \
            "$vmlinux" \
            "$prefix" \
            "$perfdata"

        ;;


    # -----------------------------------------------------------------------
    # Convert existing Propeller perf data
    # -----------------------------------------------------------------------

    convert-propeller)

        [[ $# -ge 3 ]] ||
            {
                usage
                exit 1
            }

        check_vmlinux_file "$1"

        convert_propeller "$@"

        ;;


    *)

        usage
        exit 1

        ;;

esac
