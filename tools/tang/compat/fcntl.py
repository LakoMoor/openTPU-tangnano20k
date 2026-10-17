"""Windows stand-in for fcntl: openTPU's host code takes Linux file locks; on Windows they are
no-ops (tools/tang puts this directory on sys.path; one user, one board)."""
LOCK_SH, LOCK_EX, LOCK_NB, LOCK_UN = 1, 2, 4, 8


def flock(*a, **k):
    return None


def lockf(*a, **k):
    return None


def fcntl(*a, **k):
    return 0


def ioctl(*a, **k):
    return 0
