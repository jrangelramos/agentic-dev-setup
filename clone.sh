#!/bin/bash
#
# Clone repositories. Run it from parent folder of this repo
#

clone() {
	echo ""
	echo -e "\033[1;33m==>  Setting up repository \033[1;36m$1/$2\033[0m"
	if [ -d "$2" ]; then
		return 1
	else
		git clone https://github.com/$1/$2
	fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(pwd)" == "$SCRIPT_DIR" ]]; then
	echo "Error: Do not run this script from inside the agentic-dev-setup repo."
	echo "Run it from the parent directory (as a sibling of this repo):"
	echo "  cd .. && ./agentic-dev-setup/clone.sh"
	exit 1
fi

clone openshift agentic-skills
clone openshift lightspeed-agentic-console
clone openshift lightspeed-agentic-operator
clone openshift lightspeed-agentic-sandbox
clone openshift lightspeed-operator
clone openshift cluster-update-console-plugin
