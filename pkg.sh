#!/bin/sh

set -uC
# Set pipefail if the shell supports it
# shellcheck disable=SC3040
( set -o pipefail >/dev/null ) && set -o pipefail

readonly red="\x1b[31m"
readonly blue="\x1b[34m"
readonly yellow="\x1b[33m"
readonly green="\x1b[32m"
readonly default="\x1b[39m"

readonly METADATA_DIR="/var/pkg/metadata"
readonly INSTALLED="$METADATA_DIR/installed"
readonly REPOSITORY_LIST="${REPOSITORY_LIST:-/var/pkg/repositories/*}"
readonly LOCKFILE="/var/pkg/pkg.lock"
readonly CACHE_DIR="${CACHE_DIR:-/var/pkg/source_cache}"
readonly PACKAGE_CACHE="${PACKAGE_CACHE:-/var/pkg/package_cache}"

VERBOSE=0              # Enable verbose messages
DO_CLEANUP=1           # Whether to cleanup the build directory when building packages
PARALLEL_DOWNLOADS=5   # How many source tarballs to download at the same time
CERTIFICATE_CHECK=1    # Whether to perform cert checks when downloading sources
CHECKSUM_CHECK=1       # Whether to download and verify checksums of downloaded tarballs when building

INSTALL=0              # Are we installing a package?
CREATE_PACKAGE=0       # If there's not a package ready to INSTALL, do we build one?
RESOLVE_DEPENDENCIES=1 # Do we want to resolve dependencies while installing?
INSTALL_FORCE=0        # Do we INSTALL the package even though it's already installed?

UNINSTALL=0            # Are we uninstalling a package?
BUILD_ORDER=""

QUERY=0                # Are we querying a package's info?
SHOW_INFO=0            # Shows package metadata
PRINT_WORLD=0          # Prints all the packages installed
LIST_FILES=0           # Lists files installed by a package

ARGUMENTS=""           # The argument passed to the script

# Used in dependency resolution

log_error() {
    printf "%b[ERROR]%b: %s\n" "$red" "$default" "$1" >&2
    exit 1
}

log_warn() {
    printf "%b[WARNING]%b: %s\n" "$yellow" "$default" "$1" >&2
}

log_debug() {
    [ "$VERBOSE" = 1 ] && printf "%b[DEBUG]%b: %s\n" "$blue" "$default" "$1" >&2
}

parse_arguments() {
    _flag="$1"
    case "$_flag" in
        -?*)
            _flag="${_flag#-}"
            _action="${_flag%"${_flag#?}"}"
            _flag="${_flag#?}"

            case "$_action" in
                B)
                    CREATE_PACKAGE=1
                    while [ -n "$_flag" ]; do
                        _char="${_flag%"${_flag#?}"}"
                        _flag="${_flag#?}"
                        case "$_char" in
                            k) CERTIFICATE_CHECK=0 ;;
                            s) CHECKSUM_CHECK=0 ;;
                            d) RESOLVE_DEPENDENCIES=0 ;;
                            j) PARALLEL_DOWNLOADS="$2"; shift ;;
                            c) DO_CLEANUP=0 ;;
                            v) VERBOSE=1 ;;
                            *) log_error "Invalid option for -B: -$_char" ;;
                        esac
                    done
                    shift
                    for arg in "$@"; do
                        ARGUMENTS="$ARGUMENTS $(get_package_name "$arg")" || \
                            log_error "In parse_arguments: Package name failed: $arg"
                    done
                    return 0 ;;
                I)
                    INSTALL=1
                    while [ -n "$_flag" ]; do
                        _char="${_flag%"${_flag#?}"}"
                        _flag="${_flag#?}"
                        case "$_char" in
                            r) readonly INSTALL_ROOT="$2"; shift ;;
                            b) CREATE_PACKAGE=1 ;;
                            d) RESOLVE_DEPENDENCIES=0 ;;
                            f) INSTALL_FORCE=1 ;;
                            j) PARALLEL_DOWNLOADS="$2"; shift ;;
                            c) DO_CLEANUP=0 ;;
                            v) VERBOSE=1 ;;
                            *) log_error "Invalid option for -I: -$_char" ;;
                        esac
                    done
                    shift
                    for arg in "$@"; do
                        ARGUMENTS="$ARGUMENTS $(get_package_name "$arg")"
                    done
                    return 0 ;;
                U)
                    UNINSTALL=1
                    while [ -n "$_flag" ]; do
                        _char="${_flag%"${_flag#?}"}"
                        _flag="${_flag#?}"
                        case "$_char" in
                            r) readonly INSTALL_ROOT="$2"; shift ;;
                            v) VERBOSE=1 ;;
                            *) log_error "Invalid option for -U: -$_char" ;;
                        esac
                    done

                    shift
                    ARGUMENTS="$*"
                    return 0 ;;
                Q)
                    QUERY=1
                    while [ -n "$_flag" ]; do
                        _char="${_flag%"${_flag#?}"}"
                        _flag="${_flag#?}"
                        case "$_char" in
                            i) SHOW_INFO=1 ;;
                            l) LIST_FILES=1 ;;
                            w) PRINT_WORLD=1 ;;
                            v) VERBOSE=1 ;;
                            *) log_error "Invalid option for -Q: -$_char" ;;
                        esac
                    done
                    shift
                    ARGUMENTS="$*"
                    return 0 ;;
            esac
            shift ;;
        *) log_error "Unexpected argument: $1" ;;
    esac
}

####################
# Helper Functions #
####################

# Takes in a string, removes all leading and trailing whitespace, 
# removes duplicate slashes, and prints the resulting string
trim_string_and_return() (
    set -f
    set -- $*
    var="$(printf '%s\n' "$*")"
    echo "$var" | sed 's/\/\//\//g'
)

# Check if a package is already installed
# Returns 0 is it's installled, 1 if it's not
is_installed() (
    _pkg_name="$1"
    [ -d "${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name" ] && return 0
    return 1
)

# Gets the name of a package
# Input can be build file, tar archive, or directory
get_package_name() (
    _pkg_list="$1"
    _pkg_name_list=""

    for pkg in $_pkg_list; do
        _pkg_name_list="$_pkg_name_list $(basename "$pkg" | sed 's/\.build$//' | sed 's/\.tar.*$//')"
    done

    for pkg in $_pkg_name_list; do
        _found=0
        for repo in $REPOSITORY_LIST; do
            [ -e "$repo/$pkg/$pkg.build" ] && _found=1 && break
        done
        [ "${_found:-0}" = 0 ] && \
            log_error "In get_package_name: Package does not exist: $pkg"
    done

    trim_string_and_return "$_pkg_name_list"
)

# Returns the directory containing a package's build script
get_package_dir() (
    _pkg_list="$(get_package_name "$1")" || \
        log_error "In get_package_dir: Failed to get package name: $1"
    _pkg_dir_list=""

    for pkg in $_pkg_list; do
        _to_test_against="$_pkg_dir_list"
        # Searches all repositories. Stops searching on the first one
        for repo in $REPOSITORY_LIST; do
            if [ -d "$repo/$pkg/" ]; then
                _pkg_dir_list="$_pkg_dir_list $repo/$pkg"
                break
            fi
        done
        [ "$_pkg_dir_list" = "$_to_test_against" ] && \
            log_error "In get_package_dir: Could not find build dir for: $pkg"
    done

    trim_string_and_return "$_pkg_dir_list"
)

# Returns the path to the build file for a package
get_package_build() (
    _pkg_list="$(get_package_name "$1")" || \
        log_error "In get_package_build: Failed to get package name: $1"
    _pkg_build_list=""

    for pkg in $_pkg_list; do
        _pkg_dir="$(get_package_dir "$pkg")" || \
            log_error "In get_package_build: Failed to get package dir: $pkg"
        _pkg_build_list="$_pkg_build_list $_pkg_dir/$pkg.build"
    done

    trim_string_and_return "$_pkg_build_list"
)

# Takes in a package name and removes its build and INSTALL directories
cleanup() (
    [ "$VERBOSE" = 1 ] && set -x
    _pkg_list="$1"

    if [ "$DO_CLEANUP" = 1 ]; then
        for _pkg in $_pkg_list; do
            log_debug "In cleanup: Running cleanup"
            _pkg_dir="$(get_package_dir "$_pkg")" || continue

            # These direcorites contain build artifacts and such
            [ -d "${_pkg_dir:?In cleanup: pkg dir is unset}/build/" ] && \
                rm -rf "${_pkg_dir:?In cleanup: pkg dir is unset}/build/"
            [ -d "${_pkg_dir:?In cleanup: pkg dir is unset}/INSTALL/" ] && \
                rm -rf "${_pkg_dir:?In cleanup: pkg dir is unset}/INSTALL/"
        done
    else
        log_warn "In cleanup: Cleanup called, but was disabled"
    fi
)

# Checks if a string appears in a list of strings
string_is_in_list() (
    _string="$1"
    shift
    _list="${*:-}"

    for word in $_list; do
        [ "$_string" = "$word" ] && return 0
    done
    return 1
)

# First argument is the string we want to remove
# Second argument is the list we want to remove it from
remove_string_from_list() (
    _string="$1"
    shift
    _list="${*:-}"

    _result=""
    for word in $_list; do
        if [ "$word" != "$_string" ]; then
            _result="$_result $word"
        fi
    done

    trim_string_and_return "$_result"
)

#########################
# Dependency Management #
#########################

# Takes in a package as its argument and outputs its dependencies according to its build script
list_of_dependencies() (
    _pkg="$(get_package_name "$1")" || \
        log_error "In list_of_dependencies: Failed to get package name: $_pkg"
    _pkg_build="$(get_package_build "$_pkg")" || \
        log_error "In list_of_dependencies: Failed to get package build: $_pkg"

    # shellcheck source=/dev/null
    . "$_pkg_build" || log_error "In list_of_dependencies: Failed to source: $_pkg_build"

    # package_dependencies is a variable defined in the package's build script
    trim_string_and_return "${package_dependencies:-}"
)

# A package and its dependencies create a tree-like data structure.
# This function searches this tree and appends the deepest nodes to the beginning of output.
#
# Package as its first argument.
# Packages being explored in the tree as the second argument.
# Packages not needing to be explore as the third argument.
# Build order as the fourth argument.
#
# When calling this, only use the first argument. Leave all others empty
# i.e. get_dependency_graph "$package" "" "" ""
get_dependency_graph() (
    _node=$1
    _visiting=$2
    _resolved=$3
    _order=$4

    # Errors if there's a circular dependency
    if string_is_in_list "$_node" "$_visiting"; then
        log_error "In get_dependency_graph: Circular dependency involving: $_node"
    fi

    # If a node has been resolved, don't search its subtree
    if string_is_in_list "$_node" "$_resolved"; then
        echo "$_visiting|$_resolved|$_order"
        return 0
    fi

    _visiting="$_visiting $_node"

    # The dependencies of a package are the children
    _deps=$(list_of_dependencies "$_node") || \
        log_error "In get_dependency_graph: Failed to get dependencies for: $_node"
    log_debug "In get_dependency_graph: Dependencies for $_node are: $_deps"

    for child in $_deps; do
        # If a package is installed we don't need to resolve it
        ( is_installed "$child" ) && continue

        # Get the dependency graph of all the children recursively until there
        # are no more childen. At that point we are in the deepest part of the
        # tree and can append the child to the build order.
        result=$(get_dependency_graph "$child" "$_visiting" "$_resolved" "$_order") || \
            log_error "In get_dependency_graph: Failed to get dependency graph for: $child"
        _visiting=$(echo "$result" | cut -d '|' -f1)
        _resolved=$(echo "$result" | cut -d '|' -f2)
        _order=$(echo "$result" | cut -d '|' -f3)
    done

    _visiting=$(remove_string_from_list "$_node" "$_visiting")
    _resolved="$_resolved $_node"
    _order="$_order $_node"
    log_debug "In get_dependency_graph: Adding $_node to dependency graph"

    trim_string_and_return "$_visiting|$_resolved|$_order"
)

######################
# Download Functions #
######################

# This function figures out what tool to use to download tarballs.
# It checks for the availability of wget and curl.
# Curl is currently borked. Please use wget.
get_download_cmd() (
    _download_prefix="$1"
    _download_cmd=""

    log_debug "In get_download_cmd: Checking for wget, wget2, or curl"
    for _cmd in wget wget2 curl; do
        command -v "$_cmd" > /dev/null || continue
        _download_cmd="$_cmd"
        log_debug "In get_download_cmd: Using $_download_cmd"
        break
    done

    [ -z "$_download_cmd" ] && log_error "In get_download_cmd: no suitable download tools found"
    [ "$CERTIFICATE_CHECK" = 0 ] && log_warn "In get_download_cmd: Certificate check disabled"

    case "$_download_cmd" in
        wget|wget2)
            _download_cmd="$_download_cmd -P $_download_prefix"
            [ "$VERBOSE" = 0 ] && _download_cmd="$_download_cmd -q --show-progress"
            [ "$CERTIFICATE_CHECK" = 0 ] && _download_cmd="$_download_cmd --no-check-certificate" ;;
        curl)
            # Fix curl later, it's a pain in the ass to work with
            [ "$CERTIFICATE_CHECK" = 0 ] && _download_cmd="$_download_cmd -k"
            _download_cmd="$_download_cmd -L -O" ;;
    esac

    trim_string_and_return "$_download_cmd"
)

# First argument is list of tarballs to be downloaded.
# Second argument is the list of checksums for those tarballs
download_sources() (
    _sources_list="$1"
    _checksums_list="$2"
    _job_count=0
    _tarball_list=""
    _pids=""

    [ -z "$_sources_list" ] && log_error "No sources provided"

    # Kill all child processes if we recieve an interrupt
    # shellcheck disable=SC2154
    trap 'for p in $_pids; do kill \$p 2>/dev/null; done; exit 1' INT TERM EXIT

    _download_cmd="$(get_download_cmd "$CACHE_DIR")" || \
        log_error "In download_sources: Failed to deduce available download tool"

    for source in $_sources_list; do
        case "$source" in
            *.git)
                git clone "$source" || return 1
                _sources_list="$(remove_string_from_list "$source" "$_sources_list")" ;;

            *)
                _tarball_name="${source##*/}"
                _tarball_list="$_tarball_list $_tarball_name"

                [ -e "$CACHE_DIR/$_tarball_name" ] && continue

                # This downloads the tarballs to the cache directory
                if ! (
                    # Make a variable in this subshell to prevent _tarball_name's modification from
                    # affecting what is removed by the trap. The trap ensures that no tarballs are
                    # partially downloaded to the cache
                    _file="$_tarball_name"
                    trap 'rm -f "${CACHE_DIR:?}/${_file:?}" 2>/dev/null; exit 1' INT TERM EXIT
                    $_download_cmd "$source" || \
                        log_error "In download: Failed to download: $source"
                    echo ""
                    trap - INT TERM EXIT
                ) & then
                    exit 1
                fi

                # Keep track of PIDs so we can kill the subshells if we recieve an interrupt.
                _pids="$_pids $!"
                _job_count=$((_job_count + 1))

                # Ensures that we have no more than $PARALLEL_DOWNLOADS number of
                # subshells at a time
                if [ "$_job_count" -ge "$PARALLEL_DOWNLOADS" ]; then
                    # wait -n is better if the shell supports it
                    wait -n 2>/dev/null || wait
                    _job_count=$((_job_count - 1))
                fi ;;
        esac
    done

    # Wait for the child processes to complete then remove the trap
    wait
    trim_string_and_return "$_tarball_list"

    # Verify checksums if enabled. Compares every checksum to every tarball
    if [ "$CHECKSUM_CHECK" = 1 ]; then
        for tarball in $_tarball_list; do
            _md5sum="$(md5sum "$CACHE_DIR/$tarball" | awk '{print $1}')"
            _verified=0
            for checksum in $_checksums_list; do
                [ "$_md5sum" = "$checksum" ] && _verified=1 && break
            done
            [ "${_verified:?}" = 0 ] && \
                log_error "In download_sources: Checksum failed: $tarball"
        done
    fi

    trap - INT TERM EXIT
    return 0
)

# Takes in a list of packages and outputs a combined list of sources that they all need.
# Used so downloads can be easily parallelized.
collect_all_sources() (
    _package_list="$1"
    _sources=""
    _checksums=""
    
    for pkg in $_package_list; do
        _pkg_dir="$(get_package_dir "$pkg")" ||
            log_error "In collect_all_sources: Failed to get package dir for: $_pkg_dir"
        _pkg_build="$(trim_string_and_return "$_pkg_dir"/"$pkg".build)"

        # shellcheck source=/dev/null
        . "$_pkg_build" || \
            log_error "In collect_all_sources: Failed to source: $_pkg_build"
        _sources="$_sources $(echo "$package_source" | awk '{print $1}')"
        _checksums="$_checksums $(echo "$package_source" | awk '{print $2}')"
    done

    _sources="$(trim_string_and_return "$_sources")"
    _checksums="$(trim_string_and_return "$_checksums")"

    log_debug "In collect_all_sources: Sources are $_sources"
    log_debug "In collect_all_sources: Sums are $_checksums"

    download_sources "$_sources" "$_checksums" || \
        log_error "In collect_all_sources: Failed to download needed source code"
)

##############################
# Package Building Functions #
##############################

# First argument is a package to compile and turn into an installable tarball
main_build() (
    _pkg="$1"
    _pkg_dir="$(get_package_dir "$_pkg")" || \
        log_error "In main_build: Failed to get package directory for: $_pkg"
    _pkg_build="$(get_package_build "$_pkg")" || \
        log_error "In main_build: Failed to get build script for: $_pkg"

    # shellcheck source=/dev/null
    . "$(realpath "$_pkg_build")" || \
        log_error "In main_build: Failed to source: $_pkg_build"

    # These come from the packages build script
    _pkg_name="${package_name:?}"
    _build_dir="/var/pkg/build/$_pkg_name"
    _needed_tarballs="$(echo "$package_source" | awk '{print $1}')"
    _needed_tarballs="${_needed_tarballs##*/}"

    log_debug "In main_build: Sourcing $_pkg_build"

    # Create build directory and cd to it
    mkdir -p "$_build_dir"
    cd "$_build_dir" \
        || log_error "In main_build: Failed to change directory: $_build_dir/build"

    # Unpack tarballs
    for tarball in $_needed_tarballs; do
        log_debug "In main_build: Unpacking $tarball"
        tar -xf "$CACHE_DIR/$tarball" || log_error "Failed to unpack: $tarball"
    done

    # Move patches to the expected directory so the build script can apply them
    log_debug "In main_build: Package directory is: $_build_dir"
    for patch in "$_pkg_dir"/*.patch; do
        log_debug "In build: Moving $patch to $_build_dir"
        cp -a "$patch" "$_build_dir"
    done

    # These commands are provided by the build script which was sourced in main_build
    log_debug "In main_build: Building package"
    mkdir -p "$_build_dir/package"
    configure || log_error "In main_build: In $ARGUMENTS: In configure: "
    build || log_error "In main_build: In $ARGUMENTS: In build: "

    # So make and ninja and the like INSTALL the files to where we can easily make a tarball
    export DESTDIR="$(realpath "$_build_dir/package")"

    log_debug "In main_build: DESTDIR is: $DESTDIR"
    install_files || log_error "In main_build: In $_pkg: In install_files"

    # Metadata about the package
    # Note that these are actual tab characters, not spaces
    log_debug "In main_build: Creating metadata"
    cat >| "$DESTDIR/PKGINFO" <<- EOF
		package_name=${package_name:?}
		package_version=${package_version:-unknown}
		builddate=$(date +%s)
		source="$package_source"
	EOF

    log_debug "In main_build: Creating package"
    cd "$DESTDIR" || log_error "In main_build: Failed to change directory: $DESTDIR"

    tar -Jcpf "${INSTALL_ROOT:-}/${PACKAGE_CACHE:?}/$_pkg_name.tar.zst" . \
        || log_error "In main_build: Failed to create compressed tar archive: $_pkg_name.tar.zst"

    printf "%b[SUCCESS]%b: %b" "$green" "$default" "Successfully built $_pkg_name!"
)

main_install() (
    _pkg="$1"
    _installed_files=""
    _pids=""
    _job_count=""
    _max_jobs="$(nproc)"

    # Guarantee that no matter the input, 
    # _package_archive always points to a compressed tar archive
    _pkg_dir="$(get_package_dir "$_pkg")" || \
        log_error "In main_install: Failed to get package directory for: $_pkg"
    _pkg_name="$(get_package_name "$_pkg")" || \
        log_error "In main_install: Failed to get package name for: $_pkg"
    _package_archive="$PACKAGE_CACHE/$_pkg_name.tar.zst"

    _data_dir="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name"
    log_debug "In install_package: data dir is: $_data_dir"

    # Create it if it doesn't exist already
    mkdir -p "$_data_dir" || \
        log_error "In install_package: Failed to create dir: $_data_dir"

    # shellcheck disable=SC2154
    trap '
    for f in $_installed_files; do rm "$f" 2>/dev/null ; done
    for p in $_pids; do kill "$p" 2>/dev/null ; done
    rm -rf "${INSTALL_ROOT:-}/${METADATA_DIR:?}/${_pkg_name:?}" 2>/dev/null
    log_error "In main_install: Something went wrong. Cleaning up files..."' INT TERM EXIT

    log_debug "In install_package: Installing package"
    mkdir -p "${_pkg_dir:?}/install"
    cd "$_pkg_dir/install" || \
        log_error "In install_package: Failed to change directory: $_pkg_dir/install"

    log_debug "In install_package: Current directory: $PWD"
    log_debug "In install_package: Extracting: $_package_archive"

    tar -xpvf "$_package_archive" | grep -v '/$' | sed 's/\.\///' > "$_data_dir/PKGFILES.pkg-new" \
        || log_error "In install_package: Failed to extract archive: $_package_archive"

    IFS='
    '
    set -f

    while read -r file; do
        target="${INSTALL_ROOT:-}/${file#./}.pkg-new"
        _installed_files="$_installed_files $target"
        (
            _file="$file"
            _temp_target="$target"
            _targetdir="$(dirname "$target")"

            # Install to temp location first, then replace
            # TODO: If the file is not owned by the package manager, keep it as $target.pkg-new
            mkdir -p "$_targetdir" || \
                log_error "In main_install: Failed to make dir: $_targetdir"

            if [ -f "$_file" ] || [ -L "$_file" ]; then
                mv "${_file:?}" "${_temp_target:?}" || \
                log_error "In main_install: Failed to INSTALL temporary file: $_temp_target"
            fi
        ) &

        _pids="$_pids $!"
        _job_count=$((_job_count + 1))

        if [ "$_job_count" -ge "$_max_jobs" ]; then
            # shellcheck disable=SC3045
            wait -n 2>/dev/null || wait
            _job_count=$((_job_count - 1))
        fi
    done < "$_data_dir/PKGFILES.pkg-new"
    wait || log_error "In main_install: Failed to INSTALL temporary files"

    _pids=""
    _job_count=0

    while read -r file; do
        ( [ -e "$file" ] && mv "${file:?}" "${file%.pkg-new}" ) &
        _pids="$_pids $!"
        _job_count=$((_job_count + 1))

        if [ "$_job_count" -ge "$_max_jobs" ]; then
            # shellcheck disable=SC3045
            wait -n 2>/dev/null || wait
            _job_count=$((_job_count - 1))
        fi
    done < "$_data_dir/PKGFILES.pkg-new"
    wait || log_error "In main_install: Failed to INSTALL files"

    [ -f ./PKGINFO ] && mv ./PKGINFO "$_data_dir"
    [ -f "$_data_dir/PKGFILES.pkg-new" ] && \
        mv "$_data_dir/PKGFILES.pkg-new" "$_data_dir/PKGFILES"

    # Add package name to world file if it's not in there already
    grep -x "$_pkg_name" "${INSTALL_ROOT:-}/${INSTALLED:?}" >/dev/null 2>&1 || \
        echo "$_pkg_name" >> "${INSTALL_ROOT:-}/${INSTALLED:?}"

    trap - INT TERM EXIT
    printf "%b[SUCCESS]%b: %b\n" "$green" "$default" "Successfully installed $_pkg_name!"
)

# First argument is the name of the package we want to UNINSTALL
# TODO: Add locked packages i.e. stuff like glibc which will 
# permanently obliterate your system if you remove it
#
# Possibly set a trap that moves files back if the process is interrupted?
main_uninstall() (
    _package_to_uninstall="$1"

    log_debug "In main_uninstall: Uninstalling package"
    _package_metadata_dir="${INSTALL_ROOT:-}/$METADATA_DIR/$_package_to_uninstall"
    
    [ -z "$_package_metadata_dir" ] && log_error "In main_uninstall: Package not found: $_package_to_uninstall"
    log_debug "In main_uninstall: Found metadata at: $_package_metadata_dir"
    [ -f "$_package_metadata_dir/PKGFILES" ] || \
        log_error "In main_uninstall: PKGFILES not found for $_package_to_uninstall. Is it installed properly?"

    # Remove files in reverse order (deepest first)
    log_debug "In main_uninstall: Removing files"
    sort -r "$_package_metadata_dir/PKGFILES" | while IFS= read -r file; do
        _full_path="${INSTALL_ROOT:-}/$file"
        if [ -f "$_full_path" ]; then
            log_debug "In main_uninstall: Removing file: $_full_path"
            rm "${_full_path:?In main_uninstall: _full_path is unset}" || \
                log_warn "In main_uninstall: Failed to remove: $_full_path"
        elif [ -d "$_full_path" ]; then
            if rmdir "${_full_path:?In main_uninstall: _full_path is unset}" 2>/dev/null; then
                log_debug "In main_uninstall: Removed empty directory: $_full_path"
            else
                log_warn "In main_uninstall: Failed to remove directory: $_full_path"
            fi
        fi
    done

    # Remove package name from world file
    log_debug "In main_uninstall: Removing package name from world"
    grep -vx "$_package_to_uninstall" "$INSTALLED" > "$INSTALLED.tmp" && mv "$INSTALLED.tmp" "$INSTALLED"
 
    log_debug "In main_uninstall: Removing metadata: $_package_metadata_dir"
    rm -rf "${_package_metadata_dir:?In main_install: _package_metadata_dir is unset}"

    printf "%b[SUCCESS]%b: %b" "$green" "$default" "Successfully uninstalled $_package_to_uninstall!"
)

# Simple
main_query() (
    [ "$SHOW_INFO" = 1 ]   && cat "${INSTALL_ROOT:-}/${METADATA_DIR:?}/$1/PKGINFO"
    [ "$LIST_FILES" = 1 ]  && cat "${INSTALL_ROOT:-}/${METADATA_DIR:?}/$1/PKGFILES"
    [ "$PRINT_WORLD" = 1 ] && cat "${INSTALL_ROOT:-}/${INSTALLED:?}"
    return 0
)

# Takes in a full list of packages and uses get_dependency_graph to get the final build order
get_build_order() (
    _pkg_list="$1"
    _BUILD_ORDER=""

    if [ "$RESOLVE_DEPENDENCIES" = 0 ]; then
        log_warn "In get_build_order: Resolution of dependencies is disabled"
        trim_string_and_return "$_pkg_list"
        return 0
    fi

    for pkg in $_pkg_list; do
        log_debug "In get_build_order: Resolving dependencies for: $pkg"
        result=$(get_dependency_graph "$pkg" "" "" "") \
            || log_error "In get_build_order: Failed to create dependency graph for: $pkg"
        _BUILD_ORDER="$_BUILD_ORDER $(echo "$result" | cut -d '|' -f3)"
    done

    trim_string_and_return "$_BUILD_ORDER"
)

# Basic stuff to check before doing anything gnarly
sanity_checks() {
    [ -z "$ARGUMENTS" ] && log_error "In sanity_checks: No arguments were provided"
    case "$PARALLEL_DOWNLOADS" in
        ''|*[!0-9]*)
            log_error "In sanity_checks: Invalid parallel downloads value: $PARALLEL_DOWNLOADS"
            ;;
    esac
    mkdir -p "$CACHE_DIR" || \
        log_error "Cannot create cache directory: $CACHE_DIR"
    [ -w "$CACHE_DIR" ] || \
        log_error "In sanity_checks: Cache directory: $CACHE_DIR is not writable"
}

main() {
    exec 9>|"$LOCKFILE"
    flock -n 9 || log_error "In main: Another instance is running!"

    log_debug "In main: Parsing arguments"
    parse_arguments "$@"
    sanity_checks

    log_debug "In main: arguments are: $ARGUMENTS"

    trap 'cleanup "$BUILD_ORDER"' INT TERM EXIT

    if [ "$INSTALL" = 1 ]; then
        BUILD_ORDER="$(get_build_order "$ARGUMENTS")" || \
            log_error "In main: Failed to get build order"
        log_debug "Build order: $BUILD_ORDER"

        # Install already-built packages and remove from build list
        for pkg in $BUILD_ORDER; do
            _package_dir="$(get_package_dir "$pkg")" || \
                log_error "In main: Failed to get package dir for: $pkg"

            if is_installed "$pkg" && [ "$INSTALL_FORCE" = 0 ]; then
                log_warn "$pkg already installed. Use -If to force"
                BUILD_ORDER="$(remove_string_from_list "$pkg" "$BUILD_ORDER")"
                continue
            elif [ -e "$PACKAGE_CACHE/$pkg.tar.zst" ]; then
                main_install "$pkg" || \
                    log_error "In main: Failed to install: $pkg"
                BUILD_ORDER="$(remove_string_from_list "$pkg" "$BUILD_ORDER")"
            fi
        done

        [ -z "$BUILD_ORDER" ] && echo "Nothing to do." && exit 0
        [ "$CREATE_PACKAGE" = 0 ] && \
            log_error "No pre-built package available. Use -Ib to build package before installing"

        collect_all_sources "$BUILD_ORDER" || \
            log_error "In main: Failed to collect sources for one of: $BUILD_ORDER"

        for pkg in $BUILD_ORDER; do
            main_build "$pkg"   || log_error "In main: Failed to build: $pkg"
            main_install "$pkg" || log_error "In main: Failed to INSTALL: $pkg"
        done
        exit 0
    fi

    # Same logic as install, but simpler
    if [ "$CREATE_PACKAGE" = 1 ]; then
        BUILD_ORDER="$(get_build_order "$ARGUMENTS")" || \
            log_error "In main: Failed to get build order"

        log_debug "In main: Build order is: $BUILD_ORDER"
        [ -z "$BUILD_ORDER" ] && exit 0
        collect_all_sources "$BUILD_ORDER" || \
            log_error "In main: Failed to collect sources for one of: $BUILD_ORDER"

        for pkg in $BUILD_ORDER; do
            main_build "$pkg" || log_error "In main: Failed to build: $pkg"
        done
        exit 0
    fi

    if [ "$UNINSTALL" = 1 ]; then
        for arg in $ARGUMENTS; do
            main_uninstall "$arg" || log_error "In main: Failed to uninstall: $arg"
        done && exit 0
    fi

    [ "$QUERY" = 1 ] && for arg in $ARGUMENTS; do
        main_query "$arg" || log_error "In main: Failed to QUERY: $arg"
    done && exit 0
}

main "$@"
