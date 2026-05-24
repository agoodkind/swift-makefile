function key_for(input_line,    output_line) {
    output_line = input_line
    while (index(output_line, "../") == 1) {
        output_line = substr(output_line, 4)
    }
    if (match(output_line, /:[0-9]+:[0-9]+:/)) {
        output_line = substr(output_line, 1, RSTART - 1) ":::" substr(output_line, RSTART + RLENGTH)
    }
    return output_line
}

function first_added_from(metadata_text,    field_count, fields, field_index) {
    field_count = split(metadata_text, fields, " ")
    for (field_index = 1; field_index <= field_count; field_index++) {
        if (fields[field_index] ~ /^first_added=/) {
            return substr(fields[field_index], 13)
        }
    }
    return ""
}

function remember_current(input_line,    current_key) {
    if (input_line ~ /^[ \t]*$/ || input_line ~ /^#/) {
        return
    }
    current_key = key_for(input_line)
    if (!(current_key in current_finding)) {
        current_order[++current_count] = current_key
    }
    current_finding[current_key] = input_line
}

function remember_old(input_line,    old_key, marker_index, finding, metadata_text) {
    if (input_line ~ /^[ \t]*$/ || input_line ~ /^#/) {
        return
    }
    marker_index = index(input_line, metadata_prefix)
    if (marker_index > 0) {
        finding = substr(input_line, 1, marker_index - 1)
        metadata_text = substr(input_line, marker_index + length(metadata_prefix))
    } else {
        finding = input_line
        metadata_text = ""
    }
    if (finding == "") {
        return
    }
    old_key = key_for(finding)
    if (!(old_key in old_finding)) {
        old_order[++old_count] = old_key
    }
    old_finding[old_key] = finding
    old_line[old_key] = input_line
    old_first_added[old_key] = first_added_from(metadata_text)
}

function print_current(current_key,    first_added) {
    first_added = old_first_added[current_key]
    if (first_added == "") {
        first_added = now
    }
    printf "%s\t# %s:first_added=%s last_seen=%s\n", current_finding[current_key], label, first_added, now
}

BEGIN {
    metadata_prefix = "\t# " label ":"
    while ((getline current_line < current_file) > 0) {
        remember_current(current_line)
    }
    close(current_file)
}

{
    remember_old($0)
}

END {
    if (mode == "sync") {
        for (current_index = 1; current_index <= current_count; current_index++) {
            print_current(current_order[current_index])
        }
    } else if (mode == "prune-fixed" || mode == "remove-fixed") {
        for (current_index = 1; current_index <= current_count; current_index++) {
            if (current_order[current_index] in old_finding) {
                print_current(current_order[current_index])
            }
        }
    } else if (mode == "accept-new") {
        for (current_index = 1; current_index <= current_count; current_index++) {
            print_current(current_order[current_index])
        }
        for (old_index = 1; old_index <= old_count; old_index++) {
            if (!(old_order[old_index] in current_finding)) {
                print old_line[old_order[old_index]]
            }
        }
    } else {
        print "unknown baseline update mode: " mode
        exit 1
    }
}
