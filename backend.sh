#!/bin/sh

###########
# Helpers #
###########

backend_is_installed() (
    _pkg_name="$1"
    _pkg_data_dir="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name"
    log_debug "Checking $_pkg_data_dir"
    [ -d "$_pkg_data_dir" ] && return 0
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
    _pkg_build_list=""

    for pkg in $1; do
        _pkg_dir="$(backend_get_package_dir "$pkg")" || \
            log_error "Failed to get package dir: $pkg"
        _pkg_build_list="$_pkg_build_list $_pkg_dir/$pkg.build"
    done

    trim_string_and_return "$_pkg_build_list"
)

backend_download_sources() (
    _source_list="$1"
    _checksums_list="$2"
    _job_count=0
    _tarball_list=""

    [ -z "$_source_list" ] && log_error "No sources provided"

    for _cmd in wget wget2 curl; do
        command -v "$_cmd" > /dev/null || continue
        _download_cmd="$_cmd"
        log_debug "Using $_download_cmd"
        break
    done

    case "$_download_cmd" in
        wget|wget2)
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
    trap 'kill 0 >/dev/null 2>/dev/null; exit 130' INT TERM EXIT

    for source in $_source_list; do
        case "$source" in
            *.git)
                git clone "$source" || return 1
                _sources_list="$(remove_string_from_list "$source" "$_source_list")"
                ;;

            *)
                _tarball_name="${source##*/}"
                _tarball_list="$_tarball_list $_tarball_name"

                [ -e "$CACHE_DIR/$_tarball_name" ] && continue
                log_debug "Trying to download: $source"

                # This downloads the tarballs to the cache directory
                (
                    # Make a variable in this subshell to prevent _tarball_name's 
                    # modification from affecting what is removed by the trap.
                    # The trap ensures that no tarballs are partially downloaded 
                    # to the cache
                    _file="$_tarball_name"
                    trap '
                    rm -f "${CACHE_DIR:?}/${_file:?}" 2>/dev/null
                    log_warn "Deleting cached download"' INT TERM EXIT

                    cd "${PKGDIR:?}/source_cache" || true

                    $_download_cmd "$source" || \
                        log_error "Failed to download: $source"
                    echo ""
                    trap - INT TERM EXIT
                ) &
                _job_count=$((_job_count + 1))

                # Ensures that we have no more than $PARALLEL_DOWNLOADS number of
                # subshells at a time
                if [ "$_job_count" -ge "$PARALLEL_DOWNLOADS" ]; then
                    # wait -n is better if the shell supports it
                    wait -n 2>/dev/null || wait
                    _job_count=$((_job_count - 1))
                fi
                sleep 0.05
                ;;
        esac
    done

    # Wait for the child processes to complete then remove the trap
    wait || log_error "A download failed"

    # Verify checksums if enabled. Compares every checksum to every tarball
    if [ "$CHECKSUM_CHECK" = 1 ]; then
        log_debug "Verifying checksums"
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
        _pkg_build="$(trim_string_and_return "${_pkg_dir}/${pkg}.build")"

        # shellcheck source=/dev/null
        . "$_pkg_build" || log_error "Failed to source: $_pkg_build"

        _pkg_sources="$(echo "$package_source" | awk '{print $1}')"
        _pkg_checksums="$(echo "$package_source" | awk '{print $2}')"

        # Skip package if ALL its sources already exist
        skip_pkg=true
        for src in $_pkg_sources; do
            file="${src##*/}"
            if [ ! -e "${CACHE_DIR:?}/$file" ]; then
                skip_pkg=false
                break
            fi
        done

        $skip_pkg && {
            log_debug "$pkg: all sources already cached, skipping"
            continue
        }

        _sources="$_sources $_pkg_sources"
        _checksums="$_checksums $_pkg_checksums"
    done

    # Trim spaces
    _sources="$(trim_string_and_return "$_sources")"
    _checksums="$(trim_string_and_return "$_checksums")"

    log_debug "Sources are $_sources"
    log_debug "Sums are $_checksums"

    [ -z "$_sources" ] && {
        log_debug "All sources already in cache. Skipping downloads."
        return 0
    }

    backend_download_sources "$_sources" "$_checksums" ||
        log_error "Failed to download needed source code"
)

backend_want_to_build_package() (
    [ "$CREATE_PACKAGE" = 0 ] && return 1

    _pkg="$1"
    _pkg_name="$(backend_get_package_name "$_pkg")" || \
        log_error "Failed to get package name"

    if [ ! -f "${INSTALL_ROOT:-}/${PACKAGE_CACHE:?}/$_pkg_name.tar.zst" ] \
        || [ "$INSTALL_FORCE" = 1 ]
    then
        return 0
    else
        return 1
    fi
)

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

###############
# Build Steps #
###############

backend_resolve_build_order() (
    _requested_packages="$*"

    if [ "${RESOLVE_DEPENDENCIES:-1}" = 0 ]; then
        echo "$_requested_packages"
        return 0
    fi

    _final_order="$(get_dependency_tree "$_requested_packages")"

    [ -z "$_final_order" ] && log_warn "No packages to build"
    trim_string_and_return "$_final_order"
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
    _build_dir="/${PKGDIR:?}/build/$_pkg_name"
    _url_list="$(echo "$package_source" | awk '{print $1}')"
    _needed_tarballs=""

    trap 'rm -rf ${_build_dir:?} || exit 1' INT TERM EXIT

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
    
    trap - INT TERM EXIT
)

backend_create_package() (
    _pkg="$1"
    _pkg_name="$(backend_get_package_name "$_pkg")"
    _build_dir="/${PKGDIR:?}/build/$_pkg_name/package"
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

    find . -type f -exec strip --strip-debug {} + 2>/dev/null || true

    tar -cpf - . | zstd > "${INSTALL_ROOT:-}/${PACKAGE_CACHE:?}/$_pkg_name.tar.zst" \
        || log_error "Failed to create compressed tar archive: $_pkg_name.tar.zst"
)


######################
# Installation Steps #
######################

backend_resolve_install_order() (
    backend_resolve_build_order "$@"
)

backend_install_files() (
    _pkg="$1"

    _pkg_dir="$(backend_get_package_dir "$_pkg")" || \
        log_error "Failed to get package directory for: $_pkg"
    _pkg_name="$(backend_get_package_name "$_pkg")" || \
        log_error "Failed to get package name for: $_pkg"
    _package_archive="${INSTALL_ROOT:-}/$PACKAGE_CACHE/$_pkg_name.tar.zst"
    _data_dir="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name"
    _install_dir="${INSTALL_ROOT:-}/${PKGDIR:?}/installed_packages/$_pkg_name"

    [ ! -e "$_package_archive" ] && \
        log_error "Package archive doesn't exit: $_package_archive"

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
    _install_dir="${INSTALL_ROOT:-}/${PKGDIR:?}/installed_packages/$_pkg_name"

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
    _pkg_install_dir="${INSTALL_ROOT:-}/${PKGDIR:?}/installed_packages/$_pkg_name"

    find "$_pkg_install_dir" -mindepth 1 | sed "s|^${_pkg_install_dir}/||" | \
    while read -r line; do
    (
        _source="$_pkg_install_dir/$line"
        _target="${INSTALL_ROOT:-}/$line"
        
        if [ -d "$_source" ]; then
            mkdir -p "$_target"
        else
            mkdir -p "$(dirname "$_target")"
            ln -sf "$_source" "$_target"
        fi
    ) &
    done
    wait
)

###################
# Uninstall Steps #
###################

backend_resolve_uninstall_order() (
    _requested_packages="$*"
    _uninstall_order=""

    _map_file="$(mktemp)"
    _map_dir="$(mktemp -d)"

    _job_count=0
    _max_job_nums="$(nproc)"

    trap 'for p in $_pids; do kill "$p" 2>/dev/null; done
    rm -rf ${_map_file:?} ${_map_dir:?} || true' INT TERM EXIT

    log_debug "Creating dependency map"
    # First build a map of all installed packages and their dependencies
    while read -r installed_pkg; do
        (
            _pkginfo="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$installed_pkg/PKGINFO"
            [ -f "$_pkginfo" ] || exit 0

            _deps="$(grep "^package_dependencies=" "$_pkginfo" | cut -d'=' -f2-)"

            # Print result to its own file to avoid race conditions
            printf "%s:%s\n" "$installed_pkg" "$_deps" > "${_map_dir:?}/$$"
        ) &

        _job_count=$((_job_count + 1))

        if [ "$_job_count" -ge "$_max_job_nums" ]; then
            # wait -n is better if the shell supports it
            wait -n 2>/dev/null || wait
            _job_count=$((_job_count - 1))
        fi
    done < "${INSTALL_ROOT:-}/${WORLD:?}"
    wait

    # Combine all outputs of the child processes
    cat "$_map_dir"/* > "$_map_file" 2>/dev/null
    _map="$(cat "$_map_file")"

    _reverse_deps=""

    # Checks if there is a package that has a dependency of the selected package
    log_debug "Checking if package is still needed"
    for _pkg_name in $_requested_packages; do
        _reverse_deps_temp=""
        while IFS=":" read -r installed_pkg dep; do
            if string_is_in_list "$_pkg_name" "$dep"; then
                _reverse_deps_temp="${_reverse_deps_temp:-} $installed_pkg"
            fi
        done <<- EOF
		$_map
		EOF
        [ -n "$_reverse_deps_temp" ] && \
            log_error "Cannot remove $_pkg_name: Needed by: $_reverse_deps_temp"
        _reverse_deps="$_reverse_deps $_reverse_deps_temp"
    done

    _reverse_deps="$(trim_string_and_return "$_reverse_deps")"
    _uninstall_order="$_uninstall_order $_requested_packages"

    # If all of a dependency's reverse dependencies are in the uninstall
    # order, add the dependency to the uninstall order. We need to start
    # at the top of the tree which is why we use the reversed dependency tree 
    INSTALL_FORCE=1
    _tree="$(get_dependency_tree "$_requested_packages")"

    log_debug "Reversing tree"
    # Reset and build reversed tree for this package
    for dep in $_tree; do
        _reversed_tree="${_reversed_tree:-} $dep"
    done

    log_debug "Creating uninstall order"
    for dep in $_reversed_tree; do
        # Skip if it's one of the requested packages (already in uninstall order)
        string_is_in_list "$dep" "$_uninstall_order" && continue
        
        _rdeps_list="$(echo "$_map" | awk -F: -v dep="$dep" '$1 == dep {print $2}')"
        
        _should_uninstall=1
        for rdep in $_rdeps_list; do
            if ! string_is_in_list "$rdep" "$_uninstall_order"; then
                _should_uninstall=0
                break
            fi
        done
        
        [ "$_should_uninstall" = 1 ] && [ -n "$_rdeps_list" ] && \
            log_debug "Adding $dep to uninstall order"
            _uninstall_order="$_uninstall_order $dep"
    done

    log_debug "Uninstall order is: $_uninstall_order"
    trim_string_and_return "$_uninstall_order"
)

backend_unactivate_package() (
    _pkg="$1"

    backend_is_installed "$_pkg" || log_error "Package not installed: $_pkg"

    _package_metadata_dir="${INSTALL_ROOT:-}/$METADATA_DIR/$_pkg"
    _pkgfiles="$(sort -r "$_package_metadata_dir/PKGFILES")"

    # Remove files in reverse order (deepest first)
    echo "$_pkgfiles" | while IFS= read -r file; do
    (
        _full_path="${INSTALL_ROOT:-}/$file"
        if [ -f "$_full_path" ] || [ -L "$_full_path" ]; then
            log_debug "Removing file: $_full_path"
            rm "${_full_path:?}" || log_warn "Failed to remove: $_full_path"

        fi
    ) &
    wait
    done
    
    echo "$_pkgfiles" | while IFS= read -r file; do
    (
        _full_path="${INSTALL_ROOT:-}/$file"
        if [ -d "$_full_path" ]; then
            if rmdir "${_full_path:?}" 2>/dev/null; then
                log_debug "Removed empty directory: $_full_path"
            else
                log_debug "Failed to remove directory: $_full_path"
                true
            fi
        fi
    ) &
    wait
    done
)

backend_remove_files() (
    _pkg="$1"
    _pkg_install_dir="${INSTALL_ROOT:-}/${PKGDIR:?}/installed_packages/${_pkg:?}"
    [ -d "$_pkg_install_dir" ] && rm -rf "${_pkg_install_dir:?}"
)

backend_unregister_package() (
    _pkg="$1"
    _package_metadata_dir="${INSTALL_ROOT:-}/$METADATA_DIR/$_pkg"
    _world="${INSTALL_ROOT:-}/${WORLD:?}"

    grep -vx "$_pkg" "$_world" > "$_world.tmp" && mv "$_world.tmp" "$_world"

    rm -rf "${_package_metadata_dir:?}"
)

###############
# Query Steps #
###############

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

