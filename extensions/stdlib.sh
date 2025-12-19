#!/bin/sh

trim_string_and_return() (
    set -f
    set -- $*
    var="$(printf '%s\n' "$*")"
    echo "$var"
)

string_is_in_list() (
    _string="$1"
    shift
    _list=" ${*:-} "

    case $_list in
        *" $_string "*) return 0 ;;
    esac
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

    trim_string_and_return "$_result"
)

list_of_dependencies() (
    for build in $1; do
        _pkg_build="$(backend_get_package_build "$build")" || \
            log_error "Failed to get build script: $build"

        # shellcheck source=/dev/null
        . "$_pkg_build" || log_error "Failed to source: $_pkg_build"
        string="${string:-} ${package_dependencies:-}"
    done
    trim_string_and_return "$string"
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

        if backend_is_installed "$_current" && [ "$INSTALL_FORCE" = 0 ]; then
            _resolved="$_resolved$_current "
            log_debug "$_current is already installed. Skipping adding it to the tree"
        fi

        # Skip if already resolved
        case $_resolved in
            *" $_current "*) continue ;;
        esac

        _deps=$(list_of_dependencies "$_current") || {
            log_error "Failed to get dependencies for: $_current"
        }

        log_debug "Dependencies for $_current are: $_deps"

        # Check if all dependencies are resolved
        _all_resolved=1
        _unresolved_deps=""

        for dep in $_deps; do
            case $_resolved in
                *" $dep "*) ;;
                *)
                    _all_resolved=0
                    _unresolved_deps="$_unresolved_deps $dep" ;;
            esac
        done

        if [ "$_all_resolved" -eq 0 ]; then
            # Check for circular dependency only when we need to re-queue
            case $_processing in
                *" $_current "*)
                    log_error "Circular dependency detected involving: $_current" ;;
            esac

            # Mark as processing and re-queue after dependencies
            _processing="$_processing$_current "
            _queue="$_unresolved_deps $_current $_queue"
        else
            # All dependencies resolved, add to order
            _resolved="$_resolved$_current "
            _order="$_order $_current"

            # Remove from processing since it's now resolved
            _processing=$(echo "$_processing" | sed "s| $_current | |")

            log_debug "Adding $_current to dependency graph"
        fi
    done

    log_debug "Dependency tree is: $_order"
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

    for hook in $_hooks; do
        log_debug "Running hook: $hook"
        "$hook" "$@" || return 1
    done

    return 0
}
