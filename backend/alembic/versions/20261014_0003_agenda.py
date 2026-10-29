"""meeting agendas, with the AI suggestion kept next to the saved agenda

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-14
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "meeting_agendas",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("meeting_id", sa.Uuid(), nullable=False),
        sa.Column("items", postgresql.JSONB(), nullable=False),
        sa.Column("action_items", postgresql.JSONB(), nullable=False),
        sa.Column("ai_suggestion", postgresql.JSONB(), nullable=True),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.ForeignKeyConstraint(["meeting_id"], ["meetings.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("meeting_id"),
    )


def downgrade() -> None:
    op.drop_table("meeting_agendas")
