#!/usr/bin/env bash
#
# Explain a "No valid host was found" server failure on antelope.
#
#   Nova only tells the user "No valid host was found"; the reasons are in the
#   nova-scheduler journal. This prints, for one server:
#     - what it asked for: flavor, extra specs, SR-IOV/PCI requests
#     - the scheduler's filter summary (which filter removed the hosts)
#     - the per-host reasons from the DEBUG lines (CPU pinning, hugepages,
#       PCI devices, Placement having no candidates, ...)
#   Works for deleted servers too, e.g. ones Heat removed after a failed stack.
#
# Run it on the infra host that runs nova-scheduler (voereir11), as root:
#   sudo scripts/voereir/why-no-valid-host.sh <server name or UUID>
#   sudo SINCE="2 weeks ago" scripts/voereir/why-no-valid-host.sh <name>
#
# A name can match several servers (Heat reuses names); the newest is used and
# the others are listed. Pass the UUID to pick a specific one.

set -euo pipefail

SERVER=${1:-}
SINCE=${SINCE:-"7 days ago"}
UNIT=${SCHEDULER_UNIT:-"nova-scheduler"}

if [[ -z "${SERVER}" ]]; then
    sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi
if [[ $(id -u) -ne 0 ]]; then
    echo "Run as root (needs /etc/nova/nova.conf and the ${UNIT} journal)." >&2
    exit 1
fi

NOVA_PYTHON=${NOVA_PYTHON:-$(ls -d /openstack/venvs/nova-*/bin/python 2>/dev/null | sort -V | tail -1)}
if [[ ! -x "${NOVA_PYTHON}" ]]; then
    echo "No Nova venv found under /openstack/venvs; set NOVA_PYTHON." >&2
    exit 1
fi

# Look the server up through Nova's own objects: this needs no Keystone
# credentials and also finds deleted servers in cell0.
info=$("${NOVA_PYTHON}" - "${SERVER}" <<'EOF' 2>/dev/null
import re, sys, uuid
from nova import config, context, objects

config.parse_args(["nova-api", "--config-file", "/etc/nova/nova.conf"])
objects.register_all()
ctxt = context.get_admin_context(read_deleted="yes")
arg = sys.argv[1]

matches = []
for cell in objects.CellMappingList.get_all(ctxt):
    with context.target_cell(ctxt, cell) as cctxt:
        try:
            uuid.UUID(arg)
            filters = {"uuid": arg}
        except ValueError:
            filters = {"display_name": "^%s$" % re.escape(arg)}
        for inst in objects.InstanceList.get_by_filters(
                cctxt, filters, expected_attrs=["flavor", "pci_requests"]):
            matches.append((cell, inst))

if not matches:
    print("ERROR No server named or with UUID %r." % arg)
    sys.exit(0)
matches.sort(key=lambda m: m[1].created_at)
cell, inst = matches[-1]
for c, i in matches[:-1]:
    print("NOTE Older server with this name: %s (created %s, %s)"
          % (i.uuid, i.created_at, i.vm_state))

flavor = inst.flavor
print("Server:   %s (%s)" % (inst.display_name, inst.uuid))
print("Created:  %s   cell: %s   host: %s" % (inst.created_at, cell.name, inst.host))
print("State:    vm_state=%s task_state=%s deleted=%s"
      % (inst.vm_state, inst.task_state, bool(inst.deleted)))
print("Flavor:   %s: %s vCPUs, %s MB RAM, %s GB disk"
      % (flavor.name, flavor.vcpus, flavor.memory_mb, flavor.root_gb))
for key, value in sorted(flavor.extra_specs.items()):
    print("          %s = %s" % (key, value))
for req in inst.pci_requests.requests:
    source = ("port %s" % req.requester_id if req.requester_id
              else "alias %s" % req.alias_name)
    print("PCI:      %d device(s) for %s, spec %s" % (req.count, source, req.spec))

with context.target_cell(ctxt, cell) as cctxt:
    actions = objects.InstanceActionList.get_by_instance_uuid(cctxt, inst.uuid)
for action in actions:
    if action.action == "create":
        print("REQUEST_ID %s" % action.request_id)
print("UUID %s" % inst.uuid)
EOF
)

if grep -q '^ERROR ' <<<"${info}"; then
    sed 's/^ERROR //' <<<"${info}" >&2
    exit 1
fi
if [[ -z "${info}" ]]; then
    echo "Could not read the server from Nova's database." >&2
    exit 1
fi

grep -vE '^(REQUEST_ID|UUID) ' <<<"${info}"
uuid=$(awk '/^UUID /{print $2}' <<<"${info}")
req_id=$(awk '/^REQUEST_ID /{print $2}' <<<"${info}" | tail -1)

# The scheduler logs under the request ID of the API call that created the
# server. Fall back to finding it through the instance UUID.
log=$(journalctl -u "${UNIT}" --since "${SINCE}" --no-pager -o cat 2>/dev/null)
if [[ -z "${req_id}" ]] || ! grep -qF "${req_id}" <<<"${log}"; then
    req_id=$(grep -F "instance ID '${uuid}'" <<<"${log}" | grep -o 'req-[0-9a-f-]\{36\}' | tail -1 || true)
fi
if [[ -z "${req_id}" ]]; then
    echo
    echo "No ${UNIT} log lines for this server since ${SINCE}."
    echo "Try SINCE=\"30 days ago\", or the server never reached the scheduler."
    exit 0
fi
lines=$(grep -F "${req_id}" <<<"${log}" | sed -E 's/^.*default default\] //; s/ [a-z_]+ \/openstack\/venvs\/[^ ]+$//')

echo
echo "Scheduler request: ${req_id}"

echo
echo "== Filter summary"
summary=$(grep -E 'Filtering removed all hosts' <<<"${lines}" \
    | grep -o "Filter results: \['.*" | sort -u || true)
if [[ -n "${summary}" ]]; then
    # One filter per line; the filter that ends at 0 is the one to look at.
    sed -E "s/^Filter results: \[//; s/\]$//; s/', '/'\n'/g; s/'//g" <<<"${summary}" \
        | sed -E 's/^/  /; s/(end: 0\))$/\1   <-- removed the last hosts/'
else
    grep -E 'Filter [A-Za-z]+ returned' <<<"${lines}" | sed 's/^/  /' || echo "  (no filter lines)"
fi

echo
echo "== Placement"
if grep -qiE 'no allocation candidates' <<<"${lines}"; then
    echo "  Placement returned no candidates: no host has enough free VCPU/PCPU,"
    echo "  MEMORY_MB or DISK_GB (or the requested traits). Check with:"
    echo "    openstack allocation candidate list --resource VCPU=<n> --resource MEMORY_MB=<mb> ..."
    grep -iE 'allocation candidates' <<<"${lines}" | sort -u | sed 's/^/  /'
else
    echo "  Placement had candidates; the hosts were removed by the filters above."
fi

echo
echo "== Why each host was rejected"
reasons=$(grep -E 'fails |does not |Not enough|not enough|Dropped [0-9]+ device|insufficient|Insufficient|cannot|Could not|No specific pagesize|has [0-9]+ (instances|io ops)' <<<"${lines}" \
    | grep -vE 'Lock |lockutils' | sort | uniq -c | sort -rn || true)
if [[ -n "${reasons}" ]]; then
    sed -E 's/^ +//; s/^([0-9]+) /  (x\1) /' <<<"${reasons}"
else
    echo "  No per-host reasons logged. Is debug = True set for nova-scheduler?"
fi

cat <<'EOF'

Hints:
  "Not enough PCI devices" / "Dropped N device(s)": an SR-IOV (direct) port
      asks for a physical network no VF offers. physical_network None means a
      direct port on a tunnelled (VXLAN/Geneve) network; only sriovnet1 has VFs.
  "Not enough available CPUs": not enough free pinned (dedicated) CPUs on one
      NUMA node of that host.
  "pagesize" / "memory": not enough free hugepages or memory on one NUMA node.
EOF
