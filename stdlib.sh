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
        _pkg_build="./repositories/main/$build/${build}.build"

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
        
        # Skip if already resolved
        case $_resolved in
            *" $_current "*) continue ;;
        esac

        backend_is_installed "$_current" && continue
        
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
    
    trim_string_and_return "$_order"
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
