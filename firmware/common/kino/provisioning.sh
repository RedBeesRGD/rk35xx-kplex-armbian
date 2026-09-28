# /root/provisioning.sh — sourced at the end of armbian-firstlogin, after the user account exists.
# Sourced, so it must not 'exit'; everything here is idempotent.
/usr/local/sbin/kino-setup "${RealUserName:-}" || true

# root and the user now have their own passwords: allow sshd, now and on every boot
install -d /var/lib/kplex
touch /var/lib/kplex/setup-done
systemctl start ssh.service || true

# only the first-boot setup session was meant to be quiet
rm -f /root/.hushlogin
