// TEMPORARY exit-path diagnostics (experiment only).
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <string>

static void emit(const std::string& s) { (void)!::write(2, s.data(), s.size()); }

static std::string slurp(const char* path, size_t cap = 4096) {
  int fd = ::open(path, O_RDONLY);
  if (fd < 0) return std::string("<open failed> ") + path + "\n";
  std::string out(cap, '\0');
  ssize_t n = ::read(fd, out.data(), cap);
  ::close(fd);
  out.resize(n < 0 ? 0 : (size_t)n);
  return out;
}

static std::string grep_lines(const std::string& text, const char* const* keys) {
  std::string out;
  size_t pos = 0;
  while (pos < text.size()) {
    size_t e = text.find('\n', pos);
    if (e == std::string::npos) e = text.size();
    std::string line = text.substr(pos, e - pos);
    for (const char* const* k = keys; *k; ++k)
      if (line.rfind(*k, 0) == 0) { out += "  " + line + "\n"; break; }
    pos = e + 1;
  }
  return out;
}

#include <dirent.h>
#include <cstdlib>
static std::string threads() {
  std::string out = "  tasks:";
  DIR* d = ::opendir("/proc/self/task");
  if (!d) return out + " <none>\n";
  while (dirent* e = ::readdir(d)) {
    if (e->d_name[0] == '.') continue;
    std::string base = std::string("/proc/self/task/") + e->d_name;
    std::string comm = slurp((base + "/comm").c_str(), 64);
    if (!comm.empty() && comm.back() == '\n') comm.pop_back();
    std::string st = slurp((base + "/stat").c_str(), 512);
    size_t rp = st.rfind(')');
    out += std::string(" ") + e->d_name + ":" + comm + ":" + (rp != std::string::npos && rp + 2 < st.size() ? st[rp + 2] : '?');
  }
  ::closedir(d);
  return out + "\n";
}

static void stage(const char* name) {
  static const char* const keys[] = {"Threads:", "Seccomp", "NoNewPrivs", "SigPnd", "ShdPnd", "SigBlk", "SigCgt", "CapEff", nullptr};
  std::string s = std::string("[diag] ") + name + " pid=" + std::to_string(::getpid()) +
                  " uid=" + std::to_string(::getuid()) + "\n";
  s += grep_lines(slurp("/proc/self/status"), keys);
  s += "  aio-nr=" + slurp("/proc/sys/fs/aio-nr", 64) + "  aio-max-nr=" + slurp("/proc/sys/fs/aio-max-nr", 64);
  s += threads();
  emit(s);
}

static void at_exit_last() {
  stage("atexit-last (after harness finalize)");
  if (const char* m = std::getenv("ACL_DIAG_FASTEXIT"); m && *m == '1') {
    emit("[diag] _exit(0) now\n");
    ::_exit(0);
  }
}

__attribute__((constructor(101))) static void diag_ctor() {
  stage("ctor");
  emit("[diag] limits:\n" + slurp("/proc/self/limits") + "[diag] cgroup:\n" + slurp("/proc/self/cgroup", 512));
  std::atexit(at_exit_last);
}

__attribute__((destructor(101))) static void diag_dtor() { stage("fini"); }
