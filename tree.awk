BEGIN { FS = "|" }
{
    lines[NR] = $1
    depths[NR] = $2
    types[NR] = $3
    connectors[NR] = ""
}
END {
    # For all lines, take its depth. Look at all the lines below it and add "├── "
    # to the ones with the same depth. Prefix "└── " to the very last line with the same 
    # depth and prefix "└── " to last line with the same depth
    for (i=1; i<=NR; i++) {
        delete selected_line_nums
        final_line_num = ""

        for (j=i+1; j<=NR; j++) {
            if (depths[j] == depths[i] + 1) {
                final_line_num=j
                selected_line_nums[length(selected_line_nums) + 1] = j
            } else if (depths[j] <= depths[i]) {
                break
            }
        }

        for (k=1; k<=length(selected_line_nums); k++) {
            num = selected_line_nums[k]
            connectors[num] = "├── "
        }

        if (final_line_num != "") {
            selected_line_nums[final_line_num] = ""
            connectors[final_line_num] = "└── "
        }
    }

    # Find the max depth
    target_depth = 0
    for (i=1; i<=length(depths); i++) {
        if (depths[i] > target_depth) target_depth = depths[i]
    }
    target_depth = target_depth - 1

    for (i=target_depth; i>0; i--) {
        for (j=i+1; j<=NR; j++) {
            if (depths[j] != target_depth) continue

            if (connectors[j] == "├── ") {
                for (k=j+1; k<=NR; k++) {
                    if (depths[k] == target_depth) {
                        for (n=j+1; n<k; n++) {
                            if (depths[n] == target_depth + 1) connectors[n] = "│   " connectors[n]
                        }
                        # Stop processing additional lines to avoid duplicating "│   "
                        break
                    }
                }
            }

            if (connectors[j] == "└── " && depths[j+1] > target_depth) {
                for (k=j+1; k<=NR; k++) {
                    if (depths[k] > target_depth) {
                        connectors[k] = "    " connectors[k]
                    }
                }
            }
        }
        target_depth = target_depth - 1
    }


    for (j = 1; j <= NR; j++) {
        printf "%s%s|%s\n", connectors[j], lines[j], depths[j]
    }
}
