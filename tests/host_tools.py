"""Real host equivalents of the BusyBox operations used by Darwin fixtures."""
import fcntl
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile


def run_host(script, *, cwd=None, timeout=15):
    if sys.platform != 'darwin':
        return subprocess.run(['bash', '-c', script], cwd=cwd, capture_output=True,
                              text=True, timeout=timeout)
    with tempfile.TemporaryDirectory(prefix='acc-host-tools-') as directory:
        for tool in ('flock', 'timeout', 'sed', 'stat', 'bash'):
            wrapper = Path(directory) / tool
            wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' +
                               shlex.quote(__file__) + ' ' + tool + ' "$@"\n')
            wrapper.chmod(0o755)
        env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'])
        return subprocess.run(['bash', '-c', script], cwd=cwd, env=env,
                              capture_output=True, text=True, timeout=timeout)


def main(tool, args):
    if tool == 'bash':
        if args and args[0] == '-n':
            checked = subprocess.run(['/bin/bash', *args], capture_output=True)
            sys.stdout.buffer.write(checked.stdout)
            sys.stderr.buffer.write(checked.stderr)
            # Apple's Bash 3.2 incorrectly returns zero on an unclosed array.
            return checked.returncode or (2 if checked.stderr else 0)
        os.execv('/bin/bash', ['bash', *args])
    if tool == 'flock':
        operation = fcntl.LOCK_EX
        while args and args[0].startswith('-'):
            option = args.pop(0)
            if option == '-n': operation |= fcntl.LOCK_NB
            elif option == '-u': operation = fcntl.LOCK_UN
            else: raise ValueError('Unsupported flock option: ' + option)
        target = args.pop(0)
        fd = int(target) if target.isdecimal() else os.open(target, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, operation)
        except BlockingIOError:
            return 1
        # flock on an inherited descriptor persists in the caller's open file
        # description, matching BusyBox. File/command locks live until it exits.
        return subprocess.call(args, close_fds=False) if args else 0
    if tool == 'timeout':
        seconds = float(args.pop(0))
        child = subprocess.Popen(args, start_new_session=True)
        try:
            code = child.wait(timeout=seconds)
            return code if code >= 0 else 128 - code
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try: child.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            return 124
    if tool == 'sed':
        if args and args[0] == '-i' and args[1] != '': args.insert(1, '')
        for i, arg in enumerate(args):
            if arg.startswith('1c') and not arg.startswith('1c\\'):
                args[i] = '1c\\\n' + arg[2:] + '\n'
            elif arg.startswith('s/'):
                args[i] = arg.replace(r'\n', '\\\n')
        os.execv('/usr/bin/sed', ['sed', *args])
    if tool == 'stat':
        if args[0] == '-L': args.pop(0)
        if args[0] != '-c': os.execv('/usr/bin/stat', ['stat', *args])
        fmt, target = args[1:]
        value = os.stat(target)
        fields = {'%a': format(value.st_mode & 0o7777, 'o'), '%u': str(value.st_uid),
                  '%g': str(value.st_gid), '%s': str(value.st_size)}
        for key, field in fields.items(): fmt = fmt.replace(key, field)
        if '%' in fmt: raise ValueError('Unsupported stat format: ' + fmt)
        print(fmt)
        return 0
    raise ValueError('Unsupported host tool: ' + tool)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2:]))
