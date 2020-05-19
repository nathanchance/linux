#!/usr/bin/env bash

set -eu

BASE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
BASE=${BASE%/*}

# Get parameters
function parse_parameters() {
    MY_TARGETS=()
    while ((${#})); do
        case ${1} in
            */ | *.i | *.ko | *.o | vmlinux | zImage | modules) MY_TARGETS=("${MY_TARGETS[@]}" "${1}") ;;
            *=*) export "${1?}" ;;
            -i | --incremental) INCREMENTAL=true ;;
            -j | --jobs) JOBS=${1} ;;
            -u | --update-config-only) UPDATE_CONFIG_ONLY=true ;;
            -v | --verbose) VERBOSE=true ;;
        esac
        shift
    done
    [[ -z ${MY_TARGETS[*]} ]] && MY_TARGETS=(all dtbs_install modules_install)

    # If V=, make sure -v is also set
    [[ -n ${V:-} ]] && VERBOSE=true

    # Handle architecture specific variables
    case ${ARCH:=arm64} in
        arm)
            CROSS_COMPILE=arm-linux-gnueabi-
            CONFIG=arch/arm/configs/bcm2709_defconfig
            KERNEL_IMAGE=zImage
            ;;

        arm64)
            CROSS_COMPILE=aarch64-linux-gnu-
            CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
            CONFIG=arch/arm64/configs/bcmrpi3_defconfig
            KERNEL_IMAGE=Image
            : "${LLVM_IAS:=1}"
            ;;

        *)
            echo "\${ARCH} value of '${ARCH}' is not supported!" 2>&1
            exit 22
            ;;
    esac
}

function set_toolchain() {
    # Add toolchain folders to PATH and request path override (PO environment variable)
    HERMETIC_PATH=${BASE}/bin/${ARCH}:${BASE}/bin/host:
    export PATH="${PO:+${PO}:}${CBL_LLVM:+${CBL_LLVM}:}${HERMETIC_PATH}${CBL_BNTL:+${CBL_BNTL}:}${PATH}"

    # Use ccache if it exists
    CCACHE=$(command -v ccache)

    # Set default values if user did not supply them above
    true \
        "${AR:=llvm-ar}" \
        "${CC:=${CCACHE:+ccache }clang}" \
        "${HOSTAR:=llvm-ar}" \
        "${HOSTCC:=${CCACHE:+ccache }clang}" \
        "${HOSTCXX:=${CCACHE:+ccache }clang++}" \
        "${HOSTLD:=ld.lld}" \
        "${HOSTLDFLAGS:=-fuse-ld=lld}" \
        "${JOBS:="$(nproc)"}" \
        "${LD:=ld.lld}" \
        "${LLVM_IAS:=0}" \
        "${NM:=llvm-nm}" \
        "${O:=${BASE}/out/${ARCH}}" \
        "${OBJCOPY:=llvm-objcopy}" \
        "${OBJDUMP:=llvm-objdump}" \
        "${OBJSIZE:=llvm-size}" \
        "${READELF:=llvm-readelf}" \
        "${STRIP:=llvm-strip}"

    # Resolve O=
    O=$(readlink -f -m "${O}")

    printf '\n\e[01;32mToolchain location:\e[0m %s\n\n' "$(dirname "$(command -v "${CC##* }")")"
    printf '\e[01;32mToolchain version:\e[0m %s \n\n' "$("${CC##* }" --version | head -n1)"
}

function kmake() {
    set -x
    time make \
        -C "${BASE}" \
        -j"${JOBS}" \
        ${COND_MAKE_ARGS:+"${COND_MAKE_ARGS[@]}"} \
        AR="${AR}" \
        ARCH="${ARCH}" \
        CC="${CC}" \
        ${CROSS_COMPILE:+CROSS_COMPILE="${CROSS_COMPILE}"} \
        ${CROSS_COMPILE_COMPAT:+CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT}"} \
        HOSTAR="${AR}" \
        HOSTCC="${HOSTCC}" \
        HOSTCXX="${HOSTCXX}" \
        HOSTLD="${HOSTLD}" \
        HOSTLDFLAGS="${HOSTLDFLAGS}" \
        INSTALL_DTBS_PATH=rootfs \
        INSTALL_MOD_PATH=rootfs \
        KCFLAGS="${KCFLAGS--Werror}" \
        LD="${LD}" \
        LLVM_IAS="${LLVM_IAS}" \
        NM="${NM}" \
        O="$(realpath -m --relative-to="${BASE}" "${O}")" \
        OBJCOPY="${OBJCOPY}" \
        OBJDUMP="${OBJDUMP}" \
        OBJSIZE="${OBJSIZE}" \
        READELF="${READELF}" \
        STRIP="${STRIP}" \
        ${V:+V=${V}} \
        "${@}"
    set +x
}

function build_kernel() {
    # Build silently by default
    ${VERBOSE:=false} || COND_MAKE_ARGS=(-s)

    # Build list of configure targets
    CONFIG_MAKE_TARGETS=("${CONFIG##*/}")
    ${INCREMENTAL:=false} || CONFIG_MAKE_TARGETS=(distclean "${CONFIG_MAKE_TARGETS[@]}")

    # Build list of build targets
    ${UPDATE_CONFIG_ONLY:=false} && FINAL_MAKE_TARGETS=(savedefconfig)
    [[ -z ${FINAL_MAKE_TARGETS[*]} ]] && FINAL_MAKE_TARGETS=("${MY_TARGETS[@]}")

    # Build the kernel with targets
    rm -rf "${O}"/rootfs
    kmake "${CONFIG_MAKE_TARGETS[@]}" "${FINAL_MAKE_TARGETS[@]}"

    # Copy over new config if needed
    if ${UPDATE_CONFIG_ONLY}; then
        cp -v "${O}"/defconfig "${BASE}"/${CONFIG}
        exit 0
    fi

    # Let the user know where the kernel will be (if we built one)
    KERNEL=${O}/arch/${ARCH}/boot/${KERNEL_IMAGE}
    [[ -f ${KERNEL} ]] && printf '\n\e[01;32mKernel is now available at:\e[0m %s\n' "${KERNEL}"
}

parse_parameters "${@}"
set_toolchain
build_kernel
