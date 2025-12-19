#!/bin/sh

# This file serves as both an extension management extension
# and also as a reference implementation for your own extensions

# shellcheck source=./backend.sh
# shellcheck source=./stdlib.sh
# shellcheck source=../pscl

ext_mgmt_parse_action() {
    log_debug "Parsing arguments in extension: Extension Management"
    INSTALL_EXTENSION=0
    UNINSTALL_EXTENSION=0
    LIST_EXTENSION=false

    _flag="$1"
    shift
    case "$_flag" in
        -E*)
            readonly ACTION="extension"
            _flag="${_flag#-E}"
            while [ -n "$_flag" ]; do
                _char="${_flag%"${_flag#?}"}"
                _flag="${_flag#?}"
                case "$_char" in
                    i) readonly INSTALL_EXTENSION=1 ;;
                    u) readonly UNINSTALL_EXTENSION=1 ;;
                    v) readonly VERBOSE=1 ;;
                    *) log_error "Invalid option for -E: -$_char" ;;
                esac
            done
            readonly ARGUMENTS="$*"
            ;;

        *) return 1 ;;
    esac
}

ext_mgmt_parse_flag() {
    _action="$1"
    _char="$2"

    log_debug "Parsing flag: action=[$_action] char=[$_char]"

    case "$_action" in
        Q)
            case "$_char" in
                e) readonly LIST_EXTENSION=true ;;
                *) return 1 ;;
            esac
            ;;

        *) return 1 ;;
    esac
}

ext_mgmt_augment_main() {
    case "${ACTION:-}" in
        extension) extension_main_extension "$ARGUMENTS" ;;
        *) return 1 ;;
    esac
}

extension_main_extension() (
    _requested_extensions="$*"

    [ -z "$ARGUMENTS" ] && \
        log_error "Arguments expected for -E but none were given"

    if [ "$INSTALL_EXTENSION" = 1 ] && [ "$UNINSTALL_EXTENSION" = 1 ]; then
        log_error "-Ei and -Eu cannot both be set"
    fi

    if [ "$INSTALL_EXTENSION" = 1 ]; then
        extension_install_extension "$_requested_extensions" || \
            log_error "Failed to install extensions: $_requested_extensions"
    elif [ "$UNINSTALL_EXTENSION" = 1 ]; then
        extension_uninstall_extension "$_requested_extensions" || \
            log_error "Failed to uninstall extensions: $_requested_extensions"
    fi
)

extension_install_extension() (
    _extension="$*"
    for extension in $_extension; do
        _ext="$(realpath "$extension")"
        _ext_name="${_ext##*/}"
        _install_path="${EXTENSION_DIR:?}/$_ext_name"

        # It needs to be a file with the .sh extension
        if [ ! -f "$_ext" ] || [ "$_ext" = "${_ext##*.sh}" ]; then
            log_warn "$_ext_name is not an extension. Skipping."
            continue
        elif [ -f "$_install_path" ]; then
            log_warn "$_ext_name is already installed. Skipping."
            continue 
        fi

        if (
            cp -a "$_ext" "$_install_path" || \
                log_error "Failed to copy extension to extensions directory"

            . "$_install_path" || \
                log_error "Failed to source: $_install_path"

            if command -v extension_post_install 2>/dev/null; then
                extension_post_install || \
                    log_error "Failed to execute post-install commands for $_ext_name"
            fi
        )
        then
            printf "%b[SUCCESS]%b: Successfully installed extension: %s\n" \
                "$green" "$def" "$_ext_name"
        else
            log_warn "Failed to install extension: $_ext_name"
        fi
    done
)

extension_uninstall_extension() (
    _extension="$*"
    for extension in $_extension; do
        _ext="$(realpath "$extension")"
        _ext_name="${_ext##*/}"
        _install_path="${EXTENSION_DIR:?}/$_ext_name"

        case "$_ext_name" in
            stdlib.sh|backend.sh)
                log_error "Refusing to remove $_ext_name"
        esac

        if [ ! -f "$_ext" ]; then
            log_warn "$_ext_name is not an extension. Skipping."
            continue
        elif [ ! -f "$_install_path" ]; then
            log_warn "$_ext_name is not installed. Skipping."
            continue 
        fi

        if (
            . "$_install_path" || \
                log_error "Failed to source: $_install_path"

            if command -v extension_post_uninstall 2>/dev/null; then
                extension_post_uninstall || \
                    log_error "Failed to execute post-uninstall cmds for $_ext_name"
            fi

            rm "$_install_path" || \
                log_error "Failed to copy extension to extensions directory"
        ) 
        then
            printf "%b[SUCCESS]%b: Successfully uninstalled extension: %s\n" \
                "$green" "$def" "$_ext_name"
        else
            log_warn "Failed to install extension: $_ext_name"
        fi
    done
)

extension_query_extensions() (
    if "${LIST_EXTENSION:-false}"; then
        ls "${EXTENSION_DIR:?}"
    fi
)

register_hook "pre_query" extension_query_extensions 
register_hook "action" ext_mgmt_parse_action 
register_hook "flag" ext_mgmt_parse_flag
register_hook "main" ext_mgmt_augment_main
