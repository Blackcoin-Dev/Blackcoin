# Generate a Compose overlay. Invocation must provide immutable image_ref,
# role=(regular|free_claim), and a space-separated nodes list with -v.
BEGIN {
    if (image_ref !~ /^[A-Za-z0-9._\/-]+@sha256:[0-9a-f]{64}$/) exit 65
    if (role != "regular" && role != "free_claim") exit 65
    count = split(nodes, raw, /[[:space:]]+/)
    if (count < 1 || count > 4) exit 65
    print "services:"
    for (i = 1; i <= count; i++) {
        node = raw[i] + 0
        if (raw[i] !~ /^[0-9]+$/ || node < 1 || node > 32 || seen[node]++) exit 65
        print "  node" node ":"
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
