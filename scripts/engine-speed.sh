#!/bin/sh
# Usage: scripts/engine-speed.sh [-d depth] [-r rounds] <name>=<chessmirror-cli>[,<flag>...] ...
#
# How fast two (or more) engine builds search, compared the one way every engine ticket compares
# them (chessmirror#4, #13): one search thread from the start position to a fixed depth, under
# `nice -n 19` so the rest of the machine is not the thing measured, the builds run interleaved
# round by round so a load that comes and goes falls on all of them alike. Each run prints its
# nodes, its nps and the load average when it started; the mean (and median) nps per build
# comes at the end, with the fewest core cycles a run took (see below).
#
# A build is a chessmirror-cli binary copied aside after `swift build -c release`, named, with any
# extra flags for `analyse` after commas. To compare a change, both engine builds, before and after:
#
#   swift build -c release --product chessmirror-cli && cp .build/release/chessmirror-cli /tmp/before
#   (make the change, build again)                    && cp .build/release/chessmirror-cli /tmp/after
#   scripts/engine-speed.sh before=/tmp/before before-armv8=/tmp/before,--no-dotprod \
#                           after=/tmp/after   after-armv8=/tmp/after,--no-dotprod
#
# Every build of one engine must print the same node count: a build that searched a different
# tree is a different engine, not a faster one, and the script says so.
set -eu

depth=25
rounds=5
while getopts d:r: opt; do
    case $opt in
        d) depth=$OPTARG ;;
        r) rounds=$OPTARG ;;
        *) sed -n '2p' "$0" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { sed -n '2p' "$0" >&2; exit 2; }

# The nets are found next to the source the binary was built from; a copy moved aside still
# finds them there, and CHESSMIRROR_NETS says otherwise.
: "${CHESSMIRROR_NETS:=$(cd "$(dirname "$0")/.." && pwd)/Resources/Nets}"
export CHESSMIRROR_NETS
start='rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'

results=$(mktemp)
counters=$(mktemp)
trap 'rm -f "$results" "$counters"' EXIT

round=1
while [ "$round" -le "$rounds" ]; do
    for spec in "$@"; do
        name=${spec%%=*}
        rest=${spec#*=}
        binary=${rest%%,*}
        flags=$(printf '%s' "$rest" | awk -F, '{ for (i = 2; i <= NF; i++) printf "%s ", $i }')
        [ -x "$binary" ] || { echo "engine-speed: $binary is not an executable" >&2; exit 1; }
        load=$(sysctl -n vm.loadavg | awk '{ print $2 }')
        # shellcheck disable=SC2086 # the flags are words
        out=$(nice -n 19 /usr/bin/time -l "$binary" analyse "$start" "$depth" --threads 1 --multipv 1 \
            $flags 2> "$counters")
        # The core cycles the whole run took (the nets' load included, the same for every build):
        # time spent waiting for a core is not in them, so they hold still under a load that
        # scatters nps.
        mcycles=$(awk '$2 == "cycles" { printf "%.0f", $1 / 1e6 }' "$counters")
        build=$(printf '%s\n' "$out" | sed -n 's/^build //p')
        last=$(printf '%s\n' "$out" | grep '^depth ' | tail -n 1)
        nodes=$(printf '%s\n' "$last" | awk '{ for (i = 1; i < NF; i++) if ($(i + 1) == "nodes") print $i }')
        nps=$(printf '%s\n' "$last" | awk '{ for (i = 1; i < NF; i++) if ($(i + 1) == "nps") { sub(/k$/, "", $i); print $i } }')
        printf 'round %d  %-16s %-8s load %5s  %s nodes  %sk nps  %s Mcycles\n' \
            "$round" "$name" "$build" "$load" "$nodes" "$nps" "$mcycles"
        printf '%s %s %s %s\n' "$name" "$nodes" "$nps" "$mcycles" >> "$results"
    done
    round=$((round + 1))
done

echo
# The mean is what the protocol compares. The median beside it, because on a shared machine a
# run that another job starved of its core reads a third of the others, and one such run moves a
# mean by more than a compiler flag does: a mean and a median that disagree say so. And the
# fewest cycles any run took, which a starved run cannot move at all.
echo "over $rounds rounds, depth $depth, 1 thread:"
for spec in "$@"; do
    name=${spec%%=*}
    awk -v n="$name" '$1 == n { v[++c] = $3; s += $3; nodes[$2] = 1; if (!m || $4 < m) m = $4 }
        END {
            for (i = 2; i <= c; i++) for (j = i; j > 1 && v[j - 1] > v[j]; j--) { t = v[j]; v[j] = v[j - 1]; v[j - 1] = t }
            median = (c % 2) ? v[(c + 1) / 2] : (v[c / 2] + v[c / 2 + 1]) / 2
            k = 0; for (x in nodes) k++
            printf "  %-16s mean %5.0fk nps  median %5.0fk nps  fewest %6d Mcycles%s\n", n, s / c, median, m,
                (k > 1 ? "  (node count varied between runs!)" : "")
        }' "$results"
done
