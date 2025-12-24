#!/bin/sh

draw_menu() (
    _tree="$1"
    _line_num="$2"
    tput sc >&2
    tput ed >&2
    
    # Draw menu
    i=0
    echo "$_tree" | while IFS='|' read -r item depth dep_type status; do
        if [ "$status" = "unselected" ]; then
            _prefix="[-]"
        else
            _prefix="[\x1b[32m\x1b[39m]"
        fi

        if [ "$i" -eq "$_line_num" ]; then
            tput rev >&2
            printf "%b" "$_prefix" >&2
            tput sgr0 >&2
            printf " %s" "$item" >&2
        else
            printf "%b %s" "$_prefix" "$item" >&2
        fi
        printf "\r\n" >&2
        i=$((i + 1))
    done
    printf "\r\n" >&2
    printf "Use arrow keys to navigate, Enter to select, q to quit\r\n" >&2
    
    # Restore cursor position
    tput rc >&2
)

interactive_prompt() (
    log_debug "Gotten to new confirmation"
    _prompt="$1"
    items="$2"
    line_num=0

    items="$(printf '%s\n' "$items" | tr ' ' '\n')"
    tree="$(echo "$items" | awk -f ./tree.awk)"
    total=$(echo "$items" | wc -l)

    # Print initial prompt
    printf "%s\r\n" "$_prompt" >&2

    old_stty=$(stty -g)
    trap 'stty "$old_stty"
    tput ed >&2
    tput cnorm >&2
    printf "\r" >&2
    exit' INT TERM EXIT

    tput civis >&2
    stty raw -echo >&2

    draw_menu "$tree" "$line_num"
    while true; do
        char=$(dd bs=1 count=1 2>/dev/null)

        if [ "$char" = "$(printf '\033')" ]; then
            char=$(dd bs=1 count=1 2>/dev/null)
            char=$(dd bs=1 count=1 2>/dev/null)

            case "$char" in
                A) line_num=$((line_num - 1))
                    [ "$line_num" -lt 0 ] && line_num=$((total - 1))
                    draw_menu "$tree" "$line_num" ;;
                B) line_num=$((line_num + 1))
                    [ "$line_num" -ge "$total" ] && line_num=0
                    draw_menu "$tree" "$line_num" ;;
            esac
        else
            case "$char" in
                q|Q) return 1 ;;
                "$(printf '\r')") break ;;
                "$(printf ' ')")
                    tree="$(echo "$tree" | awk -F'|' -v OFS="|" -v line="$(("$line_num" + 1))" '
                        NR == line {
                            if ($4 == "unselected") {
                                $4 = "selected"
                            } else {
                                $4 = "unselected"
                            }
                        }
                        {print}
                        ')"
                    draw_menu "$tree" "$line_num" ;;
            esac
        fi
    done

    # Clear the menu and reset everything
    stty "$old_stty" >&2
    tput ed >&2
    tput cnorm >&2

    # Return all selected packages
    while read -r line; do
        content="${line##* }"

        if [ "$(get_field "$content" 4)" = "unselected" ]; then continue; fi
        _return_string="${_return_string:-} $(get_field "$content" 1)"
    done <<- EOF
        $tree
	EOF

    trim_string_and_return "$_return_string"
)

backend_ask_confirmation() (
    _prompt="$1"
    shift
    _package_struct_list="$*"

    # The install/build order starts with deepest dependencies in the tree first
    # The interactive prompt expects the shallowest deps in the tree to be first
    # So we need to reverse the input and then reverse the prompt's output
    case "$_prompt" in
        install)
            _package_struct_list="$(reverse_string "$_package_struct_list")"
            _package_list="$(interactive_prompt "Select packages to install:" "$_package_struct_list")"
            _package_list="$(reverse_string "$_package_list")"
            ;;
        build)
            _package_struct_list="$(reverse_string "$_package_struct_list")"
            _package_list="$(interactive_prompt "Select packages to build:" "$_package_struct_list")"
            _package_list="$(reverse_string "$_package_list")"
            ;;
        uninstall)
            _package_struct_list="$(reverse_string "$_package_struct_list")"
            _package_list="$(interactive_prompt "Select packages to build:" "$_package_struct_list")"
            _package_list="$(reverse_string "$_package_list")"
            ;;
    esac

    echo "$_package_list"
)
