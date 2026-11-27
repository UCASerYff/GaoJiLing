"""Own one window process and its descendants without touching shared browsers."""

from __future__ import annotations

import ctypes as c
from ctypes import wintypes as w
import subprocess

from gaojiling import win32 as win


class _BasicLimits(c.Structure):
    _fields_ = [("process_time", c.c_int64), ("job_time", c.c_int64), ("flags", w.DWORD),
                ("min_working_set", c.c_size_t), ("max_working_set", c.c_size_t),
                ("active_limit", w.DWORD), ("affinity", c.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]


class _ExtendedLimits(c.Structure):
    _fields_ = [("basic", _BasicLimits), ("io", c.c_uint64 * 6), ("memory", c.c_size_t * 4)]


class _Accounting(c.Structure):
    _fields_ = [("times", c.c_int64 * 4), ("faults", w.DWORD), ("total", w.DWORD),
                ("active", w.DWORD), ("terminated", w.DWORD)]


class _StartupInfo(c.Structure):
    _fields_ = [("size", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR), ("title", w.LPWSTR),
                ("position_and_sizes", w.DWORD * 8), ("show", w.WORD), ("reserved_size", w.WORD),
                ("reserved_data", c.c_void_p), ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE)]


class _ProcessInfo(c.Structure):
    _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("thread_id", w.DWORD)]


_create_job = win._api(win.kernel, "CreateJobObjectW", w.HANDLE, c.c_void_p, w.LPCWSTR)
_set_job = win._api(win.kernel, "SetInformationJobObject", w.BOOL, w.HANDLE, c.c_int, c.c_void_p, w.DWORD)
_query_job = win._api(win.kernel, "QueryInformationJobObject", w.BOOL,
                      w.HANDLE, c.c_int, c.c_void_p, w.DWORD, c.c_void_p)
_assign_job = win._api(win.kernel, "AssignProcessToJobObject", w.BOOL, w.HANDLE, w.HANDLE)
_is_in_job = win._api(win.kernel, "IsProcessInJob", w.BOOL, w.HANDLE, w.HANDLE, c.POINTER(w.BOOL))
_create_process = win._api(win.kernel, "CreateProcessW", w.BOOL,
                           w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p, w.BOOL, w.DWORD, c.c_void_p, w.LPCWSTR,
                           c.POINTER(_StartupInfo), c.POINTER(_ProcessInfo))
_resume_thread = win._api(win.kernel, "ResumeThread", w.DWORD, w.HANDLE)
_terminate = win._api(win.kernel, "TerminateProcess", w.BOOL, w.HANDLE, w.UINT)
_open_process = win._api(win.kernel, "OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
_get_window_class = win._api(win.user, "GetClassNameW", c.c_int, w.HWND, w.LPWSTR, c.c_int)


class OwnedView:
    def __init__(self, command: list[str], env: dict[str, str] | None = None):
        self.job = _create_job(None, None)
        if not self.job:
            raise c.WinError(c.get_last_error())
        limits = _ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        info = _ProcessInfo()
        try:
            if not _set_job(self.job, 9, c.byref(limits), c.sizeof(limits)):
                raise c.WinError(c.get_last_error())
            start = _StartupInfo(size=c.sizeof(_StartupInfo))
            line = c.create_unicode_buffer(subprocess.list2cmdline(command))
            block = c.create_unicode_buffer("\0".join(f"{key}={env[key]}" for key in sorted(env, key=str.upper)) + "\0") if env is not None else None
            # Assign ownership before execution. Even the first bootloader or Edge
            # child must stay inside this job, and handles never reach the child.
            creation = 0x4 | 0x400  # CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT
            if not _create_process(command[0], line, None, None, False, creation,
                                   block, None, c.byref(start), c.byref(info)):
                raise c.WinError(c.get_last_error())
            if not _assign_job(self.job, info.process) or _resume_thread(info.thread) == 0xFFFFFFFF:
                error = c.WinError(c.get_last_error())
                _terminate(info.process, 1)
                raise error
        except BaseException:
            self.close()
            raise
        finally:
            for handle in (info.thread, info.process):
                if handle:
                    win.close_handle(handle)

    def is_running(self):
        info = _Accounting()
        if not _query_job(self.job, 1, c.byref(info), c.sizeof(info), None):
            raise c.WinError(c.get_last_error())
        return info.active != 0

    def owns(self, pid):
        process = _open_process(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not process:
            return False
        try:
            belongs = w.BOOL()
            return bool(_is_in_job(process, self.job, c.byref(belongs)) and belongs.value)
        finally:
            win.close_handle(process)

    def edge_window(self):
        matches = []

        @win.ENUMWINDOWS
        def check(hwnd, _):
            name = c.create_unicode_buffer(64)
            if win.window_visible(hwnd) and _get_window_class(hwnd, name, len(name)) and name.value == "Chrome_WidgetWin_1":
                pid = w.DWORD()
                win.window_pid(hwnd, c.byref(pid))
                if self.owns(pid.value):
                    matches.append(hwnd)
                    return False
            return True

        win.enum_windows(check, 0)
        return matches[0] if matches else None

    def close(self):
        if self.job:
            win.close_handle(self.job)
            self.job = None
