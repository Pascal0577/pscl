#!/bin/sh

# shellcheck disable=SC3045

###########
# Helpers #
###########

backend_ask_confirmation() (
    # If we don't want to ask for confirmation, exit immediately
    "$ASK_CONFIRMATION" || return 0
    _type="$1"
    shift
    _packages="$*"

    _msg=""
    case "$_type" in 
        build)
            _msg="Do you want to build these packages [Y/n]: " ;;
        install)
            _msg="Do you want to install these packages [Y/n]: " ;;
        uninstall)
            _msg="Do you want to uninstall these packages [Y/n]: " ;;
        activation)
            _msg="Do you want to alter the activation status of these packages [Y/n]: " ;;
    esac

    printf "%s" "$_msg" >&2
    tput sc >&2
    
    printf "\n" >&2
    for _pkg in $_packages; do
        echo "${_pkg%%|*}" >&2
    done
    echo "" >&2
    
    tput rc >&2
    read -r _ans
    tput ed >&2

    case "$_ans" in
        y|yes|Y|"") echo "$_packages" ;;
        *) return 1 ;;
    esac
)

backend_is_installed() (
    _pkg_name="$1"
    _pkg_data_dir="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name"
    log_debug "Checking $_pkg_data_dir"
    [ -d "$_pkg_data_dir" ] && return 0
    return 1
)

# Returns a package "struct" from names, dirs, tar archives:
# pkg_name|depth|dep_type
# depth and dep_type are filled out by the install/uninstall order functions
# For now they are empty
backend_get_package_name() (
    _pkg_list="$1"
    _pkg_name_list=""

    # Get basename
    for pkg in $_pkg_list; do
        _name="${pkg##*/}"
        _name="${_name%.build}"
        _name="${_name%.tar*}"

        _pkg_name_list="$_pkg_name_list $_name|0|pkg"
    done

    # Search all repos for it
    for pkg_struct in $_pkg_name_list; do
        _pkg_name="${pkg_struct%%|*}"
        _found=0
        for repo in $REPOSITORY_LIST; do
            [ -e "$repo/$_pkg_name/$_pkg_name.build" ] && _found=1 && break
        done
        [ "$_found" = 0 ] && log_error "Package does not exist: $_pkg_name"
    done

    trim_string_and_return "$_pkg_name_list"
)

# Returns the directory containing a package's build script
backend_get_package_dir() (
    for _pkg_name in $1; do
        log_debug "Searching for $_pkg_name"
        _to_test_against="$_pkg_dir_list"
        # Searches all repositories. Stops searching on the first valid package
        # that is found
        for repo in $REPOSITORY_LIST; do
            log_debug "Searching repository: $repo"
            log_debug "Testing: [ -d $repo/$_pkg_name ]"
            if [ -d "$repo/$_pkg_name" ]; then
                log_debug "Found $_pkg_name at: $repo/$_pkg_name"
                _pkg_dir_list="$_pkg_dir_list $repo/$_pkg_name"
                break
            fi
        done

        # If the list is the same before and after we searched for the package
        # then it doesn't exit in the repos
        [ "$_pkg_dir_list" = "$_to_test_against" ] && \
            log_error "Could not find package in repository: $_pkg_name"
    done

    trim_string_and_return "$_pkg_dir_list"
)

# Returns the path to the build file for a package
backend_get_package_build() (
    for _pkg_name in $1; do
        _pkg_dir="$(backend_get_package_dir "$_pkg_name")" || \
            log_error "Failed to get package dir: $_pkg_name"
        _pkg_build_list="$_pkg_build_list $_pkg_dir/$_pkg_name.build"
    done

    trim_string_and_return "$_pkg_build_list"
)

backend_download_sources() (
    set -e
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
    [ -z "$_download_cmd" ] && log_error "No suitable download tools found"

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
    [ "$CERTIFICATE_CHECK" = 0 ] && log_warn "Certificate check disabled"

    trap 'RUN_LOOP=false' INT TERM EXIT
    for source in $_source_list; do
        "${RUN_LOOP:-true}" || break
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
                    readonly _file="$_tarball_name"
                    trap '
                    rm -f "${CACHE_DIR:?}/${_file:?}" 2>/dev/null || true
                    log_warn "Deleting cached download: $_file"' INT TERM EXIT

                    cd "${PKGDIR:?}/source_cache" || true

                    $_download_cmd "$source" || \
                        log_error "Failed to download: $source"

                    # Verify checksums if enabled.
                    # Compares every checksum to tarball
                    if [ "$CHECKSUM_CHECK" = 1 ]; then
                        log_debug "Verifying checksums"
                        _md5sum="$(md5sum "$CACHE_DIR/$_file")"
                        _md5sum="${_md5sum%% *}"
                        _verified=0
                        for checksum in $_checksums_list; do
                            [ "$_md5sum" = "$checksum" ] && _verified=1 && break
                        done
                        [ "${_verified:?}" = 0 ] && \
                            log_error "Checksum failed: $_file"
                    fi

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
                ;;
        esac
    done

    # Wait for the child processes to complete then remove the trap
    wait || log_error "A download failed"
    trap - INT TERM EXIT
    return 0
)

backend_prepare_sources() (
    [ "$CREATE_PACKAGE" = 0 ] && exit 0
    _package_list="$1"
    _sources=""
    _checksums=""

    for pkg in $_package_list; do
        log_debug "Package is: [$pkg]"
        _pkg_dir="$(backend_get_package_dir "$pkg")" ||
            log_error "Failed to get package dir for: $pkg"
        _pkg_build="${_pkg_dir}/${pkg}.build"

        # shellcheck source=/dev/null
        . "$_pkg_build" || log_error "Failed to source: $_pkg_build"

        [ -z "${package_source:-}" ] && \
            log_error "package_source not defined in $_pkg_build"

        [ "${package_source:-}" = 'N/A' ] && \
            break

        # Extract the list of sources and sums provided by the build script
        _pkg_sources=""
        _pkg_sums=""
        while IFS=' ' read -r src sum junk; do
            _pkg_sources="$_pkg_sources $src"
            _pkg_sums="$_pkg_sums $sum"
        done <<- EOF
            ${package_source:?}
		EOF
        _pkg_sources="${_pkg_sources# }"
        _pkg_sums="${_pkg_sums# }"

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
        _checksums="$_checksums $_pkg_sums"
    done

    # Trim spaces
    _sources="${_sources# }"
    _checksums="${_checksums# }"

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
    [ "$INSTALL_FORCE" = 1 ] && return 0

    _pkg_name="$1"
    [ ! -f "${INSTALL_ROOT:-}/${PACKAGE_CACHE:?}/$_pkg_name.tar.zst" ] && return 0

    return 1
)

backend_run_checks() (
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

    mkdir -p "$LOG_DIR" || \
        log_error "Cannot create log directory"
)

###############
# Build Steps #
###############

backend_resolve_build_order() (
    _requested_packages="$*"
    log_debug "Recieved packages to resolve build order for: $_requested_packages"

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
        log_error "Failed to get package directory: $_pkg"
    _pkg_build="${_pkg_dir}/${_pkg}.build"

    # shellcheck source=/dev/null
    . "$(realpath "$_pkg_build")" || \
        log_error "Failed to source: $_pkg_build"

    # These come from the packages build script
    _pkg_name="${package_name:?}"
    _build_dir="${PKGDIR:?}/build/$_pkg_name"

    # Create staging directory
    _pkg_creation_dir="$_build_dir/package"
    mkdir -p "$_pkg_creation_dir"

    # Handle the special case where we use N/A to create a metapackage
    # See libxorg.build
    [ "${package_source}" = 'N/A' ] && \
        exit 0

    while read -r url sum junk; do
        _needed_tarballs="$_needed_tarballs ${url##*/}"
    done <<- EOF
        ${package_source:?}
	EOF
    _needed_tarballs="${_needed_tarballs# }"

    trap '[ "$DO_CLEANUP" = 1 ] && rm -rf ${_build_dir:?}' INT TERM EXIT

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

    export DESTDIR="$_pkg_creation_dir"
    export PKGROOT="$_pkg_dir"
    log_debug "DESTDIR is: $DESTDIR"

    # The configure, build, and install_files
    # functions are provided by the build script
    # The install_files function respects DESTDIR
    log_debug "Building package"
    configure || log_error "Configure failed!"
    build || log_error "Build failed!"
    install_files || log_error "Installing files to package creation dir failed!"

    trap - INT TERM EXIT
)

backend_create_package() (
    _pkg="$1"
    _build_dir="/${PKGDIR:?}/build/$_pkg/package"
    _pkg_build="$(backend_get_package_build "$_pkg")" || \
        log_error "Failed to get build script for: $_pkg"

    _post_install_script="$(backend_get_package_dir "$_pkg")/post-install.sh"
    log_debug "Looking for post-install script: $_post_install_script"
    if [ -f "$_post_install_script" ]; then
        log_debug "Found post-install script"
        cp -a "$_post_install_script" "$_build_dir"
    fi

    # shellcheck source=/dev/null
    . "$(realpath "$_pkg_build")" || \
        log_error "Failed to source: $_pkg_build"

    cat >| "$_build_dir/PKGINFO" <<- EOF
		package_name=${package_name:?}
		package_version=${package_version:-unknown}
		pkg_deps="${pkg_deps:-}"
		opt_deps="${opt_deps:-}"
		build_deps="${build_deps:-}"
		check_deps="${check_deps:-}"
		builddate=$(date +%s)
		source="$(echo "$package_source" | awk '{print $1}')"
	EOF

    log_debug "Creating package"
    cd "$_build_dir" || log_error "Failed to change directory: $_build_dir"

    find . -type f -exec strip --strip-unneeded {} + 2>/dev/null || true

    tar -cpf - . | zstd > "${INSTALL_ROOT:-}/${PACKAGE_CACHE:?}/$_pkg.tar.zst" \
        || log_error "Failed to create compressed tar archive: $_pkg.tar.zst"
)


######################
# Installation Steps #
######################

backend_resolve_install_order() (
    backend_resolve_build_order "$@"
)

backend_install_files() (
    _pkg_name="$1"

    _pkg_dir="$(backend_get_package_dir "$_pkg_name")" || \
        log_error "Failed to get package directory for: $_pkg_name"
    _package_archive="${INSTALL_ROOT:-}/$PACKAGE_CACHE/$_pkg_name.tar.zst"
    _data_dir="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name"
    _install_dir="${INSTALL_ROOT:-}/${PKGDIR:?}/packages/$_pkg_name"

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
    _pkg_name="$1"
    _data_dir="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name"
    _install_dir="${INSTALL_ROOT:-}/${PKGDIR:?}/packages/$_pkg_name"
    _pkg_dir="$(backend_get_package_dir "$_pkg_name")" || \
        log_error "Failed to get package directory: $_pkg_name"
    _pkg_build="${_pkg_dir}/${_pkg_name}.build"

    [ -f "$_install_dir/PKGINFO" ] && mv "$_install_dir/PKGINFO" "$_data_dir"
    [ -f "$_data_dir/PKGFILES.pkg-new" ] && \
        mv "$_data_dir/PKGFILES.pkg-new" "$_data_dir/PKGFILES"

    . "$_pkg_build" || log_error "Failed to source: $_pkg_build"

    # Add to world file
    _world="${INSTALL_ROOT:-}/${WORLD:?}"
    grep -qx "$_pkg_name" "$_world" 2>/dev/null || \
        echo "${_pkg_name}:${package_version:-}:${pkg_deps:-}:${opt_deps:-}:${build_deps:-}:${check_deps:-}:deactivated" >> "$_world"
)

backend_activate_package() {
    _pkg_name="$1"
    _data_dir="${INSTALL_ROOT:-}/${METADATA_DIR:?}/$_pkg_name"
    _pkg_install_dir="${INSTALL_ROOT:-}/${PKGDIR:?}/packages/$_pkg_name"

    trap '
        unset _pkg_name _data_dir _pkg_install_dir _source_prefix
        [ -f "${WORLD}.tmp" ] && rm "${WORLD}.tmp"
    ' INT TERM EXIT

    [ ! -d "$_pkg_install_dir" ] && log_error "Package not installed: $_pkg_name"

    _post_install_script="${_pkg_install_dir}/post-install.sh"
    if [ -f "$_post_install_script" ]; then
        cp -a "$_post_install_script" "$_data_dir"
        register_hook post_install "$_post_install_script"
    fi

    _source_prefix="${_pkg_install_dir##"${INSTALL_ROOT:-}"}"

    find "$_pkg_install_dir" -type d -printf "%P\0" | \
        xargs -0 -r -P "$(nproc)" -I {} mkdir -p "${INSTALL_ROOT:-}/{}"

    cd "$_pkg_install_dir" || return 1
    find . -mindepth 1 -type f -printf "%P\0" | \
        xargs -0 -P "$(nproc)" -I {} ln -sf "$_source_prefix/{}" "${INSTALL_ROOT:-}/{}"
    cd - >/dev/null

    awk -F: -v pkg="$_pkg_name" '
        BEGIN{OFS=":"} $1==pkg {$7="activated"} 1
    ' "$WORLD" > "${WORLD}.tmp"
    mv "${WORLD}.tmp" "$WORLD"
}

###################
# Uninstall Steps #
###################

backend_resolve_uninstall_order() (
    _requested_packages="$*"
    _uninstall_order=""

    # If all of a dependency's reverse dependencies are in the uninstall
    # order, add the dependency to the uninstall order. We need to start
    # at the top of the tree which is why we use the reversed dependency tree 
    INSTALL_FORCE=1
    _tree="$(get_dependency_tree "$_requested_packages")"
    _uninstall_order="$_tree"

    # Now we find the reverse dependencies of everything in the dependency tree
    _reverse_deps=""
    for leaf in $_tree; do
        _leaf_name="${leaf%%|*}"
        # If the leaf is one of the requested packages, build a list of
        # its reverse dependencies so a helpful error message can be given
        string_is_in_list "$_leaf_name" "$_requested_packages" && \
            _track_rdeps=0 || _track_rdeps=1
        # shellcheck disable=SC2034
        while IFS=':' read -r pkg version deps opts junk; do
            # If one of the dependencies has a reverse dependency, remove it from
            # the uninstall order if any of those reverse dependencies are not
            # already in the uninstall order. We only want to remove packages with no 
            # external reverse dependencies
            if string_is_in_list "$_leaf_name" "$deps" || \
                string_is_in_list "$_leaf_name" "$opts"; then
                log_debug "Checking if $pkg is in $_uninstall_order"
                case "$_uninstall_order" in
                    *"$pkg|"*|*" $pkg|"*) continue ;;
                    *)
                        [ "$_track_rdeps" = 0 ] && _reverse_deps="$_reverse_deps $pkg"
                        log_debug "Removing from uninstall order: $leaf"
                        _uninstall_order="$(remove_string_from_list "$leaf" "$_uninstall_order")"
                        break
                        ;;
                esac
            fi
        done < "$WORLD"

        # The aforementioned helpful error message
        [ -n "$_reverse_deps" ] && \
            log_error "Cannot remove $leaf: Needed by:$_reverse_deps"
    done

    log_debug "Uninstall order is: $_uninstall_order"
    trim_string_and_return "$_uninstall_order"
)

backend_unactivate_package() (
    _pkg="$1"

    backend_is_installed "$_pkg" || log_error "Package not installed: $_pkg"

    _package_metadata_dir="${INSTALL_ROOT:-}/$METADATA_DIR/$_pkg"

    # shellcheck disable=SC2329
    remove_file() {
        _full_path="${INSTALL_ROOT:-}/$1"
        if [ -f "$_full_path" ] || [ -L "$_full_path" ]; then
            log_debug "Removing file: $_full_path"
            rm "$_full_path" || log_warn "Failed to remove: $_full_path"
        fi
    }

    # shellcheck disable=SC2329
    remove_dir() {
        _full_path="${INSTALL_ROOT:-}/$1"
        if [ -d "$_full_path" ]; then
            if rmdir "${_full_path:?}" 2>/dev/null; then
                log_debug "Removed empty directory: $_full_path"
            else
                log_debug "Failed to remove directory: $_full_path"
                true
            fi
        fi
    }
    export -f log_debug log_warn remove_file remove_dir
    export INSTALL_ROOT

    # We need to remove individual files first, and then do a second pass
    # to remove empty directories to avoid race conditions. Despite having
    # to run twice, it is indeed faster than doing it synchronously
    xargs -a "$_package_metadata_dir/PKGFILES" -P "$(nproc)" {} bash -c 'remove_file "$@"' _ {}
    xargs -a "$_package_metadata_dir/PKGFILES" -P "$(nproc)" {} bash -c 'remove_dir "$@"' _ {}

    awk -F: -v pkg="$_pkg_name" '
        BEGIN{OFS=":"} $1==pkg {$7="deactivated"} 1
    ' "$WORLD" > "${WORLD}.tmp"
    mv "${WORLD}.tmp" "$WORLD"
)

backend_remove_files() (
    _pkg="$1"
    _pkg_install_dir="${INSTALL_ROOT:-}/${PKGDIR:?}/packages/${_pkg:?}"
    [ -d "$_pkg_install_dir" ] && rm -rf "${_pkg_install_dir:?}"
    return 0
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

