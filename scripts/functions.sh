function read_config {
	. ../default.cfg

	if [ -e ../custom.cfg ]; then
		. ../custom.cfg
	fi
}

function info {
	printf '%s\n' "$*"
}

