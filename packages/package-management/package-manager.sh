#!/bin/sh

readonly red="\x1b[31m"
readonly blue="\x1b[34m"
readonly yellow="\x1b[33m"
readonly default="\x1b[39m"

readonly METADATA_DIR="/var/lib/pkg"
readonly INSTALLED="/$METADATA_DIR/installed"

git=0
verbose=0
install=0
create_package=0
uninstall=0
cleanup=1
certificate_check=1
destdir=""
download_cmd=""
pwd="$PWD"
package=""
install_root=""
patch_list=""

log_error() {
    printf "%b[ERROR]%b: %s\n" "$red" "$default" "$1" >&2
    exit 1
}

log_warn() {
    printf "%b[WARNING]%b: %s\n" "$yellow" "$default" "$1" >&2
}

log_debug() {
    [ "$verbose" = 1 ] && printf "%b[DEBUG]%b: %s\n" "$blue" "$default" "$1"
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        _arg="$1"
        case "$_arg" in
            -?*)
                _arg="${_arg#-}"

                # First letter
                _action="${_arg%"${_arg#?}"}"

                # Everything after the first letter
                _arg="${_arg#?}"

                case "$_action" in
                    B)
                        create_package=1
                        while [ -n "$_arg" ]; do
                            _char="${_arg%"${_arg#?}"}"
                            _arg="${_arg#?}"
                            case "$_char" in
                                k) certificate_check=0 ;;
                                c) cleanup=0 ;;
                                v) verbose=1 ;;
                                *) log_error "In parse_arguments: Invalid option for -B: -$_char" ;;
                            esac
                        done ;;
                    I)
                        install=1
                        while [ -n "$_arg" ]; do
                            _char="${_arg%"${_arg#?}"}"
                            _arg="${_arg#?}"
                            case "$_char" in
                                r) install_root="$2"; shift;;
                                c) cleanup=0 ;;
                                v) verbose=1 ;;
                                *) log_error "In parse_arguments: Invalid option for -I: -$_char" ;;
                            esac
                        done ;;
                    U)
                        uninstall=1
                        while [ -n "$_arg" ]; do
                            _char="${_arg%"${_arg#?}"}"
                            _arg="${_arg#?}"
                            case "$_char" in
                                v) verbose=1 ;;
                                *) log_error "In parse_arguments: Invalid option for -U: -$_char" ;;
                            esac
                        done ;;
                    S)
                        search=1
                        while [ -n "$_arg" ]; do
                            _char="${_arg%"${_arg#?}"}"
                            _arg="${_arg#?}"
                            case "$_char" in
                                i) show_info=1 ;;
                                l) list_files=1 ;;
                                v) verbose=1 ;;
                                *) log_error "In parse_arguments: Invalid option for -S: -$_char" ;;
                            esac
                        done ;;
                esac
                shift ;;
            *)
                _last_arg="$(eval "echo \${$#}")"
                if [ -f "$_last_arg" ]; then
                    package="$_last_arg"
                    log_debug "In parse_arguments: Package is $package"
                elif [ -d "$1" ]; then
                    [ "$create_package" = 1 ] && package="$_last_arg/$(basename "$_last_arg").build"
                    [ "$install" = 1 ] && {
                        package="$_last_arg/$(basename "$_last_arg")"
                    }
                else
                    log_error "In parse_arguments: Invalid argument: $1"
                fi
                shift ;;
        esac
    done
}

change_directory() {
    # Change directory to where the package is
    _dirname="$(realpath "$(dirname "$package")")"
    log_debug "In change_directory: Changing directory: $_dirname"
    cd "$_dirname" || log_error "In unpack_source: Failed to change directory: $_dirname"
}

download() {
    [ -z "$download_cmd" ] && {
        log_debug "In download: Checking for wget, wget2, or curl"
        for _arg in wget wget2 curl; do
            command -v "$_arg" > /dev/null || continue
            download_cmd="$_arg"
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

    case "$1" in
        *.git)
            git clone "$1" || return 1 ;;
        *)
            # We specifically do not want a quoted string
            $download_cmd "$1" || return 1
            _filename="${1##*/}"
    esac
}

fetch_source() {
    log_debug "In fetch_source: Creating build directory"
    [ -d ./build ] && log_error "In fetch_source: build directory already exists. Please remove it"

    mkdir ./build
    # We ensured this will always work
    cd ./build || true

    log_debug "In fetch_source: Checking if sources were provided"
    [ -z "$package_source" ] && log_error "In fetch_source: No sources provided"

    for source in $package_source; do
        download "$source" || log_error "In fetch_source: Failed to download source: $patch"
        tarball_list="$tarball_list $_filename"
    done

    for patch in $patches; do
        download "$patch" || log_error "In fetch_source: Failed to download patch: $patch"
        patch_list="$patch_list $_filename"
    done

    return 1
}

unpack_source() {
    [ "$git" = 0 ] && {
        log_debug "In unpack_source: unpacking tarball"
        
        for tarball in $tarball_list; do
            tar -xf "$tarball" || log_error "In unpack_source: Failed to unpack: $tarball"
        done
    }

    # Provided by the build script hopefully, but a reasonable fallback is provided here
    [ -z "$source_dir" ] && {
        if [ "$git" = 1 ]; then
            source_dir="$package_name"
        else
            source_dir="$package_name-$package_version"
        fi
    }

    cd "$source_dir" || log_error "In unpack_source: $source_dir does not exist"

    [ -n "$patch_list" ] && {
        log_debug "In unpack_source: moving patches to source directory"
        for patch in $patch_list; do
            [ -n "$patch" ] && {
                mv "../$patch" . || log_error "In unpack_source: Failed to move patch: $patch"
            }
        done
    }
}

build_source() {
    log_debug "In build_source: Configuring build"
    configure || log_error "In build_source: In $package: In configure: "

    log_debug "In build_source: Building package"
    build || log_error "In build_source: In $package: In build: "
}

install_package() {
    package="$(basename "$package")"
    log_debug "In install_package: Installing package"
    cd "$_dirname" || true
    mkdir -p ./install/
    cd ./install || true
    log_debug "In install_package: Extracting: $package"
    log_debug "In install_package: Current directory: $PWD"
    
    # Find the archive file
    _found=""
    for _file in "../$package.tar"*; do
        [ -f "$_file" ] || continue
        [ -n "$_found" ] && log_error "In install_package: Multiple archives found for $package"
        _found="$_file"
    done
    [ -z "$_found" ] && log_error "In install_package: Archive not found: $package"
    
    tar -xpf "$_found" || log_error "In install_package: Failed to extract tar archive"

    package_name=$(awk -F= '/^package_name/ {print $2}' PKGINFO)
    package_version=$(awk -F= '/^package_version/ {print $2}' PKGINFO)

    _data_dir="$install_root$METADATA_DIR/$package_name"
    log_debug "In install_package: data dir is: $_data_dir"
    mkdir -p "$_data_dir" || \
        log_error "In install_package: Failed to create directory: $_data_dir"

    [ -f ./PKGFILES ] && mv ./PKGFILES "$_data_dir"
    [ -f ./PKGINFO ]  && mv ./PKGINFO  "$_data_dir"

    # Add package name to world file
    grep -x "$package_name" "$install_root$INSTALLED" >/dev/null 2>&1 || \
        echo "$package_name" >> "$install_root$INSTALLED"

    find . \( -type f -o -type l \) | while IFS= read -r file; do
        target="$install_root/${file#./}"
        targetdir="$(dirname "$target")"
        
        mkdir -p "$targetdir"
        
        # Install to temp location first
        temp_target="${target}.pkg-new"
	cp -a "$file" "$temp_target"
        
        # Atomically replace with rename
        mv "$temp_target" "$target"
    done
}

build_package() {
    log_debug "In build_package: Building package"
    mkdir -p "$_dirname/build/package"
    destdir="$(realpath "$_dirname/build/package")"
    log_debug "In build_package: DESTDIR is: $destdir"
    install_files || log_error "In build_package: In $package: In install_files"
    cd "$destdir" || log_error "In build_package: Failed to change directory: $destdir"

    log_debug "In build_package: Creating metadata"
    cat > "$destdir/PKGINFO" <<EOF
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

# Cleanup is extremely important, so it's very verbose
cleanup() {
    if [ "$cleanup" = 1 ]; then
        log_debug "In cleanup: Running cleanup"
        log_debug "In cleanup: cd $_dirname"
        [ -n "$_dirname" ] && cd "$_dirname" || true

        log_debug "In cleanup: rm -rf ./build/"
        # Tarballs, git repos, and patches were downloaded to build dir
        [ -d ./build/ ] && rm -rf ./build/

        log_debug "In cleanup: rm -rf ./install/"
        [ -d ./install/ ] && rm -rf ./install/

        log_debug "In cleanup: cd $pwd"
        cd "$pwd" || true

        cleanup=0
    else
        log_warn "In cleanup: Cleanup called, but was disabled"
    fi
}

main_install() {
    change_directory
    install_package
    echo "Successful!"
    exit 0
}

main_build() {
    log_debug "Sourcing $package"
    . $(realpath "$package")

    change_directory
    fetch_source
    [ "$git" = 0 ] && unpack_source
    build_source
    build_package
    echo "Successful!"
    exit 0
}

main_uninstall() {
    log_debug "In main_uninstall: Uninstalling package"
    
    _found=""
    for _dir in "$METADATA_DIR"/*; do
        [ -d "$_dir" ] || continue
        _name=$(awk -F= '/^package_name/ {print $2}' "$_dir/PKGINFO" 2>/dev/null)
        [ "$_name" = "$package" ] && {
            _found="$_dir"
            break
        }
    done
    
    [ -z "$_found" ] && log_error "In main_uninstall: Package not found: $package"
    log_debug "In main_uninstall: Found metadata at: $_found"
    [ -f "$_found/PKGFILES" ] || log_error "In main_uninstall: PKGFILES not found for $package"
    
    # Remove files in reverse order (deepest first)
    log_debug "In main_uninstall: Removing files"
    sort -r "$_found/PKGFILES" | while IFS= read -r file; do
        _full_path="$file"
        if [ -f "$_full_path" ]; then
            log_debug "In main_uninstall: Removing file: $_full_path"
            rm "$_full_path" || log_warn "In main_uninstall: Failed to remove: $_full_path"
        elif [ -d "$_full_path" ]; then
            rmdir "$_full_path" 2>/dev/null && log_debug "In main_uninstall: Removed empty directory: $_full_path"
        fi
    done
    
    log_debug "In main_uninstall: Removing package name from world"
    grep -vx "$package" "$INSTALLED" > "$INSTALLED.tmp" && mv "$INSTALLED.tmp" "$INSTALLED"
    
    log_debug "In main_uninstall: Removing metadata: $_found"
    rm -rf "$_found"
    
    echo "Successfully uninstalled $package"
}

main() {
    trap cleanup INT TERM EXIT
    log_debug "In main: Parsing arguments"
    parse_arguments "$@"

    [ "$install" = 1 ] && main_install
    [ "$uninstall" = 1 ] && main_uninstall
    [ "$create_package" = 1 ] && main_build
}

main "$@"
