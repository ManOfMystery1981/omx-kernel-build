Name:           llvm-propeller
Version:        23.0.0
Release:        1%{?dist}
Summary:        LLVM/Clang 23 toolchain from Google LLVM Propeller
Group:          Development/Tools
License:        Apache-2.0 WITH LLVM-exception
URL:            https://github.com/google/llvm-propeller

%description
# rpmlint: disable=devel-file-in-non-devel-package
# rpmlint: disable=binary-or-shlib-defines-rpath
LLVM/Clang 23 toolchain built from the LLVM source tree pinned by the
Google LLVM Propeller project.

This package is installed separately under /opt/llvm-propeller-23 so
that it does not conflict with the system LLVM/Clang installation.

The package contains Clang, llvm-profgen, and the Clang builtin headers
required by the compiler.

# Build with the three source/build trees defined, e.g.:
#   rpmbuild -bb \
#     --define "llvm_build /path/to/llvm-build" \
#     --define "llvm_src /path/to/llvm-source" \
#     --define "propeller_build /path/to/llvm-propeller-build" \
#     llvm-propeller.spec

%prep

%build
# The LLVM/Clang build was completed outside rpmbuild.
# No compilation is performed here.

%install
rm -rf %{buildroot}

LLVM_BUILD="%{llvm_build}"
LLVM_SRC="%{llvm_src}"
PROPELLER_BUILD="%{propeller_build}"

PREFIX="%{buildroot}/opt/llvm-propeller-23"

mkdir -p "$PREFIX/bin"
mkdir -p "$PREFIX/lib/clang/23/include"

# Clang executables.
cp -a "$LLVM_BUILD/bin/clang-23" "$PREFIX/bin/"
cp -a "$LLVM_BUILD/bin/clang++" "$PREFIX/bin/"
cp -a "$LLVM_BUILD/bin/clang-cl" "$PREFIX/bin/"
cp -a "$LLVM_BUILD/bin/clang-cpp" "$PREFIX/bin/"
cp -a "$LLVM_BUILD/bin/llvm-profgen" "$PREFIX/bin/"

# Propeller profile generator (from the propeller build tree).
cp -a "$PROPELLER_BUILD/propeller/propeller/generate_propeller_profiles" "$PREFIX/bin/"

# Preserve the Clang driver names.
ln -s clang-23 "$PREFIX/bin/clang"

# Clang builtin headers from the exact source tree used for this build.
cp -a "$LLVM_SRC/lib/Headers/." "$PREFIX/lib/clang/23/include/"

# Normalize permissions for RPM packaging.
find "$PREFIX/bin" -type f -exec chmod 0755 {} +
find "$PREFIX/lib" -type d -exec chmod 0755 {} +
find "$PREFIX/lib" -type f -exec chmod 0644 {} +

%files
/opt/llvm-propeller-23/bin/clang
/opt/llvm-propeller-23/bin/clang-23
/opt/llvm-propeller-23/bin/clang++
/opt/llvm-propeller-23/bin/clang-cl
/opt/llvm-propeller-23/bin/clang-cpp
/opt/llvm-propeller-23/bin/llvm-profgen
/opt/llvm-propeller-23/bin/generate_propeller_profiles
/opt/llvm-propeller-23/lib/clang/23/include

%changelog
* Wed Oct 07 2026 noncitizen-national <noncitizen-national@localhost> - 23.0.0-1
- Initial package of LLVM/Clang built from Google LLVM Propeller.
