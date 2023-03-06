function read_config {
	. ../default.cfg

	if [ -e ../custom.cfg ]; then
		. ../custom.cfg
	fi
}

function info {
	printf '%s\n' "$*"
}

function activate_python_virtualenv {
	#sudo apt install build-essential python3-virtualenv virtualenv python3-dev \
        #         libffi-dev libssl-dev libsasl2-dev libldap2-dev python3-pip
	if [ ! -e "./tmp" ]; then
		mkdir "./tmp"
	fi

	if [ ! -e "./tmp/python-virtualenv" ]; then
		info "Creating python virtual environment"
		virtualenv "./tmp/python-virtualenv" > /dev/null 2>&1
	fi

	source "./tmp/python-virtualenv/bin/activate"
	info "Making sure DebOps and ansible are installed in the virtual environment"
	pip3 install debops[ansible] > /dev/null 2>&1
}

read_config
cd ".."
