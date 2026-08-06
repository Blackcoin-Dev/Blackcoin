# Render a candidate Compose file while changing only the image scalar for an
# explicit comma-separated set of nodeNN services. The caller must compare the
# rendered Compose model as an additional semantic gate.

BEGIN {
    n = split(targets, requested, ",")
    if (n < 1 || image !~ /^[A-Za-z0-9._\/-]+@sha256:[0-9a-f]+$/) exit 64
    for (i = 1; i <= n; i++) {
        if (requested[i] !~ /^node(0[1-9]|[12][0-9]|3[0-2])$/ || (requested[i] in wanted)) exit 64
        wanted[requested[i]] = 1
    }
    current = ""
    in_services = 0
}

/^services:[[:space:]]*$/ {
    in_services = 1
    print
    next
}

in_services && /^  node(0[1-9]|[12][0-9]|3[0-2]):[[:space:]]*$/ {
    current = $1
    sub(/:$/, "", current)
    seen_service[current]++
    print
    next
}

in_services && /^[^[:space:]]/ && $0 !~ /^services:[[:space:]]*$/ {
    current = ""
    in_services = 0
}

in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ && $0 !~ /^  node(0[1-9]|[12][0-9]|3[0-2]):/ {
    current = ""
}

current != "" && (current in wanted) && /^    image:[[:space:]]*[^[:space:]].*$/ {
    changed[current]++
    print "    image: " image
    next
}

{ print }

END {
    if (n < 1) exit 64
    for (service in wanted) {
        if (seen_service[service] != 1 || changed[service] != 1) {
            print "render cardinality failure service=" service \
                " seen=" (seen_service[service] + 0) \
                " changed=" (changed[service] + 0) > "/dev/stderr"
            failed = 1
        }
    }
    if (failed) exit 65
}
