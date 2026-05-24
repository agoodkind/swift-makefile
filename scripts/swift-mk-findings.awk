function normalize_path(input_line,    output_line) {
    output_line = input_line
    if (pwd != "" && index(output_line, pwd) == 1) {
        output_line = substr(output_line, length(pwd) + 1)
    }
    if (cwd != "" && index(output_line, cwd) == 1) {
        output_line = substr(output_line, length(cwd) + 1)
    }
    while (index(output_line, "../") == 1) {
        output_line = substr(output_line, 4)
    }
    return output_line
}

function key_for(input_line,    output_line) {
    output_line = normalize_path(input_line)
    if (match(output_line, /:[0-9]+:[0-9]+:/)) {
        output_line = substr(output_line, 1, RSTART - 1) ":::" substr(output_line, RSTART + RLENGTH)
    }
    return output_line
}

function baseline_finding(input_line,    marker, finding) {
    if (input_line ~ /^[ \t]*$/ || input_line ~ /^#/) {
        return ""
    }
    marker = "\t# " label ":"
    finding = input_line
    if (index(input_line, marker) > 0) {
        finding = substr(input_line, 1, index(input_line, marker) - 1)
    }
    return normalize_path(finding)
}

function print_finding(input_line,    location, message) {
    input_line = normalize_path(input_line)
    if (match(input_line, /:[0-9]+:[0-9]+:/)) {
        location = substr(input_line, 1, RSTART + RLENGTH - 2)
        message = substr(input_line, RSTART + RLENGTH)
        sub(/^[ \t]+/, "", message)
        printf "  %s\n    %s\n", location, message
    } else {
        printf "  %s\n", input_line
    }
}

function finding_file(input_line,    parts) {
    split(input_line, parts, ":")
    return parts[1]
}

function finding_line(input_line,    parts) {
    split(input_line, parts, ":")
    return parts[2] + 0
}

function remember_range(input_line,    parts, file_path, range_index) {
    split(input_line, parts, "\t")
    file_path = parts[1]
    if (file_path == "") {
        return
    }
    range_index = ++range_count[file_path]
    range_start[file_path, range_index] = parts[2] + 0
    range_end[file_path, range_index] = parts[3] + 0
}

function finding_in_range(input_line,    file_path, line_number, range_index) {
    file_path = finding_file(input_line)
    line_number = finding_line(input_line)
    if (file_path == "" || line_number == 0) {
        return 0
    }
    for (range_index = 1; range_index <= range_count[file_path]; range_index++) {
        if (line_number >= range_start[file_path, range_index] && line_number <= range_end[file_path, range_index]) {
            return 1
        }
    }
    return 0
}

BEGIN {
    if (action == "") {
        action = "normalize"
    }
}

action == "ranges" && /^\+\+\+ / {
    current_file = $2
    sub(/^b\//, "", current_file)
    if (current_file == "/dev/null") {
        current_file = ""
    }
    next
}

action == "ranges" && $1 == "@@" && current_file != "" {
    range_text = $3
    sub(/^\+/, "", range_text)
    split(range_text, range_parts, ",")
    range_start_line = range_parts[1] + 0
    range_line_count = range_parts[2] == "" ? 1 : range_parts[2] + 0
    if (range_line_count > 0) {
        print current_file "\t" range_start_line "\t" range_start_line + range_line_count - 1
    }
    next
}

action == "ranges" {
    next
}

action == "linefilter" && NR == FNR {
    remember_range($0)
    next
}

action == "linefilter" {
    if (finding_in_range($0)) {
        print
    }
    next
}

action == "map" && NR == FNR {
    keyset[$0] = 1
    next
}

action == "map" {
    if (key_for($0) in keyset) {
        print
    }
    next
}

action == "baseline" {
    finding = baseline_finding($0)
    if (finding != "") {
        print finding
    }
    next
}

action == "key" {
    print key_for($0)
    next
}

action == "print" {
    print_finding($0)
    next
}

{
    print normalize_path($0)
}
