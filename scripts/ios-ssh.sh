# Sourced. ssh to the iPad's jailbroken iOS through `iproxy 2222 22`, one
# password prompt per run (a shared connection). iOS 9's OpenSSH only has
# ssh-rsa host keys, which OpenSSH 8.8+ refuses unless asked. IdentitiesOnly
# stops an agent with many keys using up sshd's tries before the password.
# ServerAlive drops the connection kloader leaves hanging when iOS stops.
IOS_PORT="${IOS_PORT:-2222}"
CM="$(mktemp -u /tmp/j1kit-ssh.XXXXXX)"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
          -o IdentitiesOnly=yes -o LogLevel=ERROR
          -o ControlMaster=auto -o ControlPath="$CM"
          -o ControlPersist=120 -o ConnectTimeout=10
          -o ServerAliveInterval=2 -o ServerAliveCountMax=3)
ios() { ssh "${SSH_OPTS[@]}" -p "$IOS_PORT" root@127.0.0.1 "$@"; }
ios_put() { ios "rm -f '$2' && cat > '$2' && chmod 755 '$2'" < "$1"; }
ios_close() { ssh -o ControlPath="$CM" -O exit x 2>/dev/null || true; }
