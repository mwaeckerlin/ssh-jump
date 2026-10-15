# Test client for tests/run.sh: git and the ssh client, which the image under
# test does not carry on purpose. Never published.
FROM alpine
RUN apk add --no-cache git openssh-client \
    && adduser -D tester
USER tester
WORKDIR /home/tester
ENTRYPOINT ["sleep", "infinity"]
