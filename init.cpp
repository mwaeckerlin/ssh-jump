/**

ssh-jump init: minimal, shell-free entrypoint for the ssh jump host.

Writes /run/ssh-jump/sshd_config from env, makes sure a host key exists,
then execv's sshd. Same three-stage / scratch / execv() pattern as the
sibling mwaeckerlin service containers. The runtime image contains no
shell, no ssh client, no busybox: only sshd, ssh-keygen, their shared
libraries and this init.

Behaviour:

  1. Refuse to act as a login shell. sshd starts every session through
     the shell of the user, which is this program; a session is never
     what the jump host is for, so `-c <command>` and a login shell end
     with an error.
  2. Check SSH_PERMIT_OPEN against what PermitOpen accepts and refuse
     anything else with `invalid SSH_PERMIT_OPEN`.
  3. Take the host key from the secret /run/secrets/ssh_host_ed25519_key
     when it exists (copied to /run/ssh-jump, mode 0600, with a missing
     final line break added), otherwise from the volume /var/lib/ssh-jump,
     where ssh-keygen creates it on the first start.
  4. Compose /run/ssh-jump/sshd_config and execv sshd in the foreground.

Supports --healthcheck: connects to 127.0.0.1:2222 and passes only when
the server sends its SSH-2.0 identification.

*/

#include <arpa/inet.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <iterator>
#include <netinet/in.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr const char *SSHD        = "/usr/sbin/sshd";
constexpr const char *SSH_KEYGEN  = "/usr/bin/ssh-keygen";
constexpr const char *CONF_PATH   = "/run/ssh-jump/sshd_config";
constexpr const char *SECRET_KEY  = "/run/secrets/ssh_host_ed25519_key";
constexpr const char *COPIED_KEY  = "/run/ssh-jump/ssh_host_ed25519_key";
constexpr const char *VOLUME_KEY  = "/var/lib/ssh-jump/ssh_host_ed25519_key";
constexpr const char *AUTH_KEYS   = "/run/secrets/authorized_keys";
constexpr int         PORT        = 2222;

std::string
env_or(const char *name, const std::string &fallback = {}) {
  const char *v = std::getenv(name);
  return (v && *v) ? std::string(v) : fallback;
}

bool
exists(const char *path) {
  struct stat st{};
  return stat(path, &st) == 0;
}

std::vector<std::string>
words(const std::string &value) {
  std::vector<std::string> result;
  std::string word;
  for (char c : value) {
    if (c == ' ') {
      if (word.empty()) return {};  // leading or double space
      result.push_back(word);
      word.clear();
    } else {
      word += c;
    }
  }
  if (word.empty()) return {};      // trailing space or empty value
  result.push_back(word);
  return result;
}

bool
all_of(const std::string &value, const char *allowed) {
  return !value.empty() && value.find_first_not_of(allowed) == std::string::npos;
}

// The value is written into sshd_config as one line. A line break would add
// directives of its own, so only what PermitOpen accepts gets through: `any`,
// `none`, or destinations `host:port`, `[ipv6]:port`, with `*` for any host
// or any port.
bool
valid_destination(const std::string &v) {
  const auto colon = v.rfind(':');
  if (colon == std::string::npos || colon == 0) return false;
  const std::string host = v.substr(0, colon);
  const std::string port = v.substr(colon + 1);
  if (port != "*") {
    if (!all_of(port, "0123456789") || port.size() > 5) return false;
    const int number = std::stoi(port);
    if (number < 1 || number > 65535) return false;
  }
  if (host == "*") return true;
  if (host.front() == '[')
    return host.size() > 2 && host.back() == ']'
           && all_of(host.substr(1, host.size() - 2), "0123456789abcdefABCDEF:.");
  return all_of(host, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_");
}

bool
valid_permit_open(const std::string &v) {
  if (v == "any" || v == "none") return true;
  const auto list = words(v);
  if (list.empty()) return false;
  for (const auto &destination : list)
    if (!valid_destination(destination)) return false;
  return true;
}

// sshd sends its identification line first; reading `SSH-2.0-` proves that
// it accepts connections and answers, which a TCP connect alone does not.
int
banner_probe() {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return 1;
  timeval timeout{3, 0};
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(PORT);
  inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
  if (connect(s, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0) {
    close(s);
    std::cerr << "health check: nothing listens on port " << PORT << std::endl;
    return 1;
  }
  char buffer[64];
  const ssize_t n = recv(s, buffer, sizeof buffer, 0);
  close(s);
  if (n < 8 || std::strncmp(buffer, "SSH-2.0-", 8) != 0) {
    std::cerr << "health check: no SSH identification on port " << PORT << std::endl;
    return 1;
  }
  return 0;
}

// sshd reads an OpenSSH private key only when its last line ends with a line
// break; a secret created with `printf %s "$KEY" | docker secret create` has
// none and fails with «error in libcrypto». The key is therefore copied to
// /run/ssh-jump, mode 0600, with the line break added where it is missing.
void
copy_host_key() {
  std::ifstream in(SECRET_KEY, std::ios::binary);
  if (!in) throw std::runtime_error(std::string("cannot read ") + SECRET_KEY + ": the secret must be readable for the user jump");
  std::string key((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  if (key.empty()) throw std::runtime_error(std::string(SECRET_KEY) + " is empty");
  if (key.back() != '\n') key += '\n';
  ::unlink(COPIED_KEY);
  const int fd = ::open(COPIED_KEY, O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (fd < 0) throw std::runtime_error(std::string("cannot write ") + COPIED_KEY + ": " + std::strerror(errno));
  const ssize_t written = ::write(fd, key.data(), key.size());
  ::close(fd);
  if (written != static_cast<ssize_t>(key.size()))
    throw std::runtime_error(std::string("cannot write ") + COPIED_KEY);
}

void
generate_host_key() {
  std::cerr << "**** Generating host key " << VOLUME_KEY << std::endl;
  const pid_t pid = fork();
  if (pid < 0) throw std::runtime_error(std::string("cannot start ssh-keygen: ") + std::strerror(errno));
  if (pid == 0) {
    const char *argv[] = {"ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "ssh-jump",
                          "-f", VOLUME_KEY, nullptr};
    execv(SSH_KEYGEN, const_cast<char *const *>(argv));
    std::perror(SSH_KEYGEN);
    _exit(127);
  }
  int status = 0;
  if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
    throw std::runtime_error(std::string("ssh-keygen could not write ") + VOLUME_KEY
                             + ": the volume /var/lib/ssh-jump must be writable for the user jump");
}

} // namespace

int main(int argc, char *argv[]) try {
  // started by sshd as the shell of the user: argv[0] starts with `-` for a
  // login shell, `-c <command>` for a command or a ForceCommand
  if ((argv[0] && argv[0][0] == '-') || (argc > 1 && std::string(argv[1]) == "-c")) {
    std::cerr << "ssh-jump: this host forwards connections only, it runs no commands" << std::endl;
    return 1;
  }

  const std::string permit_open = env_or("SSH_PERMIT_OPEN", "any");
  // validated before the health check as well, so a malformed value shows
  // up in the health state and can be tested without starting the server
  if (!valid_permit_open(permit_open))
    throw std::runtime_error("invalid SSH_PERMIT_OPEN: expected any, none or host:port destinations separated by single spaces");

  if (argc > 1 && std::string(argv[1]) == "--healthcheck")
    return banner_probe();

  const char *host_key = VOLUME_KEY;
  if (exists(SECRET_KEY)) {
    copy_host_key();
    host_key = COPIED_KEY;
  } else if (!exists(VOLUME_KEY)) {
    generate_host_key();
  }

  std::string conf;
  conf += "Port " + std::to_string(PORT) + "\n";
  conf += "AddressFamily inet\n";
  conf += "HostKey " + std::string(host_key) + "\n";
  conf += "PidFile none\n";
  conf += "LogLevel INFO\n";
  conf += "UseDNS no\n";
  // one user, keys only
  conf += "AllowUsers jump\n";
  conf += "PermitRootLogin no\n";
  conf += "AuthenticationMethods publickey\n";
  conf += "PubkeyAuthentication yes\n";
  conf += "PasswordAuthentication no\n";
  conf += "KbdInteractiveAuthentication no\n";
  conf += "AuthorizedKeysFile " + std::string(AUTH_KEYS) + "\n";
  // forwarding to a destination, nothing else
  conf += "AllowTcpForwarding local\n";
  conf += "PermitOpen " + permit_open + "\n";
  conf += "PermitListen none\n";
  conf += "GatewayPorts no\n";
  conf += "AllowAgentForwarding no\n";
  conf += "AllowStreamLocalForwarding no\n";
  conf += "X11Forwarding no\n";
  conf += "PermitTunnel no\n";
  conf += "PermitTTY no\n";
  conf += "PermitUserRC no\n";
  conf += "PermitUserEnvironment no\n";
  conf += "ForceCommand /usr/bin/init\n";
  conf += "ClientAliveInterval 60\n";
  // last, so that a Match block in a snippet ends with the file; sshd takes
  // the first value of a directive, so a snippet changes a setting inside a
  // Match block, `Match all` for every connection
  conf += "Include /etc/ssh/sshd_config.d/*.conf\n";

  std::ofstream out(CONF_PATH, std::ios::binary | std::ios::trunc);
  if (!out) throw std::runtime_error(std::string("cannot write ") + CONF_PATH);
  out << conf;
  out.close();

  std::cerr << "**** Starting sshd on port " << PORT << ", forwarding to " << permit_open << std::endl;

  const char *exec_argv[] = {SSHD, "-D", "-e", "-f", CONF_PATH, nullptr};
  execv(SSHD, const_cast<char *const *>(exec_argv));
  std::perror(SSHD);
  return 1;
} catch (const std::exception &e) {
  std::cerr << "EXCEPTION: " << e.what() << std::endl;
  return 1;
} catch (...) {
  std::cerr << "UNKNOWN ERROR" << std::endl;
  return 1;
}
