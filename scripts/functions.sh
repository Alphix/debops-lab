function read_config {
	. ../default.cfg

	if [ -e ../custom.cfg ]; then
		. ../custom.cfg
	fi
}


if [ -z "${NO_COLOR:-}" ]; then
	# Colors, NC = no color / text reset
	NC='\033[0m'
	BLACK='\033[0;30m'
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[0;33m'
	BLUE='\033[0;34m'
	PURPLE='\033[0;35m'
	CYAN='\033[0;36m'
	WHITE='\033[0;37m'
	GREY='\033[2;37m'
else
	NC=''
	BLACK=''
	RED=''
	GREEN=''
	YELLOW=''
	BLUE=''
	PURPLE=''
	CYAN=''
	WHITE=''
	GREY=''
fi


function print_header {
	local TITLE="### ${1} ###"
	local LEN="${#TITLE}"
	local BAR="$(printf '#%.0s' $(seq 1 ${LEN}))"

	printf '%b%s%b\n' "${GREY}" "${BAR}" "${NC}"
	printf '%b%s%b\n' "${GREY}" "${TITLE}" "${NC}"
	printf '%b%s%b\n' "${GREY}" "${BAR}" "${NC}"
	printf '\n'
}


function print_ok {
	printf '%b✔%b %s\n' "${GREEN}" "${NC}" "$*"
}


function print_changed {
	printf '%b⚙%b %s\n' "${YELLOW}" "${NC}" "$*"
}


function print_error {
	printf '%b✘%b %s\n' "${RED}" "${NC}" "$*"
}


function print_info {
	printf '%bℹ%b %s\n' "${BLUE}" "${NC}" "$*"
}


function print_newline {
	printf '\n'
}


function die {
	printf '%b☠%b %s\n' "${RED}" "${NC}" "$*"
	exit 1
}


# FIXME: Remove
function info {
	printf '%s\n' "$*"
}


# FIXME: Remove
function error {
	printf '%s\n' "$*" >&2
}


function activate_python_virtualenv {
	#sudo apt install build-essential python3-virtualenv virtualenv python3-dev \
        #         libffi-dev libssl-dev libsasl2-dev libldap2-dev python3-pip
	if [ ! -e "./tmp" ]; then
		mkdir "./tmp"
	fi

	if [ ! -e "./tmp/python-virtualenv" ]; then
		print_changed "Creating python virtual environment in tmp/python-virtualenv"
		virtualenv "./tmp/python-virtualenv" > /dev/null 2>&1
	fi

	source "./tmp/python-virtualenv/bin/activate"

	if pip3 show -qqq debops && pip3 show -qqq ansible; then
		print_ok "DebOps and Ansible are installed in the virtual environment"
	else
		print_changed "Installing DebOps and Ansible in the virtual environment"
		pip3 install debops[ansible] > /dev/null 2>&1
	fi

	if pip3 show -qqq mitogen; then
		print_ok "Mitogen is installed in the virtual environment"
	else
		print_changed "Installing Mitogen in the virtual environment"
		pip3 install mitogen > /dev/null 2>&1

		# This is lame, but mitogen hardcodes Ansible versions and is
		# slow to react to new releases, see e.g.:
		#   - https://github.com/mitogen-hq/mitogen/issues/974
		#   - https://github.com/mitogen-hq/mitogen/issues/1021
		print_changed "Bumping the max supported Ansible version for Mitogen"
		sed -i 's/^ANSIBLE_VERSION_MAX\s*=.*/ANSIBLE_VERSION_MAX = (2, 99)/' \
			./tmp/python-virtualenv/lib/*/site-packages/ansible_mitogen/loaders.py
	fi
}


# This can be called as:
# run_playbook <playbook> [<host|group>] [<extra_args>]
function run_playbook {
	if [ "$#" -lt 1 ]; then
		die "Invalid number of arguments to function run_playbook()"
	fi

	if [ -z "${VIRTUAL_ENV:-}" ]; then
		die "Not running in a virtual environment!?"
	fi

	local PLAYBOOK="$1"
	local ARGS=("${PLAYBOOK}")
	shift

	if [ "$#" -gt 0 ]; then
		local HOST="$1"
		ARGS+=("-l" "${HOST}")
		shift
	else
		local HOST="all"
	fi

	ARGS+=("${@}")
	local LOGFILE="logs/${HOST}-${PLAYBOOK}.log"

	export ANSIBLE_STRATEGY=mitogen_linear

	print_info "Running DebOps playbook ${PLAYBOOK} on ${HOST}"
	print_info "Log file: project/${LOGFILE}"

	if ! debops run "${ARGS[@]}" > "${LOGFILE}" 2>&1; then
		die "DebOps run failed, review the log file for details"
	else
		print_ok "Done running DebOps playbook ${PLAYBOOK} on ${HOST}"
	fi
}


function start_vm {
	if [ "$#" -lt 2 ]; then
		die "Invalid arguments to start_vm()"
	fi

	local GUEST_NAME="$1"
	shift
	local GUEST_ID="$1"
	shift
	local GUEST_INSTALL_ARGS=("$@")

	if [ "${GUEST_ID}" -lt 1 -o "${GUEST_ID}" -gt 253 ]; then
		die "Invalid guest id passed to start_vm()"
	fi

	local GUEST_IP="192.168.99.${GUEST_ID}"
	local GUEST_MAC="$(printf "52:54:00:00:00:%02x" "${GUEST_ID}")"
	local GUEST_NETDEV="tap${GUEST_ID}"
	local QEMU_IMG="./tmp/vm-disks/${GUEST_NAME}.img"
	local QEMU_EXTRA_OPTS="-name ${GUEST_NAME}"
	QEMU_EXTRA_OPTS+=" -drive file=${QEMU_IMG},format=qcow2,cache=unsafe,if=virtio,aio=io_uring"
	QEMU_EXTRA_OPTS+=" -device virtio-net,netdev=network0,mac=${GUEST_MAC}"
	QEMU_EXTRA_OPTS+=" -netdev tap,id=network0,ifname=${GUEST_NETDEV},script=no,downscript=no"
	local GUEST_SSH_KNOWN_HOSTS="./tmp/ssh/hosts/known_host.${GUEST_NAME}"
	local GUEST_SSH_CONFIG="./tmp/ssh/hosts/${GUEST_NAME}.conf"
	local SSH_CONFIG="./tmp/ssh/ssh_config"

	if [ ! -d "tmp/ssh/hosts" ]; then
		mkdir -p "tmp/ssh/hosts"
	fi

	if [ ! -d "tmp/vm-disks" ]; then
		mkdir -p "tmp/vm-disks"
	fi

	if [ ! -e "${QEMU_IMG}" ]; then
		rm -f "${GUEST_SSH_KNOWN_HOSTS}"
		print_changed "Performing fresh install of VM ${GUEST_NAME}"
		qemu-img create -f qcow2 "${QEMU_IMG}" "${DL_QEMU_DISK_SIZE}" > /dev/null
		gnome-terminal --tab --wait --title "${GUEST_NAME}-install" --		\
			qemu-system-x86_64						\
			${DL_QEMU_OPTS}							\
			${QEMU_EXTRA_OPTS}						\
			"${GUEST_INSTALL_ARGS[@]}"
	fi

	if ! lsof "${QEMU_IMG}" > /dev/null; then
		print_changed "Starting VM ${GUEST_NAME}"
		gnome-terminal --tab --title "${GUEST_NAME}" --				\
			qemu-system-x86_64						\
			${DL_QEMU_OPTS}							\
			${QEMU_EXTRA_OPTS}
	else
		print_ok "VM ${GUEST_NAME} is already running"
	fi

	local ONLINE=0

	print_info "Waiting for VM ${GUEST_NAME} to be reachable via SSH"
	for i in $(seq 100); do
		sleep 3

		if ! ping -c1 -q "${GUEST_IP}" > /dev/null 2>&1; then
			print_info "Failed to ping VM ${GUEST_NAME} on ${GUEST_IP}, retrying"
			continue
		fi
		print_ok "Managed to ping VM ${GUEST_NAME} on ${GUEST_IP}"

		if [ ! -s "${GUEST_SSH_KNOWN_HOSTS}" ]; then
			if ! ssh-keyscan "${GUEST_IP}" > "${GUEST_SSH_KNOWN_HOSTS}" 2> /dev/null; then
				print_info "Failed to keyscan VM ${GUEST_NAME} on ${GUEST_IP}, retrying"
				rm -f "${GUEST_SSH_KNOWN_HOSTS}"
				continue
			fi
		fi
		print_ok "Managed to keyscan VM ${GUEST_NAME} on ${GUEST_IP}"

		cat <<EOF > "${GUEST_SSH_CONFIG}.tmp"
Host ${GUEST_NAME} ${GUEST_NAME}.${DL_DOMAIN} ${GUEST_IP}
	Hostname ${GUEST_IP}
	UserKnownHostsFile ~/.ssh/debops-lab/hosts/known_host.${GUEST_NAME}
EOF

		if [ ! -e "${GUEST_SSH_CONFIG}" ]; then
			mv "${GUEST_SSH_CONFIG}.tmp" "${GUEST_SSH_CONFIG}"
			print_changed "Installed SSH config for VM ${GUEST_NAME} in ${GUEST_SSH_CONFIG}"
		elif ! cmp -s "${GUEST_SSH_CONFIG}.tmp" "${GUEST_SSH_CONFIG}"; then
			mv "${GUEST_SSH_CONFIG}.tmp" "${GUEST_SSH_CONFIG}"
			print_changed "Updated SSH config for VM ${GUEST_NAME} in ${GUEST_SSH_CONFIG}"
		else
			rm -f "${GUEST_SSH_CONFIG}.tmp"
			print_ok "SSH config for VM ${GUEST_NAME} is up to date"
		fi

		print_info "Attempting to login via SSH as root to VM ${GUEST_NAME}"
		if ssh -F "${SSH_CONFIG}" "root@${GUEST_NAME}" hostname > /dev/null 2>&1; then
			ONLINE=1
			break
		fi

		print_info "Failed to login via SSH to VM ${GUEST_NAME}, retrying"
	done

	if [ "$ONLINE" -ne 1 ]; then
		die "Failed to contact ${GUEST_NAME}"
	fi

	print_ok "Guest VM ${GUEST_NAME} online and accepting SSH connections"
}


read_config
cd ".."
