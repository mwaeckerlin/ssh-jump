FROM mwaeckerlin/very-base AS init
RUN $PKG_INSTALL g++
COPY init.cpp .
RUN g++ -static -Os -flto=auto -fno-rtti -ffunction-sections -fdata-sections \
        -Wl,--gc-sections -Wl,-s -std=c++20 -o init init.cpp
RUN strip -s -R .comment -R .gnu.version --strip-unneeded init

FROM mwaeckerlin/very-base AS build
RUN $PKG_INSTALL openssh-server openssh-keygen
# the shell of jump is the init, which refuses every command: sshd only
# accepts a user whose shell exists
RUN adduser -S -D -H -h /var/empty -s /usr/bin/init jump \
    && mkdir -p /var/empty /var/lib/ssh-jump /run/ssh-jump /etc/ssh/sshd_config.d \
    && chown jump /var/lib/ssh-jump /run/ssh-jump
COPY --from=init init /usr/bin/init

# Collect only sshd, its session programs, ssh-keygen and their shared libs
# into /root/. The scratch runtime image contains no shell, no busybox and
# no ssh client: the jump host forwards connections and runs nothing.
RUN tar cph \
        /var/empty /var/lib/ssh-jump /run/ssh-jump /etc/ssh/sshd_config.d \
        /etc/passwd /etc/group /etc/nsswitch.conf \
        /usr/sbin/sshd /usr/lib/ssh/sshd-* /usr/bin/ssh-keygen /usr/bin/init \
        $(for f in /usr/sbin/sshd /usr/lib/ssh/sshd-* /usr/bin/ssh-keygen; do ldd $f; done \
          | sed -n 's,.* => \([^ ]*\) .*,\1,p' | sort -u) \
    | tar xpC /root/

FROM mwaeckerlin/scratch
ENV CONTAINERNAME="ssh-jump" \
    SSH_PERMIT_OPEN="any"
EXPOSE 2222
VOLUME /var/lib/ssh-jump
USER jump
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/bin/init", "--healthcheck"]
ENTRYPOINT ["/usr/bin/init"]
COPY --from=build /root/ /
