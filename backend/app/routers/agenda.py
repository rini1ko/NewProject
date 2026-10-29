import uuid
from datetime import UTC, datetime

from fastapi import APIRouter
from sqlalchemy import select

from app.auth import CurrentUser
from app.db import SessionDep
from app.models import MeetingAgenda
from app.routers.meetings import _get_meeting
from app.schemas import AgendaRead, AgendaWrite

router = APIRouter(prefix="/meetings/{meeting_id}/agenda", tags=["agenda"])


async def _read(session: SessionDep, meeting_id: uuid.UUID) -> MeetingAgenda | None:
    return await session.scalar(select(MeetingAgenda).where(MeetingAgenda.meeting_id == meeting_id))


@router.get("", response_model=AgendaRead)
async def get_agenda(meeting_id: uuid.UUID, session: SessionDep, user: CurrentUser):
    await _get_meeting(session, meeting_id, user)  # someone else's meeting is "not found"
    agenda = await _read(session, meeting_id)
    if agenda is None:
        return AgendaRead(items=[], action_items=[], ai_suggestion=None, updated_at=None)
    return agenda


@router.put("", response_model=AgendaRead)
async def save_agenda(
    meeting_id: uuid.UUID, payload: AgendaWrite, session: SessionDep, user: CurrentUser
):
    """The only place an agenda is written, whether it was typed or suggested by the parser.
    The parser Lambda has no access to this table: a person always presses Save."""
    await _get_meeting(session, meeting_id, user)
    agenda = await _read(session, meeting_id)
    if agenda is None:
        agenda = MeetingAgenda(meeting_id=meeting_id)
        session.add(agenda)
    agenda.items = [item.model_dump(mode="json") for item in payload.items]
    agenda.action_items = [item.model_dump(mode="json") for item in payload.action_items]
    agenda.ai_suggestion = (
        payload.ai_suggestion.model_dump(mode="json") if payload.ai_suggestion else None
    )
    agenda.updated_at = datetime.now(UTC)
    await session.commit()
    return agenda
