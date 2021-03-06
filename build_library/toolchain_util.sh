#!/bin/bash

# Toolchain packages are treated a bit specially, since they take a
# while to build and are generally more complicated to build they are
# only built via catalyst and everyone else installs them as binpkgs.
TOOLCHAIN_PKGS=(
    sys-devel/binutils
    sys-devel/gcc
    sys-kernel/linux-headers
    sys-libs/glibc
)

# Portage arguments to enforce the toolchain to only use binpkgs.
TOOLCHAIN_BINONLY=( "${TOOLCHAIN_PKGS[@]/#/--useoldpkg-atoms=}"
                    "${TOOLCHAIN_PKGS[@]/#/--rebuild-exclude=}" )

# Portage profile to use for building out the cross compiler's SYSROOT.
# This is only used as an intermediate step to be able to use the cross
# compiler to build a full native toolchain. Packages are not uploaded.
CROSS_PROFILE["x86_64-cros-linux-gnu"]="coreos:coreos/amd64/generic"

# Map board names to CHOSTs and portage profiles. This is the
# definitive list, there is assorted code new and old that either
# guesses or hard-code these. All that should migrate to this list.
declare -A BOARD_CHOST BOARD_PROFILE
BOARD_CHOST["amd64-generic"]="x86_64-cros-linux-gnu"
BOARD_PROFILE["amd64-generic"]="coreos:coreos/amd64/generic"
BOARD_NAMES=( "${!BOARD_CHOST[@]}" )

### Generic metadata fetching functions ###

# map CHOST to portage ARCH, list came from crossdev
# Usage: get_portage_arch chost
get_portage_arch() {
    case "$1" in
        aarch64*)   echo arm;;
        alpha*)     echo alpha;;
        arm*)       echo arm;;
        hppa*)      echo hppa;;
        ia64*)      echo ia64;;
        i?86*)      echo x86;;
        m68*)       echo m68k;;
        mips*)      echo mips;;
        powerpc64*) echo ppc64;;
        powerpc*)   echo ppc;;
        sparc*)     echo sparc;;
        s390*)      echo s390;;
        sh*)        echo sh;;
        x86_64*)    echo amd64;;
        *)          die "Unknown CHOST '$1'";;
    esac
}

get_board_list() {
    local IFS=$'\n\t '
    sort <<<"${BOARD_NAMES[*]}"
}

get_chost_list() {
    local IFS=$'\n\t '
    sort -u <<<"${BOARD_CHOST[*]}"
}

get_profile_list() {
    local IFS=$'\n\t '
    sort -u <<<"${BOARD_PROFILE[*]}"
}

# Usage: get_board_arch board [board...]
get_board_arch() {
    local board
    for board in "$@"; do
        get_portage_arch $(get_board_chost "${board}")
    done
}

# Usage: get_board_chost board [board...]
get_board_chost() {
    local board
    for board in "$@"; do
        if [[ ${#BOARD_CHOST["$board"]} -ne 0 ]]; then
            echo "${BOARD_CHOST["$board"]}"
        else
            die "Unknown board '$board'"
        fi
    done
}

# Usage: get_board_profile board [board...]
get_board_profile() {
    local board
    for board in "$@"; do
        if [[ ${#BOARD_PROFILE["$board"]} -ne 0 ]]; then
            echo "${BOARD_PROFILE["$board"]}"
        else
            die "Unknown board '$board'"
        fi
    done
}

# Usage: get_cross_pkgs chost [chost2...]
get_cross_pkgs() {
    local cross_chost native_pkg
    for cross_chost in "$@"; do
        for native_pkg in "${TOOLCHAIN_PKGS[@]}"; do
            echo "${native_pkg/*\//cross-${cross_chost}/}"
        done
    done
}

### Toolchain building utilities ###

# Ugly hack to get a dependency list of a set of packages.
# This is required to figure out what to install in the crossdev sysroot.
# Usage: ROOT=/foo/bar _get_dependency_list pkgs... [--portage-opts...]
_get_dependency_list() {
    local pkgs=( ${*/#-*/} )
    local IFS=$'| \t\n'

    PORTAGE_CONFIGROOT="$ROOT" emerge "$@" --pretend \
        --emptytree --root-deps=rdeps --onlydeps --quiet | \
        sed -e 's/.*\] \([^ :]*\).*/=\1/' |
        egrep -v "(=$(echo "${pkgs[*]}")-[0-9])"
}

# Configure a new ROOT
# Values are copied from the environment or the current host configuration.
# Usage: ROOT=/foo/bar SYSROOT=/foo/bar configure_portage coreos:some/profile
_configure_sysroot() {
    local profile="$1"

    mkdir -p "${ROOT}/etc/portage"
    echo "eselect will report '!!! Warning: Strange path.' but that's OK"
    eselect profile set --force "$profile"

    cat >"${ROOT}/etc/portage/make.conf" <<EOF
$(portageq envvar -v CHOST CBUILD ROOT SYSROOT \
    PORTDIR PORTDIR_OVERLAY DISTDIR PKGDIR)
HOSTCC=\${CBUILD}-gcc
PKG_CONFIG_PATH="\${SYSROOT}/usr/lib/pkgconfig/"
EOF
}

# Dump crossdev information to determine if configs must be reganerated
_crossdev_info() {
    local cross_chost="$1"; shift
    echo -n "# "; crossdev --version
    echo "# $@"
    crossdev --show-target-cfg "${cross_chost}"
}

# Build/install a toolchain w/ crossdev.
# Usage: build_cross_toolchain chost [--portage-opts....]
install_cross_toolchain() {
    local cross_chost="$1"; shift
    local cross_pkgs=( $(get_cross_pkgs $cross_chost) )
    local cross_cfg="/usr/${cross_chost}/etc/portage/${cross_chost}-crossdev"
    local cross_cfg_data=$(_crossdev_info "${cross_chost}" stable)

    # may be called from either catalyst (root) or upgrade_chroot (user)
    local sudo=
    if [[ $(id -u) -ne 0 ]]; then
        sudo="sudo -E"
    fi

    # Only call crossdev to regenerate configs if something has changed
    if ! cmp --quiet - "${cross_cfg}" <<<"${cross_cfg_data}"
    then
        $sudo crossdev --stable --portage "$*" \
            --init-target --target "${cross_chost}"
        $sudo tee "${cross_cfg}" <<<"${cross_cfg_data}" >/dev/null
    fi

    # If binary packages are enabled try to just emerge them instead of
    # doing a full bootstrap which speeds things up greatly. :)
    if [[ "$*" == *--usepkg* ]] && \
        emerge "$@" --usepkgonly --binpkg-respect-use=y \
            --pretend "${cross_pkgs[@]}" &>/dev/null
    then
        $sudo emerge "$@" --binpkg-respect-use=y -u "${cross_pkgs[@]}"
    else
        $sudo crossdev --stable --portage "$*" \
            --stage4 --target "${cross_chost}"
    fi

    # Setup wrappers for our shiny new toolchain
    if [[ ! -e "/usr/lib/ccache/bin/${cross_chost}-gcc" ]]; then
        $sudo ccache-config --install-links "${cross_chost}"
    fi
    if [[ ! -e "/usr/lib/sysroot-wrappers/bin/${cross_chost}-gcc" ]]; then
        $sudo sysroot-config --install-links "${cross_chost}"
    fi
}
