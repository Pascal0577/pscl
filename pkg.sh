#!/bin/sh

set -uC
# shellcheck disable=SC3040
( set -o pipefail >/dev/null ) && set -o pipefail

readonly red="\x1b[31m"
readonly blue="\x1b[34m"
readonly yellow="\x1b[33m"
readonly default="\x1b[39m"

readonly METADATA_DIR="/var/lib/pkg"
readonly INSTALLED="$METADATA_DIR/installed"
readonly REPOSITORY_LIST="${REPOSITORY_LIST:-/sources/package-management/packages}"
readonly LOCKFILE="/var/run/pkg.lock"

verbose=0           # Enable verbose messages
install=0           # Are we installing a package?
create_package=0    # Are we building a package?
uninstall=0         # Are we uninstalling a package?
query=0             # Are we querying a package's info?
do_cleanup=1           # Whether to cleanup the build directory when building packages
resolve_dependencies=1
build_to_install=0
install_force=0
certificate_check=1 # Whether to perform cert checks when downloading sources
checksum_check=1    # Whether to download and verify checksums of downloaded tarballs when building
pwd="$PWD"          # Keep track of the directory we ran the command from
arguments=""        # The argument passed to the script
install_root=""     # The root of the install. Used for bootstrapping

# Used in dependency resolution
BUILD_ORDER=""

log_error() {
    printf "%b[ERROR]%b: %s\n" "$red" "$default" "$1" >&2
    exit 1
}

log_warn() {
    printf "%b[WARNING]%b: %s\n" "$yellow" "$default" "$1" >&2
}

log_debug() {
    [ "$verbose" = 1 ] && printf "%b[DEBUG]%b: %s\n" "$blue" "$default" "$1" >&2
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
                    create_package=1
                    while [ -n "$_flag" ]; do
                        _char="${_flag%"${_flag#?}"}"
                        _flag="${_flag#?}"
                        case "$_char" in
                            k) certificate_check=0 ;;
                            s) checksum_check=0 ;;
                            d) resolve_dependencies=0 ;;
                            c) do_cleanup=0 ;;
                            v) verbose=1 ;;
                            *) log_error "Invalid option for -B: -$_char" ;;
                        esac
                    done
                    shift
                    for arg in "$@"; do
                        arguments="$arguments $(get_package_name "$arg")"
                    done
                    return 0 ;;
                I)
                    install=1
                    while [ -n "$_flag" ]; do
                        _char="${_flag%"${_flag#?}"}"
                        _flag="${_flag#?}"
                        case "$_char" in
                            r) install_root="$2"; shift ;;
                            b) build_to_install=1 ;;
                            d) resolve_dependencies=0 ;;
                            f) install_force=1 ;;
                            c) do_cleanup=0 ;;
                            v) verbose=1 ;;
                            *) log_error "Invalid option for -I: -$_char" ;;
                        esac
                    done
                    shift
                    for arg in "$@"; do
                        arguments="$arguments $(get_package_name "$arg")"
                    done
                    return 0 ;;
                U)
                    uninstall=1
                    while [ -n "$_flag" ]; do
                        _char="${_flag%"${_flag#?}"}"
                        _flag="${_flag#?}"
                        case "$_char" in
                            r) install_root="$2"; shift ;;
                            v) verbose=1 ;;
                            *) log_error "Invalid option for -U: -$_char" ;;
                        esac
                    done

                    shift
                    arguments="$*"
                    return 0 ;;
                Q)
                    query=1
                    while [ -n "$_flag" ]; do
                        _char="${_flag%"${_flag#?}"}"
                        _flag="${_flag#?}"
                        case "$_char" in
                            i) show_info=1 ;;
                            l) list_files=1 ;;
                            w) print_world=1 ;;
                            v) verbose=1 ;;
                            *) log_error "Invalid option for -Q: -$_char" ;;
                        esac
                    done
                    shift
                    arguments="$*"
                    return 0 ;;
            esac
            shift ;;
        *) log_error "Unexpected argument: $1" ;;
    esac
}

# Check if a package is already installed
is_installed() (
    _pkg_name="$1"
    [ -d "$install_root/$METADATA_DIR/$_pkg_name" ] && return 0
    return 1
)

get_package_name() ( basename "$1" | sed 's/\.build$//' | sed 's/\.tar.*$//' )

# Returns the directory containing the package's build script
# Takes in the package to find as the first argument and the list of respositories as the second
# Package can be either a path to a build script, path to the package directory, or just the package name
get_package_dir() (
    _pkg="$(get_package_name "$1")"
    _pkg="${_pkg%.build}"

    for repo in $REPOSITORY_LIST; do
        if [ -d "$repo/$_pkg/" ]; then
            echo "$repo/$_pkg/"
            return 0
        fi
    done

    log_error "In get_package_dir: Could not find build dir for: $_pkg"
)

# Cleanup is extremely important, so it's very verbose
cleanup() (
    set -x
    _pkg="$1"

    if [ "$do_cleanup" = 1 ]; then
        log_debug "In cleanup: Running cleanup"
        _pkg_dir="$(get_package_dir "$_pkg")"

        # Tarballs, git repos, and patches were downloaded to build dir
        [ -d "${_pkg_dir:?In cleanup: pkg dir is unset}/build/" ] && \
            rm -rf "${_pkg_dir:?In cleanup: pkg dir is unset}/build/"
        [ -d "${_pkg_dir:?In cleanup: pkg dir is unset}/install/" ] && \
            rm -rf "${_pkg_dir:?In cleanup: pkg dir is unset}/install/"
    else
        log_warn "In cleanup: Cleanup called, but was disabled"
    fi
)

string_is_in_list() (
    _string="$1"
    shift
    _list="${*:-}"

    for word in $_list; do
        [ "$_string" = "$word" ] && return 0
    done
    return 1
)

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
    # Trim leading space
    echo "$_result" | sed 's/^ //'
)

list_of_dependencies() (
    _package="$(basename "$1")"

    for repo in $REPOSITORY_LIST; do
        if [ -d "$repo/$_package" ]; then
            _dependency_list="$(grep "package_dependencies=" "$repo/$_package/$_package.build" | \
                sed 's/package_dependencies=//')"
            _dependency_list="${_dependency_list##\"}"
            _dependency_list="${_dependency_list%%\"}"
            break
        fi
    done

    echo "$_dependency_list"
)

get_dependency_graph() (
    _node=$1
    _visiting=$2
    _resolved=$3
    _order=$4

    # Errors if there's a circular dependency
    if string_is_in_list "$_node" "$_visiting"; then
        log_error "Circular dependency involving: $_node"
    fi

    if string_is_in_list "$_node" "$_resolved"; then
        echo "$_visiting|$_resolved|$_order"
        return 0
    fi

    _visiting="$_visiting $_node"

    _deps=$(list_of_dependencies "$_node")
    log_debug "In get_dependency_graph: Dependencies for $_node are: $_deps"

    for child in $_deps; do
        result=$(get_dependency_graph "$child" "$_visiting" "$_resolved" "$_order") || return 1
        _visiting=$(echo "$result" | cut -d '|' -f1)
        _resolved=$(echo "$result" | cut -d '|' -f2)
        _order=$(echo "$result" | cut -d '|' -f3)
    done

    _visiting=$(remove_string_from_list "$_node" "$_visiting")
    _resolved="$_resolved $_node"
    _order="$_order $_node"
    log_debug "In get_dependency_graph: Adding $_node to dependency graph"

    echo "$_visiting|$_resolved|$_order"
)

get_download_cmd() (
    _download_cmd=""

    log_debug "In get_download_cmd: Checking for wget, wget2, or curl"
    for _cmd in wget wget2 curl; do
        command -v "$_cmd" > /dev/null || continue
        _download_cmd="$_cmd"
        log_debug "In get_download_cmd: Using $_download_cmd"
        break
    done

    [ -z "$_download_cmd" ] && log_error "In get_download_cmd: no suitable download tools found"
    [ "$certificate_check" = 0 ] && log_warn "In get_download_cmd: Certificate check disabled"

    case "$_download_cmd" in
        wget|wget2)
            [ "$certificate_check" = 0 ] && _download_cmd="$_download_cmd --no-check-certificate" ;;
        curl)
            [ "$certificate_check" = 0 ] && _download_cmd="$_download_cmd -k"
            _download_cmd="$_download_cmd -L -O" ;;
    esac

    echo "$_download_cmd"
)

download() (
    _source="$1"
    _download_cmd="$2"

    # If the source is a git repo, then clone it. Otherwise, use the download command
    case "$_source" in
        *.git)
            git clone "$_source" || return 1 ;;
        *)
            # We specifically do not want a quoted string
            $_download_cmd "$_source" || return 1
            _name_of_downloaded_file="${_source##*/}"
            echo "$_name_of_downloaded_file"
    esac
)

prepare_sources() (
    _sources_list="$1"
    _checksums_list="$2"
    
    _download_cmd="$(get_download_cmd)"
    [ -z "$_sources_list" ] && log_error "No sources provided"
    
    _tarball_list=""
    for source in $_sources_list; do
        _tarball="$(download "$source" "$_download_cmd")"
        _tarball_list="$_tarball_list $_tarball"
    done
    
    # Verify checksums if enabled
    [ "$checksum_check" = 1 ] && {
        for tarball in $_tarball_list; do
            _md5sum="$(md5sum "$tarball" | awk '{print $1}')"
            _verified=0
            for checksum in $_checksums_list; do
                [ "$_md5sum" = "$checksum" ] && _verified=1 && break
            done
            [ "$_verified" = 0 ] && log_error "Checksum failed: $tarball"
        done
    }
    
    # Unpack tarballs
    for tarball in $_tarball_list; do
        tar -xf "$tarball" || log_error "Failed to unpack: $tarball"
    done
)

move_patches_if_needed() (
    _package="$1"
    _package_directory="$(get_package_dir "$_package")"

    log_debug "In move_patches_if_needed: Package directory it $_package_directory"
    for patch in "$_package_directory"/*.patch; do
        log_debug "In move_patches_if_needed: Moving $arguments to $_package_directory/build/"
        cp -a "$patch" "$_package_directory/build"
    done
)

build_package() (
    _pkg="$1"
    _package_directory="$(get_package_dir "$_pkg")"
    _package_name="$(get_package_name "$_pkg")"
    _package_version="${package_version:-unknown}"

    log_debug "In build_package: Package directory it $_package_directory"
    for patch in "$_package_directory"/*.patch; do
        log_debug "In move_patches_if_needed: Moving $arguments to $_package_directory/build/"
        cp -a "$patch" "$_package_directory/build"
    done

    configure || log_error "In compile_source: In $arguments: In configure: "
    build || log_error "In compile_source: In $arguments: In build: "

    log_debug "In build_package: Building package"
    mkdir -p "$_package_directory/build/package"
    export DESTDIR="$(realpath "$_package_directory/build/package")"

    # for compatibility
    destdir="$DESTDIR"

    log_debug "In build_package: DESTDIR is: $DESTDIR"
    install_files || log_error "In build_package: In $_pkg: In install_files"

    log_debug "In build_package: Creating metadata"
    cat > "$DESTDIR/PKGINFO" <<- EOF
		package_name=$_package_name
		package_version=${_package_version:-unknown}
		builddate=$(date +%s)
		source = $package_source
	EOF

    cd "$DESTDIR" || log_error "In build_package: Failed to change directory: $DESTDIR"
    find . ! -name '.' ! -name 'PKGFILES' ! -name 'PKGINFO' \
        \( -type f -o -type l -o -type d \) -printf '%P\n' > PKGFILES

    tar -Jcpf "$_package_directory/$_package_name.tar.xz" . \
        || log_error "In build_package: Failed to create tar archive: $_package_name.tar"
)

main_build() (
    _package_to_build="$1"
    _package_dir="$(get_package_dir "$_package_to_build")"

    log_debug "Sourcing $_package_to_build"

    # shellcheck source=/dev/null
    . "$(realpath "$_package_to_build")"

    mkdir -p "$_package_dir/build"
    cd "$_package_dir/build" || log_error "In main_build: Failed to change directory: $_package_dir/build"

    _sources_list="$(echo "$package_source" | awk '{print $1}')"
    _checksums_list="$(echo "$package_source" | awk '{print $2}')"

    prepare_sources "$_sources_list" "$_checksums_list"
    build_package "$_package_to_build"
    echo "Successful!"
)

main_install() (
    _pkg="$1"

    # Guarantee that no matter the input, _package_to_install always points to a compressed tar archive
    _package_directory="$(get_package_dir "$_pkg")"
    _package_name="$(get_package_name "$_pkg")"
    _package_to_install="$_package_directory/$_package_name.tar.xz"

    log_debug "In install_package: Installing package"
    mkdir -p "${_package_directory:?}/install"
    cd "$_package_directory/install" || log_error "In install_package: Failed to change directory: $_package_directory/install"

    log_debug "In install_package: Current directory: $PWD"
    log_debug "In install_package: Extracting: $_package_to_install"
    
    tar -xpf "$_package_to_install" || log_error "In install_package: Failed to extract tar archive: $_package_to_install"

    _data_dir="$install_root/$METADATA_DIR/$_package_name"
    log_debug "In install_package: data dir is: $_data_dir"

    # Create it if it doesn't exist already
    mkdir -p "$_data_dir" || \
        log_error "In install_package: Failed to create directory: $_data_dir"

    [ -f ./PKGFILES ] && mv ./PKGFILES "$_data_dir"
    [ -f ./PKGINFO ]  && mv ./PKGINFO  "$_data_dir"

    # Add package name to world file
    grep -x "$_package_name" "$install_root/$INSTALLED" >/dev/null 2>&1 || \
        echo "$_package_name" >> "$install_root/$INSTALLED"

    # Install files
    find . \( -type f -o -type l \) | while IFS= read -r file; do
        target="$install_root/${file#./}"
        targetdir="$(dirname "$target")"
        
        mkdir -p "$targetdir"
        
        # Install to temp location first
        temp_target="${target}.pkg-new"
	    cp -a "$file" "$temp_target"
        
        # Replace. This is an atomic operation
        # TODO: If the file is not owned by the package manager, keep it as $target.pkg-new
        mv "${temp_target:?}" "${target:?}"
    done
)

main_uninstall() (
    _package_to_uninstall="$1"

    log_debug "In main_uninstall: Uninstalling package"
    
    _package_metadata_dir="$install_root/$METADATA_DIR/$_package_to_uninstall"
    
    [ -z "$_package_metadata_dir" ] && log_error "In main_uninstall: Package not found: $_package_to_uninstall"
    log_debug "In main_uninstall: Found metadata at: $_package_metadata_dir"
    [ -f "$_package_metadata_dir/PKGFILES" ] || log_error "In main_uninstall: PKGFILES not found for $_package_to_uninstall"
    
    # Remove files in reverse order (deepest first)
    log_debug "In main_uninstall: Removing files"
    sort -r "$_package_metadata_dir/PKGFILES" | while IFS= read -r file; do
        _full_path="$install_root/$file"
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
    
    log_debug "In main_uninstall: Removing package name from world"
    grep -vx "$_package_to_uninstall" "$INSTALLED" > "$INSTALLED.tmp" && mv "$INSTALLED.tmp" "$INSTALLED"
    
    log_debug "In main_uninstall: Removing metadata: $_package_metadata_dir"
    rm -rf "${_package_metadata_dir:?In main_install: _package_metadata_dir is unset}"
    
    echo "Successfully uninstalled $_package_to_uninstall"

    unset "$_package_metadata_dir"

    cd "$pwd" || true
)

main_query() (
    [ "$show_info" = 1 ]   && cat "$install_root/$METADATA_DIR/$1/PKGINFO"
    [ "$list_files" = 1 ]  && cat "$install_root/$METADATA_DIR/$1/PKGFILES"
    [ "$print_world" = 1 ] && cat "$install_root/$INSTALLED"
)

get_build_order() (
    _pkgs="$1"
    _BUILD_ORDER=""

    if [ "$resolve_dependencies" = 0 ]; then
        log_warn "In get_build_order: Resolution of dependencies is disabled"
        echo "$_pkgs"
        return 0
    fi

    for pkg in $_pkgs; do
        log_debug "In get_build_order: Resolving dependencies for: $pkg"
        result=$(get_dependency_graph "$pkg" "" "" "")
        _BUILD_ORDER="$_BUILD_ORDER $(echo "$result" | cut -d '|' -f3)"
    done

    echo "$_BUILD_ORDER"
)

main() {
    exec 9>|"$LOCKFILE"
    flock -n 9 || log_error "In main: Another instance is running!"

    log_debug "In main: Parsing arguments"
    parse_arguments "$@"

    # Remove leading spaces
    arguments="${arguments#"${arguments%%[![:space:]]*}"}"
    [ -z "$arguments" ] && log_error "In main: No arguments were provided"
    log_debug "In main: arguments are: $arguments"

    trap 'if [ -n "$CURRENT_PACKAGE" ]; then cleanup "$CURRENT_PACKAGE"; fi; exit 1' INT TERM

    if [ "$install" = 1 ]; then
        BUILD_ORDER="$(get_build_order "$arguments")"
        for package_name in $BUILD_ORDER; do
            log_debug "In main: build order is: $BUILD_ORDER"
            CURRENT_PACKAGE="$package_name"
            _package_dir="$(get_package_dir "$package_name")"
            _build_file="$_package_dir/$package_name.build"
            _built_package="$_package_dir/$package_name.tar.xz"

            if is_installed "$package_name" && [ "$install_force" = 0 ]; then
                log_warn "$package_name is already installed. Set -If to force install it"
                continue
            elif [ -e "$_built_package" ]; then
                log_debug "In main: installing $_built_package"
                main_install "$_built_package"
                cleanup "$package_name"
            elif [ "$build_to_install" = 1 ]; then
                log_debug "In main: building: $_build_file"
                main_build "$_build_file"
                main_install "$_built_package"
                cleanup "$package_name"
            else
                log_error "In main: No package found."
            fi
            CURRENT_PACKAGE=""
        done && exit 0
    fi

    if [ "$create_package" = 1 ]; then
        BUILD_ORDER="$(get_build_order "$arguments")"
        for package_name in $BUILD_ORDER; do
            CURRENT_PACKAGE="$package_name"
            log_debug "In main: build order is: $BUILD_ORDER"
            _build_dir="$(get_package_dir "$package_name")"
            _build_file="$_build_dir/$package_name.build"
            _built_package="$_build_dir/$package_name.tar.xz"
            if [ ! -e "$_built_package" ]; then
                log_debug "In main: Building: $_build_file"
                main_build "$_build_file"
                cleanup "$package_name"
            fi
            CURRENT_PACKAGE=""
        done && exit 0
    fi

    if [ "$uninstall" = 1 ]; then
        for arg in $arguments; do
            main_uninstall "$arg"
        done && exit 0
    fi

    [ "$query" = 1 ] && for arg in $arguments; do
        main_query "$arg"
    done && exit 0
}

main "$@"
