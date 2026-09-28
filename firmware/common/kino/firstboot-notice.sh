# kplex: first-boot console behaviour, sourced before armbian-check-first-login.sh
if [ "$(id -u)" = 0 ] && [ -f /root/.not_logged_in_yet ]; then
	# Start setup on the HDMI console without "Press Enter": Armbian skips that wait when
	# SSH_CONNECTION is set. The serial console still waits, so setup cannot start on an unwatched one.
	if [ "$(tty)" = /dev/tty1 ] && [ -z "$SSH_CONNECTION" ]; then
		export SSH_CONNECTION=kplex-console
	fi
	if [ "$(systemctl is-system-running 2>/dev/null)" = starting ]; then
		printf '\nFirst boot is still finishing: compiling drivers and generating keys.\n'
		printf 'This takes about 5 minutes. Setup starts on its own when it is done.\nStill running:\n'
		systemctl list-jobs --no-legend 2>/dev/null | awk '$4 == "running" { print "  " $2 }'
		echo
	fi
fi
