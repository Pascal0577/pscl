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

    trim_string_and_return "$_result"
)

list_of_dependencies() (
    _pkg="$(backend_get_package_name "$1")" || \
        log_error "Failed to get package name: $_pkg"
    _pkg_build="$(backend_get_package_build "$_pkg")" || \
        log_error "Failed to get package build: $_pkg"

    # shellcheck source=/dev/null
    . "$_pkg_build" || log_error "Failed to source: $_pkg_build"

    # package_dependencies is a variable defined in the package's build script
    trim_string_and_return "${package_dependencies:-}"
)

get_dependency_tree() (
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
        [ "$INSTALL_FORCE" = 0 ] && ( backend_is_installed "$child" ) && continue

        # Get the dependency graph of all the children recursively until there
        # are no more childen. At that point we are in the deepest part of the
        # tree and can append the child to the build order.
        result=$(get_dependency_tree "$child" "$_visiting" "$_resolved" "$_order") || \
            log_error "Failed to get dependency graph for: $child"
        _visiting=$(echo "$result" | cut -d '|' -f1)
        _resolved=$(echo "$result" | cut -d '|' -f2)
        _order=$(echo "$result" | cut -d '|' -f3)
    done

    _visiting=$(remove_string_from_list "$_node" "$_visiting")
    _resolved="$_resolved $_node"
    _order="$_order $_node"
    log_debug "Adding $_node to dependency graph"

    trim_string_and_return "$_visiting|$_resolved|$_order"
)

run_in_parallel() (
    _job_num="$1"
    _data="$2"
    _cmd="$3"

    # shellcheck disable=SC2154
    trap 'for p in $_pids; do kill -- -\$p 2>/dev/null; done; exit 1' INT TERM EXIT

    for singleton in $_data; do
        (
            set -m
            $_cmd "$singleton" || log_error "$_cmd $singleton"
        ) &

        _pids="$_pids $!"
        _job_count=$((_job_count + 1))

        if [ "$_job_count" -ge "$PARALLEL_DOWNLOADS" ]; then
            wait -n 2>/dev/null || wait
            _job_count=$((_job_count - 1))
        fi
    done

    wait
    trap - INT TERM EXIT
)

# Hook system
HOOKS_PRE_INSTALL=""
HOOKS_POST_INSTALL=""
HOOKS_PRE_BUILD=""
HOOKS_POST_BUILD=""
HOOKS_PRE_UNINSTALL=""
HOOKS_POST_UNINSTALL=""

register_hook() {
    _hook_point="$1"
    _hook_func="$2"
    
    case "$_hook_point" in
        pre_install)    HOOKS_PRE_INSTALL="$HOOKS_PRE_INSTALL $_hook_func" ;;
        post_install)   HOOKS_POST_INSTALL="$HOOKS_POST_INSTALL $_hook_func" ;;
        pre_build)      HOOKS_PRE_BUILD="$HOOKS_PRE_BUILD $_hook_func" ;;
        post_build)     HOOKS_POST_BUILD="$HOOKS_POST_BUILD $_hook_func" ;;
        pre_uninstall)  HOOKS_PRE_UNINSTALL="$HOOKS_PRE_UNINSTALL $_hook_func" ;;
        post_uninstall) HOOKS_POST_UNINSTALL="$HOOKS_POST_UNINSTALL $_hook_func" ;;
        *) log_error "Unknown hook point: $_hook_point" ;;
    esac
}

run_hooks() {
    _hook_point="$1"
    shift
    
    case "$_hook_point" in
        pre_install)    _hooks="$HOOKS_PRE_INSTALL" ;;
        post_install)   _hooks="$HOOKS_POST_INSTALL" ;;
        pre_build)      _hooks="$HOOKS_PRE_BUILD" ;;
        post_build)     _hooks="$HOOKS_POST_BUILD" ;;
        pre_uninstall)  _hooks="$HOOKS_PRE_UNINSTALL" ;;
        post_uninstall) _hooks="$HOOKS_POST_UNINSTALL" ;;
        *) return 0 ;;
    esac
    
    for hook in $_hooks; do
        log_debug "Running hook: $hook"
        "$hook" "$@" || return 1
    done
    
    return 0
}
