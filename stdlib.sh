#!/bin/sh

trim_string_and_return() {
    set -f
    set -- $*
    echo "$*"
}

string_is_in_list() {
    _string="$1"
    shift
    _list=" ${*:-} "

    case $_list in
        *" $_string "*) return 0 ;;
    esac
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

    trim_string_and_return "$_result"
}

reverse_string() {
    _reversed=""
    for word in $1; do
        _reversed="$word $_reversed"
    done
    set -- $_reversed
    echo "$*"
}

list_of_dependencies_og() (
    for build in $1; do
        _pkg_build="$(backend_get_package_build "$build")" || \
            log_error "Failed to get build script: $build"

        # shellcheck source=/dev/null
        . "$_pkg_build" || log_error "Failed to source: $_pkg_build"
        string="${string:-} ${pkg_deps:-}"
        "$OPT_DEPS" && string="${string:-} ${opt_deps:-}"
        "$CHECK_DEPS" && string="${string:-} ${check_deps:-}"
        "$BUILD_DEPS" && string="${string:-} ${build_deps:-}"
    done
    trim_string_and_return "$string"
)

# Takes in a list of package structs and returns a list of structs
# that are dependencies of the input packages
list_of_dependencies() (
    for _pkg in $1; do
        IFS='|' read -r _pkg_name _pkg_depth _pkg_type <<- EOF
            $_pkg
		EOF

        _pkg_build="$(backend_get_package_build "$_pkg_name")" || \
            log_error "Failed to get build script: $_pkg_name"

        # Add one to the current package depth
        _dep_depth="$((_pkg_depth + 1))"

        # shellcheck source=/dev/null
        . "$_pkg_build" || log_error "Failed to source: $_pkg_build"

        # Dependencies of build dependencies are also build dependencies
        for dep in $pkg_deps; do
            if [ "$_pkg_type" = "build" ]; then
                _dep_type="build"
            else
                _dep_type="pkg"
            fi
            result="${result:-} ${dep}|${_dep_depth}|${_dep_type}"
        done

        # Process optional, check, and build dependencies if needed
        "$OPT_DEPS" && for dep in $opt_deps; do
            [ -z "$dep" ] && continue 
            result="${result:-} ${dep}|${_dep_depth}|opt"
        done

        "$CHECK_DEPS" && for dep in $check_deps; do
            [ -z "$dep" ] && continue 
            result="${result:-} ${dep}|${_dep_depth}|check"
        done

        "$BUILD_DEPS" && for dep in $build_deps; do
            [ -z "$dep" ] && continue 
            result="${result:-} ${dep}|${_dep_depth}|build"
        done
    done

    trim_string_and_return "$result"
)

edit_field() (
    _struct="$1"
    _field="$2"
    _replacement="$3"

    IFS='|'
    i=1
    for field in $_struct; do
        if [ "$i" = "$_field" ]; then
            _return_string="${_return_string:-}|$_replacement"
        else
            _return_string="${_return_string:-}|$field"
        fi
        i="$((i + 1))"
    done

    echo "${_return_string#|}"
)

get_field() (
    _struct_list="$1"
    _field="$2"
    _return_string=""

    for struct in $_struct_list; do
        IFS='|'
        # shellcheck disable=SC2086
        set -- $struct
        eval "_value=\$$_field"
        # shellcheck disable=SC2154
        _return_string="$_return_string $_value"
    done

    echo "${_return_string# }"
)

get_dependency_tree() (
    _initial_packages="$*"
    # Spaces for easier pattern matching
    _order=""
    _resolved=" "
    _processing=" "

    _queue="$_initial_packages"

    while [ -n "$_queue" ]; do
        _current=$(echo "$_queue" | awk '{print $1}')
        _queue=$(echo "$_queue" | sed 's/^[^ ]* *//')

        _current_name=$(get_field "$_current" 1)

        if backend_is_installed "$_current" && [ "$INSTALL_FORCE" = 0 ]; then
            _resolved="$_resolved$_current_name "
            log_debug "$_current is already installed. Skipping adding it to the tree"
            continue
        fi

        # Skip if already resolved
        case $_resolved in
            *" $_current_name "*) continue ;;
        esac

        # Now we resolve
        if [ -f "${INSTALL_ROOT:-}/${PKGDIR:?}/installed_packages/$_current_name.tar.zst" ]
        then
            _deps=$(BUILD_DEPS=false list_of_dependencies "$_current") || \
                log_error "Failed to get dependencies for: $_current"
        else
            _deps=$(list_of_dependencies "$_current") || \
                log_error "Failed to get dependencies for: $_current"
        fi
        log_debug "Dependencies for $_current are: $_deps"

        # Check if all dependencies are resolved
        _all_resolved=1
        _unresolved_deps=""

        for dep_struct in $_deps; do
            dep_name=$(get_field "$dep_struct" 1)
            case $_resolved in
                *" $dep_name "*) ;;
                *)
                    _all_resolved=0
                    _unresolved_deps="$_unresolved_deps $dep_struct"
                    ;;
            esac
        done

        if [ "$_all_resolved" -eq 0 ]; then
            # Check for circular dependency only when we need to re-queue
            case $_processing in
                *" $_current_name "*)
                    log_error "Circular dependency detected involving: $_current_name" ;;
            esac

            # Mark as processing and re-queue after dependencies
            _processing="$_processing$_current_name "
            _queue="$_unresolved_deps $_current $_queue"
        else
            # All dependencies resolved, add to order
            _resolved="$_resolved$_current_name "
            _order="$_order $_current"

            # Remove from processing since it's now resolved
            _processing=$(echo "$_processing" | sed "s# $_current_name # #")

            log_debug "Adding $_current to dependency graph"
        fi
    done

    log_debug "Dependency tree is: $_order"

    # Return structs (or just package names if you prefer)
    trim_string_and_return "$_order"
)

register_hook() {
    _hook_point="$1"
    _hook_func="$2"

    case "$_hook_point" in
        pre_install)     HOOK_PRE_INSTALL="${HOOK_PRE_INSTALL:-} $_hook_func" ;;
        post_install)    HOOK_POST_INSTALL="${HOOK_POST_INSTALL:-} $_hook_func" ;;
        pre_build)       HOOK_PRE_BUILD="${HOOK_PRE_BUILD:-} $_hook_func" ;;
        post_build)      HOOK_POST_BUILD="${HOOK_POST_BUILD:-} $_hook_func" ;;
        pre_uninstall)   HOOK_PRE_UNINSTALL="${HOOK_PRE_UNINSTALL:-} $_hook_func" ;;
        post_uninstall)  HOOK_POST_UNINSTALL="${HOOK_POST_UNINSTALL:-} $_hook_func" ;;
        pre_query)       HOOK_PRE_QUERY="${HOOK_PRE_QUERY:-} $_hook_func" ;;
        prost_query)     HOOK_POST_QUERY="${HOOK_POST_QUERY:-} $_hook_func" ;;
        pre_activation)  HOOK_PRE_ACTIVATION="${HOOK_PRE_ACTIVATION:-} $_hook_func" ;;
        post_activation) HOOK_POST_ACTIVATION="${HOOK_POST_ACTIVATION:-} $_hook_func" ;;
        action)          HOOK_ACTION="${HOOK_ACTION:-} $_hook_func" ;;
        flag)            HOOK_FLAG="${HOOK_FLAG:-} $_hook_func" ;;
        main)            HOOK_MAIN="${HOOK_MAIN:-} $_hook_func" ;;
        *) log_error "Unknown hook point: $_hook_point" ;;
    esac
}

run_hooks() {
    _hook_point="$1"
    shift

    case "$_hook_point" in
        pre_install)     _hooks="$HOOK_PRE_INSTALL" ;;
        post_install)    _hooks="$HOOK_POST_INSTALL" ;;
        pre_build)       _hooks="$HOOK_PRE_BUILD" ;;
        post_build)      _hooks="$HOOK_POST_BUILD" ;;
        pre_uninstall)   _hooks="$HOOK_PRE_UNINSTALL" ;;
        post_uninstall)  _hooks="$HOOK_POST_UNINSTALL" ;;
        pre_query)       _hooks="$HOOK_PRE_QUERY" ;;
        post_query)      _hooks="$HOOK_POST_QUERY" ;;
        pre_activation)  _hooks="$HOOK_PRE_ACTIVATION" ;;
        post_activation) _hooks="$HOOK_POST_ACTIVATION" ;;
        action)          _hooks="$HOOK_ACTION" ;;
        flag)            _hooks="$HOOK_FLAG" ;;
        main)            _hooks="$HOOK_MAIN" ;;
        *) return 0 ;;
    esac

    log_debug "Hooks to run: [$_hooks]"

    case "$_hook_point" in
        action|flag|main)
            for hook in $_hooks; do
                log_debug "Running hook: $hook"
                if "$hook" "$@"; then
                    log_debug "Hook $hook handled this $_hook_point"
                    return 0
                fi
                log_debug "Hook $hook did not handle this $_hook_point. Trying next"
            done
            # No hook handled it - return failure
            log_debug "No hook handled the request"
            return 1
            ;;

        *)
            # For other hooks, run all and fail if any fail
            for hook in $_hooks; do
                log_debug "Running hook: $hook"
                "$hook" "$@" || return 1
            done
            return 0
            ;;
    esac
}
