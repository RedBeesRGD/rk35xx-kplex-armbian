# /root/provisioning.sh — sourced at the end of armbian-firstlogin, after the user account exists.
# Sourced, so it must not 'exit'; kino-setup is idempotent, so a re-run is harmless.
/usr/local/sbin/kino-setup "${RealUserName:-}" || true

