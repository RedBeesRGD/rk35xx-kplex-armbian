# /root/provisioning.sh — sourced at the end of armbian-firstlogin, after the user account exists.
# Sourced, so it must not 'exit'; everything here is idempotent.
/usr/local/sbin/kino-setup "${RealUserName:-}" || true

# root and the user now have their own passwords: allow sshd, now and on every boot
install -d /var/lib/kplex
touch /var/lib/kplex/setup-done
systemctl start ssh.service || true

# hand the HDMI console to the new user once Armbian's cleanup has run; this ends the root session there
echo "Logging in as ${RealUserName:-the new user} on the console..."
systemd-run --quiet --on-active=3 systemctl restart getty@tty1.service || true
