#!/bin/sh

backend_run_checks() (
    [ -z "$ARGUMENTS" ] && [ "$PRINT_WORLD" = 0 ] && \
        log_error "Arguments were expected but none were provided"
    case "$PARALLEL_DOWNLOADS" in
        ''|*[!0-9]*)
            log_error "Invalid parallel downloads value: $PARALLEL_DOWNLOADS"
            ;;
    esac
    mkdir -p "$CACHE_DIR" || \
        log_error "Cannot create cache directory: $CACHE_DIR"
    [ -w "$CACHE_DIR" ] || \
        log_error "Cache directory: $CACHE_DIR is not writable"

    mkdir -p "${INSTALL_ROOT:-}/${PACKAGE_CACHE:?}"
)

backend_is_installed() (
    _pkg_name="$1"
    [ -d "${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name" ] && return 0
    return 1
)

backend_get_package_name() (
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
            log_error "Package does not exist: $pkg"
    done

    trim_string_and_return "$_pkg_name_list"
)

# Returns the directory containing a package's build script
backend_get_package_dir() (
    _pkg_list="$(backend_get_package_name "$1")" || \
        log_error "Failed to get package name: $1"
    _pkg_dir_list=""

    for pkg in $_pkg_list; do
        _to_test_against="$_pkg_dir_list"
        # Searches all repositories. Stops searching on the first valid package
        # that is found
        for repo in $REPOSITORY_LIST; do
            if [ -d "$repo/$pkg/" ]; then
                _pkg_dir_list="$_pkg_dir_list $repo/$pkg"
                break
            fi
        done
        [ "$_pkg_dir_list" = "$_to_test_against" ] && \
            log_error "Could not find build dir for: $pkg"
    done

    trim_string_and_return "$_pkg_dir_list"
)

# Returns the path to the build file for a package
backend_get_package_build() (
    _pkg_list="$(backend_get_package_name "$1")" || \
        log_error "Failed to get package name: $1"
    _pkg_build_list=""

    for pkg in $_pkg_list; do
        _pkg_dir="$(backend_get_package_dir "$pkg")" || \
            log_error "Failed to get package dir: $pkg"
        _pkg_build_list="$_pkg_build_list $_pkg_dir/$pkg.build"
    done

    trim_string_and_return "$_pkg_build_list"
)

backend_list_files_owned_by_package() (
    _pkg="$1"
    if backend_is_installed "$_pkg"; then
        cat "${INSTALL_ROOT:-}/${METADATA_DIR:?}/$1/PKGFILES"
    else
        log_error "Package not installed: $_pkg"
    fi
)

backend_show_package_info() (
    _pkg="$1"
    if backend_is_installed "$_pkg"; then
        cat "${INSTALL_ROOT:-}/${METADATA_DIR:?}/$1/PKGINFO"
    else
        log_error "Package not installed: $_pkg"
    fi
)

backend_print_world() (
    cat "${INSTALL_ROOT:-}/${WORLD:?}"
)

backend_query() (
    _pkg="$1"
    if [ "$PRINT_WORLD" = 1 ]; then
        backend_print_world || log_error "World file doesn't exist"
    elif [ "$LIST_FILES" = 1 ]; then
        backend_list_files_owned_by_package "$_pkg" || \
            log_error "Failed to list files owned by package"
    elif [ "$SHOW_INFO" = 1 ]; then
        backend_show_package_info "$_pkg" || log_error "Failed to get package info"
    fi
)

backend_install_files() (
    _pkg="$1"

    _pkg_dir="$(backend_get_package_dir "$_pkg")" || \
        log_error "Failed to get package directory for: $_pkg"
    _pkg_name="$(backend_get_package_name "$_pkg")" || \
        log_error "Failed to get package name for: $_pkg"
    _package_archive="$PACKAGE_CACHE/$_pkg_name.tar.zst"
    _data_dir="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name"
    _install_dir="${INSTALL_ROOT:-}/var/pkg/installed_packages/$_pkg_name"

    trap '
        [ -d "$_data_dir" ] && rm -rf "${_data_dir:?}"
        [ -d "$_install_dir" ] && rm -rf "${_install_dir:?}"
    ' INT TERM EXIT

    mkdir -p "$_install_dir"
    mkdir -p "$_data_dir"
    cd "$_install_dir" || log_error "Failed to change directory: $_install_dir"

    tar -xpvf "$_package_archive" > "$_data_dir/PKGFILES.pkg-new" \
        || log_error "Failed to extract archive: $_package_archive"

    trap - INT TERM EXIT
)

backend_register_package() (
    _pkg="$1"
    _pkg_name="$(backend_get_package_name "$_pkg")" || \
        log_error "Failed to get package name for: $_pkg"
    _data_dir="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name"
    _install_dir="${INSTALL_ROOT:-}/var/pkg/build/$_pkg_name/package"

    [ -f "$_install_dir/PKGINFO" ] && mv "$_install_dir/PKGINFO" "$_data_dir"
    [ -f "$_data_dir/PKGFILES.pkg-new" ] && \
        mv "$_data_dir/PKGFILES.pkg-new" "$_data_dir/PKGFILES"

    # Add to world file
    _world="${INSTALL_ROOT:-}/${WORLD:?}"
    grep -qx "$_pkg_name" "$_world" 2>/dev/null || \
        echo "$_pkg_name" >> "$_world"
)

backend_activate_package() (
    _pkg="$1"
    _pkg_name="$(backend_get_package_name "$_pkg")"
    _pkg_install_dir="${INSTALL_ROOT:-}/var/pkg/installed_packages/$_pkg_name"

    find "$_pkg_install_dir" -mindepth 1 | sed "s|^${_pkg_install_dir}/||" | \
    while read -r line; do
        _source="$_pkg_install_dir/$line"
        _target="${INSTALL_ROOT:-}/$line"
        
        if [ -d "$_source" ]; then
            mkdir -p "$_target"
        else
            mkdir -p "$(dirname "$_target")"
            ln -sf "$_source" "$_target"
        fi
    done
)

backend_build_source() (
    _pkg="$1"
    _pkg_dir="$(backend_get_package_dir "$_pkg")" || \
        log_error "Failed to get package directory for: $_pkg"
    _pkg_build="$(backend_get_package_build "$_pkg")" || \
        log_error "Failed to get build script for: $_pkg"

    # shellcheck source=/dev/null
    . "$(realpath "$_pkg_build")" || \
        log_error "Failed to source: $_pkg_build"

    # These come from the packages build script
    _pkg_name="${package_name:?}"
    _build_dir="/var/pkg/build/$_pkg_name"
    _url_list="$(echo "$package_source" | awk '{print $1}')"
    _needed_tarballs=""

    for url in $_url_list; do
        _needed_tarballs="$_needed_tarballs ${url##*/}"
    done
    _needed_tarballs="$(echo "$_needed_tarballs" | xargs)"

    # Create build directory and cd to it
    mkdir -p "$_build_dir"
    cd "$_build_dir" \
        || log_error "Failed to change directory: $_build_dir/build"

    # Unpack tarballs
    for tarball in $_needed_tarballs; do
        log_debug "Unpacking $tarball"
        tar -xf "$CACHE_DIR/$tarball" || log_error "Failed to unpack: $tarball"
    done

    # Move patches to the expected directory so the build script can apply them
    log_debug "Package directory is: $_build_dir"
    find "$_pkg_dir" -name "*.patch" | while read -r patch; do
        log_debug "Moving $patch to $_build_dir"
        cp -a "$patch" "$_build_dir"
    done

    # These commands are provided by the build script which was sourced in main_build
    log_debug "Building package"
    mkdir -p "$_build_dir/package"
    export DESTDIR="$(realpath "$_build_dir/package")"
    log_debug "DESTDIR is: $DESTDIR"
    configure || log_error "In $ARGUMENTS: In configure: "
    build || log_error "In $ARGUMENTS: In build: "
    install_files || log_error "In install_files"
)

backend_create_package() (
    _pkg="$1"
    _pkg_name="$(backend_get_package_name "$_pkg")"
    _build_dir="/var/pkg/build/$_pkg_name/package"
    _pkg_build="$(backend_get_package_build "$_pkg")" || \
        log_error "Failed to get build script for: $_pkg"

    # shellcheck source=/dev/null
    . "$(realpath "$_pkg_build")" || \
        log_error "Failed to source: $_pkg_build"

    cat >| "$_build_dir/PKGINFO" <<- EOF
		package_name=${package_name:?}
		package_version=${package_version:-unknown}
		package_dependencies=${package_dependencies:-}
		builddate=$(date +%s)
		source="$package_source"
	EOF

    log_debug "Creating package"
    cd "$_build_dir" || log_error "Failed to change directory: $_build_dir"

    tar -cpf - . | zstd > "${INSTALL_ROOT:-}/${PACKAGE_CACHE:?}/$_pkg_name.tar.zst" \
        || log_error "Failed to create compressed tar archive: $_pkg_name.tar.zst"
)

backend_resolve_build_order() (
    _requested_packages="$*"

    if [ "${RESOLVE_DEPENDENCIES:-1}" = 0 ]; then
        echo "$_requested_packages"
        return 0
    fi

    _final_order=""
    for pkg in $_requested_packages; do
        result=$(get_dependency_tree "$pkg" "" "" "")
        _final_order="$_final_order $(echo "$result" | cut -d '|' -f3)"
    done

    trim_string_and_return "$_final_order"
)

backend_resolve_install_order() (
    backend_resolve_build_order "$@"
)

backend_resolve_uninstall_order() (
    _requested_packages="$*"
    _final_order=""

    for _pkg_name in $_requested_packages; do
        _reverse_deps_for_pkg="$(get_reverse_dependencies "$_pkg_name")"
        [ -n "$_reverse_deps_for_pkg" ] && \
            log_error "Can't remove $_pkg_name: Needed by: $_reverse_deps_for_pkg"
        log_debug "Reverse dependencies for $_pkg_name are: $_reverse_deps_for_pkg"

        _uninstall_order="$_pkg_name"
        _tree="$(get_dependency_tree "$_pkg_name" "" "" "" | cut -d '|' -f3)"
        log_debug "Dependencies for $_pkg_name are: $_tree"

        for dep in $_tree; do
            _reverse_deps="$(get_reverse_dependencies "$dep")"
            log_debug "Reverse dependencies of dependency $dep are: $_reverse_deps"
            [ "$_reverse_deps" = "$_pkg_name" ] && \
                _uninstall_order="$_uninstall_order $dep"
        done

        log_debug "Adding $_uninstall_order to uninstall order"
        _final_order="$_final_order $_uninstall_order"
    done

    log_debug "Uninstall order is: $_final_order"
    trim_string_and_return "$_final_order"
)

backend_download_sources() (
    _source_list="$1"
    _checksums_list="$2"
    _job_count=0
    _tarball_list=""
    _pids=""

    [ -z "$_source_list" ] && log_error "No sources provided"

    for _cmd in wget wget2 curl; do
        command -v "$_cmd" > /dev/null || continue
        _download_cmd="$_cmd"
        log_debug "Using $_download_cmd"
        break
    done

    case "$_download_cmd" in
        wget|wget2)
            _download_cmd="$_download_cmd -P $CACHE_DIR"
            [ "$VERBOSE" = 0 ] && _download_cmd="$_download_cmd -q --show-progress"
            [ "$CERTIFICATE_CHECK" = 0 ] && \
                _download_cmd="$_download_cmd --no-check-certificate" ;;
        curl)
            # Fix curl later, it's a pain in the ass to work with
            [ "$CERTIFICATE_CHECK" = 0 ] && _download_cmd="$_download_cmd -k"
            _download_cmd="$_download_cmd -L -O" ;;
    esac

    [ -z "$_download_cmd" ] && log_error "No suitable download tools found"
    [ "$CERTIFICATE_CHECK" = 0 ] && log_warn "Certificate check disabled"

    # Kill all child processes if we recieve an interrupt
    # shellcheck disable=SC2154
    trap 'for p in $_pids; do kill -- -\$p 2>/dev/null; done; exit 1' INT TERM EXIT

    for source in $_source_list; do
        case "$source" in
            *.git)
                git clone "$source" || return 1
                _sources_list="$(remove_string_from_list "$source" "$_source_list")"
                ;;

            *)
                log_debug "Trying to download: $source"
                _tarball_name="${source##*/}"
                _tarball_list="$_tarball_list $_tarball_name"

                [ -e "$CACHE_DIR/$_tarball_name" ] && continue

                # This downloads the tarballs to the cache directory
                (
                    set -m
                    # Make a variable in this subshell to prevent _tarball_name's 
                    # modification from affecting what is removed by the trap.
                    # The trap ensures that no tarballs are partially downloaded 
                    # to the cache
                    _file="$_tarball_name"
                    trap '
                    rm -f "${CACHE_DIR:?}/${_file:?}" 2>/dev/null
                    exit 1' INT TERM EXIT

                    $_download_cmd "$source" || \
                        log_error "Failed to download: $source"
                    echo ""
                    trap - INT TERM EXIT
                ) &

                # Keep track of PIDs so we can kill the subshells
                # if we recieve an interrupt.
                _pids="$_pids $!"
                _job_count=$((_job_count + 1))

                # Ensures that we have no more than $PARALLEL_DOWNLOADS number of
                # subshells at a time
                if [ "$_job_count" -ge "$PARALLEL_DOWNLOADS" ]; then
                    # wait -n is better if the shell supports it
                    wait -n 2>/dev/null || wait
                    _job_count=$((_job_count - 1))
                fi
                ;;
        esac
    done

    # Wait for the child processes to complete then remove the trap
    wait || log_error "A download failed"

    # Verify checksums if enabled. Compares every checksum to every tarball
    log_debug "Verifying checksums"
    if [ "$CHECKSUM_CHECK" = 1 ]; then
        for tarball in $_tarball_list; do
            _md5sum="$(md5sum "$CACHE_DIR/$tarball" | awk '{print $1}')"
            _verified=0
            for checksum in $_checksums_list; do
                [ "$_md5sum" = "$checksum" ] && _verified=1 && break
            done
            [ "${_verified:?}" = 0 ] && \
                log_error "Checksum failed: $tarball"
        done
    fi

    trap - INT TERM EXIT
    return 0
)

backend_prepare_sources() (
    _package_list="$1"
    _sources=""
    _checksums=""

    for pkg in $_package_list; do
        _pkg_dir="$(backend_get_package_dir "$pkg")" ||
            log_error "Failed to get package dir for: $_pkg_dir"
        _pkg_build="$(trim_string_and_return "$_pkg_dir"/"$pkg".build)"

        # shellcheck source=/dev/null
        . "$_pkg_build" || log_error "Failed to source: $_pkg_build"
        _sources="$_sources $(echo "$package_source" | awk '{print $1}')"
        _checksums="$_checksums $(echo "$package_source" | awk '{print $2}')"
    done

    _sources="$(trim_string_and_return "$_sources")"
    _checksums="$(trim_string_and_return "$_checksums")"

    log_debug "Sources are $_sources"
    log_debug "Sums are $_checksums"

    backend_download_sources "$_sources" "$_checksums" || \
        log_error "Failed to download needed source code"
)

backend_unactivate_package() (
    _pkg="$1"

    backend_is_installed "$_pkg" || log_error "Package not installed: $_pkg"

    _package_metadata_dir="${INSTALL_ROOT:-}/$METADATA_DIR/$_pkg"

    # Remove files in reverse order (deepest first)
    sort -r "$_package_metadata_dir/PKGFILES" | while IFS= read -r file; do
        _full_path="${INSTALL_ROOT:-}/$file"
        if [ -f "$_full_path" ] || [ -L "$_full_path" ]; then
            log_debug "Removing file: $_full_path"
            rm "${_full_path:?}" || log_warn "Failed to remove: $_full_path"
        elif [ -d "$_full_path" ]; then
            if rmdir "${_full_path:?}" 2>/dev/null; then
                log_debug "Removed empty directory: $_full_path"
            else
                log_warn "Failed to remove directory: $_full_path"
            fi
        fi
    done
)

backend_remove_files() (
    _pkg="$1"
    _pkg_install_dir="${INSTALL_ROOT:-}/var/pkg/installed_packages/${_pkg:?}"
    [ -d "$_pkg_install_dir" ] && rm -rf "${_pkg_install_dir:?}"
)

backend_unregister_package() (
    _pkg="$1"
    _package_metadata_dir="${INSTALL_ROOT:-}/$METADATA_DIR/$_pkg"
    _world="${INSTALL_ROOT:-}/${WORLD:?}"

    grep -vx "$_pkg" "$_world" > "$_world.tmp" && mv "$_world.tmp" "$_world"

    rm -rf "${_package_metadata_dir:?}"
)

backend_want_to_build_package() (
    _pkg="$1"
    _pkg_name="$(backend_get_package_name "$_pkg")" || \
        log_error "Failed to get package name"

    if [ ! -f "${PACKAGE_CACHE:?}/$_pkg_name.tar.zst" ] || [ "$INSTALL_FORCE" = 1 ]
    then
        return 0
    else
        return 1
    fi
)
