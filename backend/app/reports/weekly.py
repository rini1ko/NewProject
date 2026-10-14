"""Weekly meetings report: one ISO week in, one CSV file out.

No AWS in here on purpose: the Lambda handler (later) only decides *which* week to build
and where to put the bytes. Run it locally:

    docker compose exec backend python -m app.reports.weekly 2026-W40
"""

import asyncio
import csv
import io
import re
import sys
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal

from sqlalchemy import DateTime, cast, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.models import Meeting, User, meeting_participants

TIMEZONE = "Europe/Kyiv"
WEEK_RE = re.compile(r"^\d{4}-W\d{2}$")


def week_label(monday: date) -> str:
    year, number, _ = monday.isocalendar()
    return f"{year}-W{number:02d}"


def week_start(week: str) -> date:
    """Monday of an ISO week like "2026-W40"."""
    if not WEEK_RE.match(week):
        raise ValueError(f"Bad week {week!r}, expected e.g. 2026-W40")
    year, number = int(week[:4]), int(week[6:])
    return date.fromisocalendar(year, number, 1)  # raises ValueError for e.g. W54


def previous_week(today: date | None = None) -> str:
    """The ISO week before the one containing `today` (UTC date by default)."""
    today = today or datetime.now(UTC).date()
    return week_label(today - timedelta(days=today.weekday() + 7))


def report_key(week: str) -> str:
    """Same week -> same S3 key, so a second run overwrites instead of duplicating."""
    week_start(week)  # validates
    return f"reports/{week}.csv"


def _bounds(monday: date):
    """[start, end) of the week as timestamptz, with midnight meaning Kyiv midnight."""
    start = datetime.combine(monday, datetime.min.time())
    end = start + timedelta(days=7)
    return (
        func.timezone(TIMEZONE, cast(start, DateTime())),
        func.timezone(TIMEZONE, cast(end, DateTime())),
    )


def _hours() -> object:
    return func.extract("epoch", Meeting.ends_at - Meeting.starts_at) / 3600


def _round(value: Decimal | float | None) -> float:
    return round(float(value or 0), 2)


async def _totals(session: AsyncSession, monday: date) -> tuple[int, float]:
    lo, hi = _bounds(monday)
    row = (
        await session.execute(
            select(func.count(Meeting.id), func.coalesce(func.sum(_hours()), 0)).where(
                Meeting.starts_at >= lo, Meeting.starts_at < hi
            )
        )
    ).one()
    return row[0], _round(row[1])


async def _build(session: AsyncSession, week: str) -> bytes:
    monday = week_start(week)
    prev_monday = monday - timedelta(days=7)
    lo, hi = _bounds(monday)
    in_week = (Meeting.starts_at >= lo, Meeting.starts_at < hi)

    count, hours = await _totals(session, monday)
    prev_count, prev_hours = await _totals(session, prev_monday)

    by_owner = (
        await session.execute(
            select(User.name, func.count(Meeting.id), func.sum(_hours()))
            .join(User, User.id == Meeting.owner_id)
            .where(*in_week)
            .group_by(User.id, User.name)
            .order_by(func.sum(_hours()).desc(), User.name)
        )
    ).all()

    participants = (
        select(func.count())
        .where(meeting_participants.c.meeting_id == Meeting.id)
        .scalar_subquery()
    )
    longest = (
        await session.execute(
            select(
                Meeting.title,
                func.timezone(TIMEZONE, Meeting.starts_at),  # local wall-clock time
                _hours(),
                participants,
            )
            .where(*in_week)
            # Title and id as tie-breakers keep the file identical between runs.
            .order_by(_hours().desc(), Meeting.starts_at, Meeting.title, Meeting.id)
            .limit(5)
        )
    ).all()

    out = io.StringIO()
    w = csv.writer(out, lineterminator="\r\n")
    sunday = monday + timedelta(days=6)
    w.writerow(["Weekly meetings report", week])
    w.writerow(["Period", f"{monday} .. {sunday} ({TIMEZONE})"])
    w.writerow([])
    w.writerow(["Summary", "Meetings", "Hours"])
    w.writerow([week, count, hours])
    w.writerow([week_label(prev_monday), prev_count, prev_hours])
    w.writerow(["Change", f"{count - prev_count:+d}", f"{hours - prev_hours:+.2f}"])
    w.writerow([])
    w.writerow(["By organiser", "Meetings", "Hours"])
    for name, n, h in by_owner:
        w.writerow([name, n, _round(h)])
    w.writerow([])
    w.writerow(["Longest meetings"])
    w.writerow(["Title", "Start", "Hours", "Participants"])
    for title, starts, h, p in longest:
        w.writerow([title, starts.strftime("%Y-%m-%d %H:%M"), _round(h), p])

    # BOM so Excel opens Cyrillic names correctly.
    return out.getvalue().encode("utf-8-sig")


async def build_weekly_report(week: str, session: AsyncSession | None = None) -> bytes:
    """Query the meetings of one ISO week (e.g. "2026-W40") and return the CSV."""
    if session is not None:
        return await _build(session, week)
    async with SessionLocal() as own:
        return await _build(own, week)


if __name__ == "__main__":
    wk = sys.argv[1] if len(sys.argv) > 1 else previous_week()
    data = asyncio.run(build_weekly_report(wk))
    sys.stdout.write(data.decode("utf-8-sig"))
