# kplex: first boot on the HDMI console, sourced before armbian-check-first-login.sh.
# Runs Armbian's setup here, without its "Press Enter" wait, then ends root's session so the getty
# logs the new user straight in. Other consoles are left to Armbian and still wait for Enter.
if [ "$(id -u)" = 0 ] && [ -f /root/.not_logged_in_yet ] && [ "$(tty)" = /dev/tty1 ] && [ -z "$SSH_CONNECTION" ]; then
	if [ "$(systemctl is-system-running 2>/dev/null)" = starting ]; then
		printf '\nFirst boot is still finishing. Setup starts on its own when it is done.\nStill running:\n'
		systemctl list-jobs --no-legend 2>/dev/null | awk '$4 == "running" { print "  " $2 }'
		echo
	fi
	# Armbian skips its Enter wait when SSH_CONNECTION is set
	SSH_CONNECTION=kplex-console bash /usr/lib/armbian/armbian-firstlogin
	[ -f /root/.not_logged_in_yet ] || exit
fi
