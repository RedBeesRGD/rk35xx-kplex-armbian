# kplex: explain the wait before Armbian's first-login setup (sourced before armbian-check-first-login.sh)
if [ "$(id -u)" = 0 ] && [ -f /root/.not_logged_in_yet ] && [ "$(systemctl is-system-running 2>/dev/null)" = starting ]; then
	printf '\nFirst boot is still finishing: compiling drivers and generating keys.\n'
	printf 'This takes about 5 minutes. Setup starts on its own when it is done.\nStill running:\n'
	systemctl list-jobs --no-legend 2>/dev/null | awk '$4 == "running" { print "  " $2 }'
	echo
fi
