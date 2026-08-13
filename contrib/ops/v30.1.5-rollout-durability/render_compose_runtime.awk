# Generate a Compose overlay. Invocation must provide immutable image_ref,
# role=(regular|free_claim), a space-separated nodes list, and the sealed
# logical-node topology map with -v.
BEGIN {
    if (image_ref !~ /^[A-Za-z0-9._\/-]+@sha256:[0-9a-f]{64}$/) exit 65
    if (role != "regular" && role != "free_claim") exit 65
    if (topology_file == "") exit 65
    topology_rows = 0
    while ((topology_status = (getline topology_line < topology_file)) > 0) {
        if (topology_line == "" || topology_line ~ /^#/) continue
        if (topology_line !~ /^[1-9][0-9]* [A-Za-z0-9][A-Za-z0-9_.-]* [A-Za-z0-9][A-Za-z0-9_.-]*$/)
            exit 65
        split(topology_line, topology_fields, " ")
        logical = topology_fields[1] + 0
        if (logical < 1 || logical > 32 || sprintf("%d", logical) != topology_fields[1] ||
            topology_node_seen[logical]++ || topology_service_seen[topology_fields[2]]++ ||
            topology_container_seen[topology_fields[3]]++) exit 65
        compose_service[logical] = topology_fields[2]
        container_name[logical] = topology_fields[3]
        topology_rows++
    }
    close(topology_file)
    if (topology_status < 0 || topology_rows != 32) exit 65
    for (logical = 1; logical <= 32; logical++)
        if (!(logical in compose_service) || !(logical in container_name)) exit 65
    count = split(nodes, raw, /[[:space:]]+/)
    if (count < 1 || count > 4) exit 65
    print "services:"
    for (i = 1; i <= count; i++) {
        node = raw[i] + 0
        if (raw[i] !~ /^[0-9]+$/ || node < 1 || node > 32 || seen[node]++) exit 65
        print "  " compose_service[node] ":"
        print "    image: " image_ref
        print "    entrypoint:"
        print "      - /bin/bash"
        print "      - -c"
        print "      - |"
        print "          export DISPLAY=:0"
        print "          rm -f /tmp/.X0-lock"
        print "          Xvfb :0 -screen 0 1280x800x16 &"
        print "          sleep 2"
        print "          fluxbox &"
        print "          x11vnc -display :0 -nopw -listen localhost -xkb -forever -shared &"
        print "          websockify --web=/usr/share/novnc/ 8080 localhost:5900 &"
        print "          sleep 2"
        print "          exec /usr/local/bin/blackcoin-qt -datadir=/home/blackcoin/.blackcoin \"$$@\""
        print "      - node" node "-v3015-rollout"
        print "    command:"
        print "      - -walletbroadcast=1"
        print "      - -autostartstaking=1"
        if (role == "regular") {
            print "      - -powmining=1"
            print "      - -powminingthreads=1"
            print "      - -powminingcpu=1"
        } else {
            print "      - -powmining=0"
        }
    }
}
