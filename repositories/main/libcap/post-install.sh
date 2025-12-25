#!/bin/sh

# We need to add an entry to the top of /etc/pam.d/system-auth
trap 'if [ -e /etc/pam.d/system-auth.bak ]; then
        mv /etc/pam.d/system-auth.bak /etc/pam.d/system-auth
    fi' INT TERM EXIT

[ -e /etc/pam.d/system-auth ] && \
    mv /etc/pam.d/system-auth /etc/pam.d/system-auth.bak

cat > /etc/pam.d/system-auth <<- "EOF"
    # Begin /etc/pam.d/system-auth

    auth      optional    pam_cap.so
EOF

if [ -e /etc/pam.d/system-auth ]; then
    cat /etc/pam.d/system-auth.bak >> /etc/pam.d/system-auth
    rm /etc/pam.d/system-auth.bak
fi

trap - INT TERM EXIT
