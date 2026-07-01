"""
foreman-tools tui — interactive project dashboard
Receives: path to JSON data file as sys.argv[1]
Keys: j/k or arrow-down/up to navigate, q to quit, r to reload
"""

import curses
import json
import os
import signal
import sys
from pathlib import Path

# ── colour pair constants (1-based) ──────────────────────────────────────────
CP_ACCENT = 1   # cyan — header, labels
CP_GOOD   = 2   # green — positive status
CP_WARN   = 3   # yellow — warnings / unreleased
CP_DIM    = 4   # grey — subdued text
CP_SEL    = 5   # white on blue — selected row

LEFT_W    = 24  # inner width of the left panel
BORDER_W  = 1   # one column for the separator
RIGHT_X   = LEFT_W + BORDER_W + 1  # right panel starts here (1-based from panel col 0)


# ── data loading ─────────────────────────────────────────────────────────────

def load_data(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:
        return {"user": "unknown", "projects": [], "_error": str(exc)}


# ── rendering helpers ─────────────────────────────────────────────────────────

def safe_addstr(win, y: int, x: int, text: str, attr: int = 0) -> None:
    """Write text clipped to window width; swallow curses.error on overflow."""
    try:
        max_y, max_x = win.getmaxyx()
        if y < 0 or y >= max_y or x < 0 or x >= max_x:
            return
        available = max_x - x - 1  # leave 1 for safety on right edge
        if available <= 0:
            return
        win.addstr(y, x, text[:available], attr)
    except curses.error:
        pass


def hline(win, y: int, x: int, length: int, attr: int = 0) -> None:
    try:
        max_y, max_x = win.getmaxyx()
        if y < 0 or y >= max_y:
            return
        actual = min(length, max_x - x)
        if actual > 0:
            win.hline(y, x, curses.ACS_HLINE, actual, attr)
    except curses.error:
        pass


def vline(win, y: int, x: int, length: int, attr: int = 0) -> None:
    try:
        max_y, max_x = win.getmaxyx()
        if x < 0 or x >= max_x:
            return
        actual = min(length, max_y - y)
        if actual > 0:
            win.vline(y, x, curses.ACS_VLINE, actual, attr)
    except curses.error:
        pass


# ── left panel — project list ─────────────────────────────────────────────────

def draw_left(win, projects: list, selected: int, scroll: int) -> None:
    max_y, max_x = win.getmaxyx()
    inner_w = min(LEFT_W, max_x - 2)
    if inner_w <= 0:
        return

    visible = max_y - 2  # rows available between top/bottom borders
    for rel, proj in enumerate(projects[scroll: scroll + visible]):
        abs_idx = scroll + rel
        row = rel + 1
        is_sel = abs_idx == selected
        label = proj.get("name", "?")
        priv = " [private]" if proj.get("is_private") else " [public] "
        line = f"{label}{priv}"

        attr = curses.color_pair(CP_SEL) | curses.A_BOLD if is_sel else 0
        marker = "▶ " if is_sel else "  "
        safe_addstr(win, row, 1, marker + line, attr)


# ── right panel — project detail ──────────────────────────────────────────────

def draw_right(win, proj, right_x: int, panel_w: int) -> None:
    max_y, _ = win.getmaxyx()
    if panel_w <= 4 or proj is None:
        if proj is None:
            safe_addstr(win, 2, right_x + 1, "No projects found.", curses.color_pair(CP_DIM))
        return

    name        = proj.get("name", "?")
    description = proj.get("description") or ""
    path        = proj.get("path", "")
    is_private  = proj.get("is_private", False)
    latest_tag  = proj.get("latest_tag") or "—"
    commits     = proj.get("commits_since", 0)
    is_dirty    = proj.get("is_dirty", False)
    has_spec    = proj.get("has_spec", False)
    has_claude  = proj.get("has_claude_md", False)
    is_local    = proj.get("is_local", False)

    # ── title row ───────────────────────────────────────────────────────────
    lock = "🔒 private" if is_private else "🔓 public "
    safe_addstr(win, 1, right_x + 2, name, curses.color_pair(CP_ACCENT) | curses.A_BOLD)
    safe_addstr(win, 1, right_x + 2 + len(name) + 2, lock, curses.color_pair(CP_DIM))

    # ── description + path ──────────────────────────────────────────────────
    row = 2
    if description:
        safe_addstr(win, row, right_x + 2, description, 0)
        row += 1
    if path:
        display_path = path.replace(str(Path.home()), "~")
        safe_addstr(win, row, right_x + 2, display_path, curses.color_pair(CP_DIM))
        row += 1

    row += 1  # blank line

    # ── release row ─────────────────────────────────────────────────────────
    safe_addstr(win, row, right_x + 2, "Release", curses.color_pair(CP_ACCENT) | curses.A_BOLD)
    rel_text = f"  {latest_tag}"
    if commits > 0:
        rel_text += f" · {commits} commit{'s' if commits != 1 else ''} unreleased"
    safe_addstr(win, row, right_x + 9, rel_text, curses.color_pair(CP_WARN) if commits > 0 else 0)
    if is_dirty:
        safe_addstr(win, row, right_x + 9 + len(rel_text) + 1, "(dirty)", curses.color_pair(CP_WARN))
    row += 2

    # ── MVP readiness ────────────────────────────────────────────────────────
    safe_addstr(win, row, right_x + 2, "MVP Readiness", curses.color_pair(CP_ACCENT) | curses.A_BOLD)
    row += 1

    checks = [
        (has_spec,    "spec.md present"),
        (has_claude,  "CLAUDE.md present"),
        (is_local,    "local clone present"),
        (bool(latest_tag and latest_tag != "—"), "tagged release"),
    ]
    for ok, label in checks:
        if ok:
            safe_addstr(win, row, right_x + 2, f"✓ {label}", curses.color_pair(CP_GOOD))
        else:
            safe_addstr(win, row, right_x + 2, f"✗ {label}", curses.color_pair(CP_DIM))
        row += 1

    if commits > 0:
        row += 1
        safe_addstr(win, row, right_x + 2,
                    f"→ {commits} unreleased — run /release",
                    curses.color_pair(CP_WARN))
        row += 1

    if not is_local:
        safe_addstr(win, row, right_x + 2,
                    "→ not cloned locally — run /restore-projects",
                    curses.color_pair(CP_WARN))


# ── chrome / borders ─────────────────────────────────────────────────────────

def draw_chrome(win, user: str, n_projects: int) -> None:
    max_y, max_x = win.getmaxyx()
    if max_y < 4 or max_x < 20:
        return

    # header bar
    win.attron(curses.color_pair(CP_ACCENT) | curses.A_BOLD)
    try:
        win.hline(0, 0, ord(" "), max_x)
    except curses.error:
        pass
    safe_addstr(win, 0, 1, "  FOREMAN ", curses.color_pair(CP_ACCENT) | curses.A_BOLD)
    gh_label = f"github.com/{user}  "
    safe_addstr(win, 0, max(1, max_x - len(gh_label) - 1), gh_label,
                curses.color_pair(CP_ACCENT) | curses.A_BOLD)
    win.attroff(curses.color_pair(CP_ACCENT) | curses.A_BOLD)

    # footer bar
    footer_y = max_y - 1
    try:
        win.hline(footer_y, 0, ord(" "), max_x)
    except curses.error:
        pass
    count_label = f"  {n_projects} project{'s' if n_projects != 1 else ''}  "
    help_label  = "  j/k · q quit · r reload  "
    safe_addstr(win, footer_y, 1, count_label, curses.color_pair(CP_DIM))
    safe_addstr(win, footer_y, max(1, max_x - len(help_label) - 1), help_label,
                curses.color_pair(CP_DIM))

    # vertical separator
    sep_x = LEFT_W + 1
    if sep_x < max_x - 1:
        vline(win, 1, sep_x, max_y - 2, curses.color_pair(CP_DIM))


def draw_too_small(win) -> None:
    try:
        win.clear()
        win.addstr(0, 0, "Terminal too small — resize to at least 50×10")
    except curses.error:
        pass


# ── main TUI loop ─────────────────────────────────────────────────────────────

def main(stdscr: "curses._CursesWindow") -> None:
    data_path = sys.argv[1]

    # terminal setup
    curses.curs_set(0)
    curses.use_default_colors()
    stdscr.keypad(True)
    stdscr.timeout(200)  # ms — allows SIGWINCH polling

    # colour pairs
    curses.init_pair(CP_ACCENT, curses.COLOR_CYAN,    -1)
    curses.init_pair(CP_GOOD,   curses.COLOR_GREEN,   -1)
    curses.init_pair(CP_WARN,   curses.COLOR_YELLOW,  -1)
    curses.init_pair(CP_DIM,    curses.COLOR_WHITE,   -1)
    curses.init_pair(CP_SEL,    curses.COLOR_WHITE,   curses.COLOR_BLUE)

    # resize flag (SIGWINCH)
    needs_resize = [False]

    def on_resize(sig, frame):  # noqa: ARG001
        needs_resize[0] = True

    signal.signal(signal.SIGWINCH, on_resize)

    data     = load_data(data_path)
    projects = data.get("projects", [])
    user     = data.get("user", "unknown")

    selected = 0
    scroll   = 0

    while True:
        max_y, max_x = stdscr.getmaxyx()

        if max_y < 10 or max_x < 50:
            draw_too_small(stdscr)
            stdscr.refresh()
            ch = stdscr.getch()
            if ch in (ord("q"), ord("Q"), 27):
                break
            continue

        if needs_resize[0]:
            needs_resize[0] = False
            curses.resizeterm(max_y, max_x)

        stdscr.erase()
        draw_chrome(stdscr, user, len(projects))

        # clamp selection
        if projects:
            selected = max(0, min(selected, len(projects) - 1))
        else:
            selected = 0

        # scroll so selected row stays visible
        visible_rows = max_y - 2
        if selected < scroll:
            scroll = selected
        elif selected >= scroll + visible_rows:
            scroll = selected - visible_rows + 1

        draw_left(stdscr, projects, selected, scroll)

        right_x  = LEFT_W + 1
        panel_w  = max_x - right_x - 1
        proj     = projects[selected] if projects else None
        draw_right(stdscr, proj, right_x, panel_w)

        stdscr.refresh()

        ch = stdscr.getch()

        if ch in (ord("q"), ord("Q"), 27):
            break
        elif ch in (ord("j"), curses.KEY_DOWN):
            if projects:
                selected = min(selected + 1, len(projects) - 1)
        elif ch in (ord("k"), curses.KEY_UP):
            if projects:
                selected = max(selected - 1, 0)
        elif ch in (ord("r"), ord("R")):
            data     = load_data(data_path)
            projects = data.get("projects", [])
            user     = data.get("user", "unknown")
            selected = min(selected, max(0, len(projects) - 1))
            scroll   = 0
        elif ch == curses.KEY_RESIZE:
            max_y, max_x = stdscr.getmaxyx()
            curses.resizeterm(max_y, max_x)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: tui.py <data.json>", file=sys.stderr)
        sys.exit(1)
    try:
        curses.wrapper(main)
    except curses.error as exc:
        print(f"curses error: {exc}", file=sys.stderr)
        sys.exit(1)
