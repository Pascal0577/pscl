#!/bin/sh

readonly red="\x1b[31m"
readonly blue="\x1b[34m"
readonly yellow="\x1b[33m"
readonly default="\x1b[39m"

readonly METADATA_DIR="/var/lib/pkg"
readonly INSTALLED="$METADATA_DIR/installed"

git=0               # Whether we are using a git repo as a source
verbose=0           # Enable verbose messages
install=0           # Are we installing a package?
create_package=0    # Are we building a package?
uninstall=0         # Are we uninstalling a package?
query=0             # Are we querying a package's info?
cleanup=1           # Whether to cleanup the build directory when building packages
resolve_dependencies=1
certificate_check=1 # Whether to perform cert checks when downloading sources
checksum_check=1    # Whether to download and verify checksums of downloaded tarballs when building
destdir=""          # Used when building packages
download_cmd=""     # Used to download tarball sources later. See download function
pwd="$PWD"          # Keep track of the directory we ran the command from
arguments=""        # The argument passed to the script
install_root=""     # The root of the install. Used for bootstrapping
package_directory=""

sources_list=""
checksums_list=""
repository_list="${repository_list:-/sources/package-management/packages}"

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
    while [ $# -gt 0 ]; do
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
                                b) resolve_dependencies=0 ;;
                                c) cleanup=0 ;;
                                v) verbose=1 ;;
                                *) log_error "Invalid option for -B: -$_char" ;;
                            esac
                        done
                        shift
                        for arg in "$@"; do
                            [ -f "$arg" ] && arguments="$arguments $arg"
                            [ -d "$arg" ] && arguments="$arguments $arg/$(basename "$arg").build"
                        done
                        return 0 ;;
                    I)
                        install=1
                        while [ -n "$_flag" ]; do
                            _char="${_flag%"${_flag#?}"}"
                            _flag="${_flag#?}"
                            case "$_char" in
                                r) install_root="$2"; shift ;;
                                b) resolve_dependencies=0 ;;
                                c) cleanup=0 ;;
                                v) verbose=1 ;;
                                *) log_error "Invalid option for -I: -$_char" ;;
                            esac
                        done
                        shift
                        for arg in "$@"; do
                            [ -f "$arg" ] && arguments="$arguments $arg"
                            [ -d "$arg" ] && arguments="$arguments $arg/$(basename "$arg").tar.xz"
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
    done
}

change_directory() {
    # Change directory to where the package is
    for repo in $repository_list; do
        package_directory="$(realpath "$(dirname "$1")")"
        log_debug "In change_directory: Changing directory: $package_directory"
        cd "$package_directory" || log_error "In unpack_source: Failed to change directory: $package_directory"
    done
}

# Check if a package is already installed
is_installed() {
    _pkg_name="$1"
    [ -d "$install_root/$METADATA_DIR/$_pkg_name" ] && return 0
    return 1
}

# Cleanup is extremely important, so it's very verbose
cleanup() {
    if [ "$cleanup" = 1 ]; then
        for arg in $BUILD_ORDER; do
            log_debug "In cleanup: Running cleanup"
            for repo in $repository_list; do
                [ -d "$repo/$arg" ] && arg_dir="$repo/$arg"
            done
            change_directory "$arg_dir"

            log_debug "In cleanup: rm -rf $(realpath "./$arg/build/")"
            # Tarballs, git repos, and patches were downloaded to build dir
            [ -d ./build/ ] && rm -rf ./build/

            log_debug "In cleanup: rm -rf $(realpath "./$arg/install/")"
            [ -d ./install/ ] && rm -rf ./install/

            log_debug "In cleanup: cd $pwd"
            cd "$pwd" || true
        done

        cleanup=0
    else
        log_warn "In cleanup: Cleanup called, but was disabled"
    fi
}

string_is_in_list() {
    _string="$1"
    shift
    _list="${*:-}"
    for word in $_list; do
        [ "$_string" = "$word" ] && return 0
    done
    return 1
}

remove_string_from_list() {
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
}

find_package_build() {
    _pkg="$1"
    for repo in $repository_list; do
        if [ -f "$repo/$_pkg/$_pkg.build" ]; then
            echo "$repo/$_pkg/$_pkg.build"
            return 0
        fi
    done
    log_error "In find_package_build: Could not find build file for: $_pkg"
}

list_of_dependencies() {
    _package="$(basename "$1")"

    for repo in $repository_list; do
        if [ -d "$repo/$_package" ]; then
            _dependency_list="$(grep "package_dependencies=" "$repo/$_package/$_package.build" | \
                sed 's/package_dependencies=//')"
            _dependency_list="${_dependency_list##\"}"
            _dependency_list="${_dependency_list%%\"}"
            break
        fi
    done

    echo "$_dependency_list"
}

get_dependency_graph() {
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
}

download() {
    # If the source is a git repo, then clone it. Otherwise, use the download command
    case "$1" in
        *.git)
            git clone "$1" || return 1 ;;
        *)
            # Figure out how to download the sources based on whether wget or curl is installed
            [ -z "$download_cmd" ] && {
                log_debug "In download: Checking for wget, wget2, or curl"
                for _cmd in wget wget2 curl; do
                    command -v "$_cmd" > /dev/null || continue
                    download_cmd="$_cmd"
                    log_debug "In download: Using $download_cmd to download $1"
                    break
                done

                [ -z "$download_cmd" ] && log_error "In download: no suitable download tools found"
                [ "$certificate_check" = 0 ] && log_warn "In download: Certificate check is disabled"

                case "$download_cmd" in
                    wget|wget2)
                        [ "$certificate_check" = 0 ] && download_cmd="$download_cmd --no-check-certificate" ;;
                    curl)
                        [ "$certificate_check" = 0 ] && download_cmd="$download_cmd -k"
                        download_cmd="$download_cmd -L -O" ;;
                esac
            }

            # We specifically do not want a quoted string
            $download_cmd "$1" || return 1
            _name_of_downloaded_file="${1##*/}"
    esac
}

parse_sources() {
    # Read the package source line-by-line 
    log_debug "In parse_sources: Parsing sources list"
    while IFS= read -r line; do
        _source="$(printf '%s\n' "$line" | awk '{print $1}')"
        _checksum="$(printf '%s\n' "$line" | awk '{print $2}')"
        sources_list="$sources_list $_source"
        checksums_list="$checksums_list $_checksum"
    # THESE ARE INDENTED WITH TAB CHARACTERS FOR BETTER FORMATTING
    # THESE ARE NOT SPACES
    done <<- EOF
	$package_source
	EOF
}

# Fetches all of the listed sources using the download function
fetch_source() {
    log_debug "In fetch_source: Creating build directory"
    [ -d ./build ] && log_error "In fetch_source: build directory already exists. Please remove it"

    mkdir ./build
    cd ./build || true

    log_debug "In fetch_source: Checking if sources were provided"
    [ -z "$package_source" ] && log_error "In fetch_source: No sources provided"

    for source in $sources_list; do
        download "$source" || log_error "In fetch_source: Failed to download source: $source"
        tarball_list="$tarball_list $_name_of_downloaded_file"
    done

    return 0
}

verify_checksum_if_needed() {
    # For every tarball, check it against every provided checksum
    if [ "$checksum_check" = 1 ]; then
        for tarball in $tarball_list; do
            _md5sum="$(md5sum "$tarball" | awk '{print $1}')"
            _checksum_verified=0
            for checksum in $checksums_list; do
                [ "$_md5sum" = "$checksum" ] && {
                    _checksum_verified=1
                    log_debug "Checksum verified!"
                }
            done
            [ "$_checksum_verified" = 0 ] && \
                log_error "In verify_checksum_if_needed: Failed to verify $tarball"
        done
    else
        return 0
    fi
}

unpack_source_if_needed() {
    if [ "$git" = 0 ]; then
        log_debug "In unpack_source_if_needed: unpacking tarball"
        
        for tarball in $tarball_list; do
            tar -xf "$tarball" || \
                log_error "In unpack_source_if_needed: Failed to unpack: $tarball"
        done
    else
        return 0
    fi
}

move_patches_if_needed() {
    for patch in "$package_directory"/*.patch; do
        log_debug "In move_patches_if_needed: Moving $arguments to $package_directory/build/"
        cp -a "$patch" "$package_directory/build"
    done
}

compile_source() {
    cd "$package_directory/build/" || true

    log_debug "In compile_source: Configuring build. Current directory is $PWD"
    configure || log_error "In compile_source: In $arguments: In configure: "

    log_debug "In compile_source: Building package. Current directory is $PWD"
    build || log_error "In compile_source: In $arguments: In build: "
}

install_package() {
    _package_to_install="$1"
    _package_to_install="$(basename "$_package_to_install")"
    log_debug "In install_package: Installing package"
    # cd "$package_directory" || true
    mkdir -p ./install/
    cd ./install || true
    log_debug "In install_package: Extracting: $_package_to_install"
    log_debug "In install_package: Current directory: $PWD"
    
    tar -xpf "../$_package_to_install" || log_error "In install_package: Failed to extract tar archive"

    package_name=$(awk -F= '/^package_name/ {print $2}' PKGINFO)
    package_version=$(awk -F= '/^package_version/ {print $2}' PKGINFO)

    _data_dir="$install_root/$METADATA_DIR/$package_name"
    log_debug "In install_package: data dir is: $_data_dir"

    # Create it if it doesn't exist already
    mkdir -p "$_data_dir" || \
        log_error "In install_package: Failed to create directory: $_data_dir"

    [ -f ./PKGFILES ] && mv ./PKGFILES "$_data_dir"
    [ -f ./PKGINFO ]  && mv ./PKGINFO  "$_data_dir"

    # Add package name to world file
    grep -x "$package_name" "$install_root/$INSTALLED" >/dev/null 2>&1 || \
        echo "$package_name" >> "$install_root/$INSTALLED"

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
        mv "$temp_target" "$target"
    done
}

build_package() {
    log_debug "In build_package: Building package"
    mkdir -p "$package_directory/build/package"
    destdir="$(realpath "$package_directory/build/package")"
    log_debug "In build_package: DESTDIR is: $destdir"
    install_files || log_error "In build_package: In $arguments: In install_files"
    cd "$destdir" || log_error "In build_package: Failed to change directory: $destdir"

    log_debug "In build_package: Creating metadata"
    cat > "$destdir/PKGINFO" <<- EOF
		package_name=$package_name
		package_version=${package_version:-unknown}
		builddate=$(date +%s)
		source = $package_source
	EOF

    find . ! -name '.' ! -name 'PKGFILES' ! -name 'PKGINFO' \
        \( -type f -o -type l -o -type d \) -printf '%P\n' > PKGFILES

    tar -cpf "../../$package_name.tar" . || log_error "In build_package: Failed to create tar archive: $package_name.tar"
    xz "../../$package_name.tar" || log_error "In build_package: Failed to compress tar archive: $package_name.tar.xz"
}

main_install() {
    change_directory "$1"
    install_package "$1"
    echo "Successful!"
    cd "$pwd" || true
}

main_build() {
    _package_to_build="$1"

    log_debug "Sourcing $_package_to_build"

    # shellcheck source=/dev/null
    . "$(realpath "$_package_to_build")"

    change_directory "$_package_to_build"
    parse_sources
    fetch_source
    verify_checksum_if_needed
    unpack_source_if_needed
    move_patches_if_needed
    compile_source
    build_package
    echo "Successful!"
    cd "$pwd" || true
}

main_uninstall() {
    _package_to_uninstall="$1"

    log_debug "In main_uninstall: Uninstalling package"
    
    _found="$install_root/$METADATA_DIR/$_package_to_uninstall"
    
    [ -z "$_found" ] && log_error "In main_uninstall: Package not found: $_package_to_uninstall"
    log_debug "In main_uninstall: Found metadata at: $_found"
    [ -f "$_found/PKGFILES" ] || log_error "In main_uninstall: PKGFILES not found for $_package_to_uninstall"
    
    # Remove files in reverse order (deepest first)
    log_debug "In main_uninstall: Removing files"
    sort -r "$_found/PKGFILES" | while IFS= read -r file; do
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
    
    log_debug "In main_uninstall: Removing metadata: $_found"
    rm -rf "${_found:?In main_install: _found is unset}"
    
    echo "Successfully uninstalled $_package_to_uninstall"

    unset "$_found"

    cd "$pwd" || true
}

main_query() {
    [ "$show_info" = 1 ]   && cat "$install_root/$METADATA_DIR/$1/PKGINFO"
    [ "$list_files" = 1 ]  && cat "$install_root/$METADATA_DIR/$1/PKGFILES"
    [ "$print_world" = 1 ] && cat "$install_root/$INSTALLED"
}

main() {
    trap cleanup INT TERM EXIT
    log_debug "In main: Parsing arguments"
    parse_arguments "$@"

    # Remove leading spaces
    arguments="${arguments#"${arguments%%[![:space:]]*}"}"
    [ -z "$arguments" ] && log_error "In main: No arguments were provided"
    log_debug "In main: arguments are: $arguments"

    if [ "$install" = 1 ]; then
        for arg in $arguments; do
            _pkg_name="$(basename "$(dirname "$arg")")"
            if [ "$resolve_dependencies" = 1 ]; then
                get_dependency_graph "$arg"
            else
                BUILD_ORDER="$BUILD_ORDER $arg"
            fi
        done
        for package_name in $BUILD_ORDER; do
            log_debug "In main: build order is: $BUILD_ORDER"
            _build_file="$(find_package_build "$package_name")"
            main_install "$_build_file"
        done && exit 0
    fi

    if [ "$create_package" = 1 ]; then
        for arg in $arguments; do
            _pkg_name="$(basename "$(dirname "$arg")")"
            if [ "$resolve_dependencies" = 1 ]; then
                result=$(get_dependency_graph "$_pkg_name" "" "" "")
                BUILD_ORDER=$(echo "$result"   | cut -d '|' -f3)
            else
                BUILD_ORDER="$BUILD_ORDER $_pkg_name"
            fi
        done
        for package_name in $BUILD_ORDER; do
            log_debug "In main: build order is: $BUILD_ORDER"
            _build_file="$(find_package_build "$package_name")"
            main_build "$_build_file"
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
