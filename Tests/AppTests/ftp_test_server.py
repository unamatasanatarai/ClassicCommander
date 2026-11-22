#!/usr/bin/env python3
"""A minimal FTP server for ClassicCommander's tests (plain FTP, passive mode, one folder).

Usage: ftp_test_server.py ROOT USER PASSWORD [--no-mlsd] [--dos]
Prints "PORT <n>" on the first line once listening on 127.0.0.1.
Not a real server: no security beyond checking the one user name and password, test use only.
"""
import os, socket, socketserver, sys, threading, time, stat

ROOT, USER, PASSWORD = os.path.realpath(sys.argv[1]), sys.argv[2], sys.argv[3]
NO_MLSD = "--no-mlsd" in sys.argv
DOS = "--dos" in sys.argv


def real(cwd, arg):
    """Maps an FTP path to a path inside ROOT (never outside it)."""
    path = arg if arg.startswith("/") else os.path.join(cwd, arg)
    path = os.path.normpath("/" + path).lstrip("/")
    full = os.path.realpath(os.path.join(ROOT, path))
    if full != ROOT and not full.startswith(ROOT + os.sep):
        raise PermissionError(arg)
    return full


def virtual(full):
    rel = os.path.relpath(full, ROOT)
    return "/" if rel == "." else "/" + rel


class Handler(socketserver.StreamRequestHandler):
    def reply(self, text):
        self.wfile.write((text + "\r\n").encode())

    def handle(self):
        self.cwd, self.user, self.authed, self.pasv, self.rest, self.rnfr = "/", None, False, None, 0, None
        self.reply("220 ClassicCommander test server")
        while True:
            line = self.rfile.readline()
            if not line:
                return
            line = line.decode("utf-8", "replace").rstrip("\r\n")
            cmd, _, arg = line.partition(" ")
            cmd = cmd.upper()
            try:
                if not self.dispatch(cmd, arg):
                    return
            except PermissionError:
                self.reply("550 Permission denied")
            except FileNotFoundError:
                self.reply("550 No such file or directory")
            except Exception as e:  # keep serving
                self.reply("451 " + str(e).replace("\n", " "))

    def data_conn(self):
        if not self.pasv:
            self.reply("425 Use PASV first")
            return None
        self.reply("150 Opening data connection")
        conn, _ = self.pasv.accept()
        self.pasv.close()
        self.pasv = None
        return conn

    def listing(self, path, machine):
        lines = []
        for name in sorted(os.listdir(path)):
            st = os.lstat(os.path.join(path, name))
            isdir = stat.S_ISDIR(st.st_mode)
            if machine:
                t = time.strftime("%Y%m%d%H%M%S", time.gmtime(st.st_mtime))
                kind = "dir" if isdir else "file"
                lines.append(f"type={kind};size={st.st_size};modify={t};UNIX.mode={oct(st.st_mode & 0o777)[2:].zfill(4)}; {name}")
            elif DOS:
                t = time.strftime("%m-%d-%y  %I:%M%p", time.localtime(st.st_mtime))
                lines.append(f"{t}       {'<DIR>' if isdir else str(st.st_size).rjust(14)} {name}")
            else:
                mode = stat.filemode(st.st_mode)
                t = time.strftime("%b %d %H:%M", time.localtime(st.st_mtime))
                lines.append(f"{mode}   1 owner group {st.st_size:>10} {t} {name}")
        return "".join(l + "\r\n" for l in lines).encode()

    def dispatch(self, cmd, arg):
        if cmd == "USER":
            self.user = arg
            self.reply("331 Password required")
        elif cmd == "PASS":
            if self.user == USER and arg == PASSWORD:
                self.authed = True
                self.reply("230 Logged in")
            else:
                self.reply("530 Login incorrect")
        elif cmd == "QUIT":
            self.reply("221 Bye")
            return False
        elif cmd == "AUTH":
            self.reply("502 TLS not supported by this test server")
        elif not self.authed:
            self.reply("530 Please log in")
        elif cmd == "PWD":
            self.reply(f'257 "{self.cwd}" is current directory')
        elif cmd == "CWD":
            full = real(self.cwd, arg)
            if not os.path.isdir(full):
                raise FileNotFoundError
            self.cwd = virtual(full)
            self.reply("250 OK")
        elif cmd == "CDUP":
            self.cwd = virtual(real(self.cwd, ".."))
            self.reply("250 OK")
        elif cmd in ("TYPE", "MODE", "STRU", "NOOP", "OPTS", "SITE"):
            self.reply("200 OK")
        elif cmd == "SYST":
            self.reply("215 UNIX Type: L8")
        elif cmd == "FEAT":
            self.reply("211 End")
        elif cmd == "EPSV":
            self.reply("500 EPSV not supported")
        elif cmd == "PASV":
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            s.listen(1)
            self.pasv = s
            p = s.getsockname()[1]
            self.reply(f"227 Entering Passive Mode (127,0,0,1,{p >> 8},{p & 255})")
        elif cmd in ("LIST", "NLST", "MLSD"):
            if cmd == "MLSD" and NO_MLSD:
                self.reply("500 MLSD not understood")
                return True
            target = real(self.cwd, arg if arg and not arg.startswith("-") else ".")
            if not os.path.isdir(target):
                raise FileNotFoundError
            conn = self.data_conn()
            if conn:
                data = ("".join(n + "\r\n" for n in sorted(os.listdir(target)))).encode() if cmd == "NLST" else self.listing(target, cmd == "MLSD")
                conn.sendall(data)
                conn.close()
                self.reply("226 Done")
        elif cmd == "SIZE":
            self.reply(f"213 {os.path.getsize(real(self.cwd, arg))}")
        elif cmd == "MDTM":
            t = time.strftime("%Y%m%d%H%M%S", time.gmtime(os.path.getmtime(real(self.cwd, arg))))
            self.reply(f"213 {t}")
        elif cmd == "MFMT":
            stamp, _, name = arg.partition(" ")
            import calendar
            t = calendar.timegm(time.strptime(stamp, "%Y%m%d%H%M%S"))
            os.utime(real(self.cwd, name), (t, t))
            self.reply(f"213 Modify={stamp}; {name}")
        elif cmd == "REST":
            self.rest = int(arg)
            self.reply("350 Restarting")
        elif cmd == "RETR":
            full = real(self.cwd, arg)
            if not os.path.isfile(full):
                raise FileNotFoundError
            conn = self.data_conn()
            if conn:
                with open(full, "rb") as f:
                    f.seek(self.rest)
                    conn.sendall(f.read())
                self.rest = 0
                conn.close()
                self.reply("226 Transfer complete")
        elif cmd in ("STOR", "APPE"):
            full = real(self.cwd, arg)
            if os.path.basename(full).startswith("denied"):
                self.reply("553 Permission denied")
                return True
            conn = self.data_conn()
            if conn:
                mode = "ab" if cmd == "APPE" or self.rest else "wb"
                with open(full, mode) as f:
                    while True:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        f.write(chunk)
                self.rest = 0
                conn.close()
                self.reply("226 Transfer complete")
        elif cmd == "MKD":
            os.mkdir(real(self.cwd, arg))
            self.reply(f'257 "{arg}" created')
        elif cmd == "RMD":
            os.rmdir(real(self.cwd, arg))
            self.reply("250 Removed")
        elif cmd == "DELE":
            os.remove(real(self.cwd, arg))
            self.reply("250 Deleted")
        elif cmd == "RNFR":
            self.rnfr = real(self.cwd, arg)
            if not os.path.exists(self.rnfr):
                raise FileNotFoundError
            self.reply("350 Ready")
        elif cmd == "RNTO":
            os.rename(self.rnfr, real(self.cwd, arg))
            self.rnfr = None
            self.reply("250 Renamed")
        else:
            self.reply("502 Not implemented")
        return True


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    server = Server(("127.0.0.1", 0), Handler)
    print("PORT", server.server_address[1], flush=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        sys.stdin.read()          # exits when the test closes stdin
    finally:
        server.shutdown()
